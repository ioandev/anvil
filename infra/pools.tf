# Extra node pools: servers that join the cluster as k3s agents for one project's heavy work, switched on only when
# needed (billed by the hour). docs: Operations → Scale a site out. The example is `demo`: the demo app's own database,
# API and website when it outgrows the server, and its load-test copy.
#
# Separate from the light node (instance.tf, `agent_*`) on purpose: those resources are untouched, so adding a pool can
# never replace it.
#
# Unlike the light node, a pool is TRUSTED (var.pools[*].trusted): it may pull from the registry and run pods that use
# Secrets, and it is not refused by the `block-agents` NetworkPolicies (scripts/node.sh isolate-agents refuses the light
# node and untrusted pools only). It is not exposed either: no public 80/443 (traffic comes through the server's Traefik
# over the private network), only SSH on var.ssh_port.
#
# Block storage (SBS), not local SSD: the server can change type later (POP2-4C-16G -> POP2-8C-32G, ...) with a stop
# and start, keeping its disk, IP and cluster identity (the provider migrates in place: replace_on_type_change false).
# That needs a Flatcar image on a block snapshot: var.pool_image_pipeline imports one (kept, so a pool node is up in
# minutes).
#
# Up/down: scripts/pool up|down <name> (sets the count in infra/pools.auto.tfvars, then a targeted plan and apply).

variable "pools" {
  description = "Extra node pools: name => settings. count 0 = nothing exists (and nothing is billed)."
  type = map(object({
    count               = number
    type                = string # e.g. POP2-4C-16G; change it to resize in place (stop, migrate, start)
    disk_gb             = number
    iops                = optional(number, 5000) # SBS: 5000 or 15000
    swap_mb             = optional(number, 1024)
    ssh_public_key_path = optional(string, "") # default: the server's own key (var.ssh_public_key_path)
    trusted             = optional(bool, true)
    # Direct mode (scripts/pool direct <name> on|off): Cloudflare fetches the pool's sites from the pool itself
    # instead of the server, through a second Traefik on the pool; 80/443 open to Cloudflare's ranges only, as on
    # the server, with the same Authenticated Origin Pulls (only our zones complete a handshake).
    direct = optional(bool, false)
  }))
  default = {}
  validation {
    # A private key must never end up in a server's first-boot data (it happened once in a draft: caught by YAML).
    condition     = alltrue([for p in values(var.pools) : p.ssh_public_key_path == "" || endswith(p.ssh_public_key_path, ".pub")])
    error_message = "pools[*].ssh_public_key_path must be a .pub file (the PUBLIC key)."
  }
}

variable "pool_image_pipeline" {
  description = "Import Flatcar onto a block snapshot and keep it as an image (needed to create pool nodes: SBS servers can't boot the local-SSD image)."
  type        = bool
  default     = false
}

locals {
  # One entry per node: "demo-0" => { pool = "demo", index = 0, ... }.
  pool_nodes = merge([
    for name, p in var.pools : {
      for i in range(p.count) : "${name}-${i}" => merge(p, { pool = name, index = i })
    }
  ]...)
}

# --- Flatcar on a block snapshot (same qcow2 as image.tf, var.image_path) ---------------------------------------

resource "scaleway_object_bucket" "pool_image" {
  count  = var.pool_image_pipeline ? 1 : 0
  name   = "${var.bucket_name}-pool-${random_id.bucket_suffix.hex}"
  region = var.region
}

resource "scaleway_object" "pool_qcow2" {
  count  = var.pool_image_pipeline ? 1 : 0
  bucket = scaleway_object_bucket.pool_image[0].name
  region = var.region
  key    = "flatcar_production_scaleway_image.qcow2"
  file   = var.image_path
  hash   = fileexists(var.image_path) ? filemd5(var.image_path) : null
}

# The qcow2 imported straight into a block snapshot (the `import` argument of scaleway_block_snapshot).
resource "scaleway_block_snapshot" "pool_flatcar" {
  count = var.pool_image_pipeline ? 1 : 0
  name  = "flatcar-stable-sbs"
  zone  = var.zone
  import {
    bucket = scaleway_object.pool_qcow2[0].bucket
    key    = scaleway_object.pool_qcow2[0].key
  }
}

resource "scaleway_instance_image" "pool_flatcar" {
  count          = var.pool_image_pipeline ? 1 : 0
  name           = "flatcar-stable-sbs"
  zone           = var.zone
  root_volume_id = scaleway_block_snapshot.pool_flatcar[0].id
  architecture   = "x86_64"
}

# --- The nodes -------------------------------------------------------------------------------------------------

resource "scaleway_ipam_ip" "pool" {
  for_each = local.pool_nodes
  region   = var.region
  source {
    private_network_id = scaleway_vpc_private_network.cluster.id
  }
}

# A public IP for outbound traffic (registry pulls, the internet) and SSH; nothing else is open on it.
resource "scaleway_instance_ip" "pool" {
  for_each = local.pool_nodes
  zone     = var.zone
}

resource "scaleway_instance_security_group" "pool" {
  for_each                = var.pools
  name                    = "${var.name}-pool-${each.key}"
  zone                    = var.zone
  inbound_default_policy  = "drop"
  outbound_default_policy = "accept"

  dynamic "inbound_rule" {
    for_each = each.value.direct ? local.master_ingress_rules : {}
    content {
      action   = "accept"
      protocol = "TCP"
      port     = inbound_rule.value.port
      ip_range = inbound_rule.value.ip_range
    }
  }

  dynamic "inbound_rule" {
    for_each = var.ssh_allowed_cidrs
    content {
      action   = "accept"
      protocol = "TCP"
      port     = var.ssh_port
      ip_range = inbound_rule.value
    }
  }
}

data "ct_config" "pool" {
  for_each = local.pool_nodes
  strict   = true
  content = templatefile("${path.module}/butane/flatcar.yaml.tpl", merge(local.butane_common, {
    role               = "agent"
    hostname           = "${var.name}-${each.key}"
    node_ip            = split("/", scaleway_ipam_ip.pool[each.key].address)[0]
    master_private_ip  = local.master_private_ip
    traefik_config_b64 = ""
    origin_pull_b64    = ""
    ssh_public_key     = trimspace(file(pathexpand(each.value.ssh_public_key_path != "" ? each.value.ssh_public_key_path : var.ssh_public_key_path)))
    swap_size_mb       = each.value.swap_mb
    k3s_version        = var.agent_k3s_version # never newer than the master's
    node_pool          = each.value.pool
    node_trusted       = each.value.trusted ? "true" : ""
    # Trusted pools pull from the registry like the master; an untrusted one gets no login (as the light node).
    registry_password = each.value.trusted && var.registry_password != "" ? "set" : ""
  }))
}

resource "scaleway_instance_server" "pool" {
  for_each          = local.pool_nodes
  name              = "${var.name}-${each.key}"
  zone              = var.zone
  type              = each.value.type
  image             = var.pool_image_pipeline ? scaleway_instance_image.pool_flatcar[0].id : "pool-image-pipeline-disabled"
  ip_id             = scaleway_instance_ip.pool[each.key].id
  security_group_id = scaleway_instance_security_group.pool[each.value.pool].id
  tags              = [var.name, "pool-${each.value.pool}"]

  lifecycle {
    ignore_changes = [image]
  }

  root_volume {
    volume_type = "sbs_volume"
    size_in_gb  = each.value.disk_gb
    sbs_iops    = each.value.iops
  }

  user_data = {
    "cloud-init" = data.ct_config.pool[each.key].rendered
  }
}

resource "scaleway_instance_private_nic" "pool" {
  for_each           = local.pool_nodes
  zone               = var.zone
  server_id          = scaleway_instance_server.pool[each.key].id
  private_network_id = scaleway_vpc_private_network.cluster.id
  ipam_ip_ids        = [scaleway_ipam_ip.pool[each.key].id]
}

output "pool_nodes" {
  description = "Pool nodes: name => public IP, private IP, type"
  value = {
    for k, v in local.pool_nodes : k => {
      public_ip  = scaleway_instance_ip.pool[k].address
      private_ip = split("/", scaleway_ipam_ip.pool[k].address)[0]
      type       = v.type
    }
  }
}

# --- The load generator: a temporary machine that runs k6 (scripts/loadtest run) ------------------------------------
# Not part of the cluster (no k3s, no private network, no secrets): Flatcar with Docker and an SSH key, created for a
# run and deleted after it. In the same region as the server, so the home connection is not what limits the test.

variable "loadgen" {
  description = "The k6 machine: count 0 or 1, its type (billed by the hour), and the SSH key for core"
  type = object({
    count               = number
    type                = string
    ssh_public_key_path = optional(string, "") # default: the server's own key
  })
  default = { count = 0, type = "POP2-2C-8G" }
  validation {
    condition     = var.loadgen.ssh_public_key_path == "" || endswith(var.loadgen.ssh_public_key_path, ".pub")
    error_message = "loadgen.ssh_public_key_path must be a .pub file (the PUBLIC key)."
  }
}

data "ct_config" "loadgen" {
  count  = var.loadgen.count
  strict = true
  content = yamlencode({
    variant = "flatcar"
    version = "1.0.0"
    passwd  = { users = [{ name = "core", ssh_authorized_keys = [trimspace(file(pathexpand(var.loadgen.ssh_public_key_path != "" ? var.loadgen.ssh_public_key_path : var.ssh_public_key_path)))] }] }
    # No automatic updates or reboots in the middle of a test: the machine lives an hour at most.
    systemd = { units = [{ name = "update-engine.service", mask = true }, { name = "locksmithd.service", mask = true }] }
  })
}

resource "scaleway_instance_ip" "loadgen" {
  count = var.loadgen.count
  zone  = var.zone
}

resource "scaleway_instance_security_group" "loadgen" {
  count                   = var.loadgen.count
  name                    = "${var.name}-loadgen"
  zone                    = var.zone
  inbound_default_policy  = "drop"
  outbound_default_policy = "accept"

  dynamic "inbound_rule" {
    for_each = var.ssh_allowed_cidrs
    content {
      action   = "accept"
      protocol = "TCP"
      port     = 22
      ip_range = inbound_rule.value
    }
  }
}

resource "scaleway_instance_server" "loadgen" {
  count             = var.loadgen.count
  name              = "${var.name}-loadgen"
  zone              = var.zone
  type              = var.loadgen.type
  image             = var.pool_image_pipeline ? scaleway_instance_image.pool_flatcar[0].id : "pool-image-pipeline-disabled"
  ip_id             = scaleway_instance_ip.loadgen[0].id
  security_group_id = scaleway_instance_security_group.loadgen[0].id
  tags              = [var.name, "loadgen"]

  root_volume {
    volume_type = "sbs_volume"
    size_in_gb  = 20
  }

  user_data = {
    "cloud-init" = data.ct_config.loadgen[0].rendered
  }
}

output "loadgen_ip" {
  description = "The k6 machine's public IP (empty when it doesn't exist)"
  value       = var.loadgen.count > 0 ? scaleway_instance_ip.loadgen[0].address : ""
}
