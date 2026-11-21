locals {
  # nonsensitive: the *flag* isn't secret, and without this the sensitivity
  # of the token would taint every output/local derived from it.
  cloudflare_enabled = nonsensitive(var.cloudflare_api_token != "") && var.cloudflare_zone_id != ""

  master_private_ip = split("/", scaleway_ipam_ip.master.address)[0]

  # Cloudflare mode: 80/443 reachable from Cloudflare's edge only.
  # Without Cloudflare: open to the world (TLS-ALPN needs direct inbound 443).
  master_ingress_rules = local.cloudflare_enabled ? {
    for pair in setproduct([80, 443], var.cloudflare_ipv4_ranges) :
    "${pair[0]}-${pair[1]}" => { port = pair[0], ip_range = pair[1] }
    } : {
    "80-any"  = { port = 80, ip_range = null }
    "443-any" = { port = 443, ip_range = null }
  }

  traefik_config = templatefile("${path.module}/manifests/traefik-config.yaml.tpl", {
    acme_email         = var.acme_email
    acme_ca_server     = var.acme_ca_server
    cloudflare_enabled = local.cloudflare_enabled
    cloudflare_ranges  = var.cloudflare_ipv4_ranges
  })

  origin_pull_enabled = local.cloudflare_enabled && var.origin_pull_ca_path != "" && fileexists(var.origin_pull_ca_path)
  origin_pull = local.origin_pull_enabled ? templatefile("${path.module}/manifests/origin-pull.yaml.tpl", {
    ca_crt_b64 = base64encode(file(var.origin_pull_ca_path))
  }) : ""


  butane_common = {
    ssh_public_key     = trimspace(file(pathexpand(var.ssh_public_key_path)))
    swap_size_mb       = var.swap_size_mb
    k3s_channel        = var.k3s_channel
    domain             = var.domain
    k3s_token          = random_password.k3s_token.result
    cloudflare_enabled = local.cloudflare_enabled
    registry_password  = var.registry_password != "" ? "set" : ""
    registries_yaml_b64 = base64encode(yamlencode({
      configs = { "rg.${var.region}.scw.cloud" = { auth = { username = "nologin", password = var.registry_password } } }
    }))
    ssh_port               = var.ssh_port
    tailscale_version      = var.tailscale_version
    tailscale_auth_key     = var.tailscale_auth_key != "" ? "set" : ""
    tailscale_auth_key_b64 = base64encode(var.tailscale_auth_key)
    k3s_version            = ""   # pools pin it (infra/pools.tf)
    node_pool              = ""
    node_trusted           = ""
  }
}

# Butane -> Ignition, one rendering per node. The k8s manifests are embedded
# base64-encoded to avoid YAML-in-YAML indentation issues.
data "ct_config" "master" {
  strict = true
  content = templatefile("${path.module}/butane/flatcar.yaml.tpl", merge(local.butane_common, {
    role               = "server"
    hostname           = var.name
    node_ip            = local.master_private_ip
    master_private_ip  = ""
    traefik_config_b64 = base64encode(local.traefik_config)
    origin_pull_b64    = local.origin_pull_enabled ? base64encode(local.origin_pull) : ""
  }))
}

data "ct_config" "agent" {
  count  = var.agent_count
  strict = true
  content = templatefile("${path.module}/butane/flatcar.yaml.tpl", merge(local.butane_common, {
    role               = "agent"
    hostname           = "${var.name}-agent-${count.index}"
    node_ip            = split("/", scaleway_ipam_ip.agent[count.index].address)[0]
    master_private_ip  = local.master_private_ip
    traefik_config_b64 = ""
    origin_pull_b64    = ""
  }))
}

resource "scaleway_instance_ip" "public" {
  zone = var.zone
}

# Master: 80/443 per local.master_ingress_rules (Cloudflare edge only, or
# world-open without Cloudflare); SSH on var.ssh_port from var.ssh_allowed_cidrs
# (default: anywhere, key-only). Scaleway security
# groups are stateful and don't filter private-network traffic, so cluster
# ports need no rules.
resource "scaleway_instance_security_group" "k3s" {
  name                    = "${var.name}-master"
  zone                    = var.zone
  inbound_default_policy  = "drop"
  outbound_default_policy = "accept"

  dynamic "inbound_rule" {
    for_each = var.ssh_allowed_cidrs
    content {
      action   = "accept"
      protocol = "TCP"
      port     = var.ssh_port
      ip_range = inbound_rule.value
    }
  }

  dynamic "inbound_rule" {
    for_each = local.master_ingress_rules
    content {
      action   = "accept"
      protocol = "TCP"
      port     = inbound_rule.value.port
      ip_range = inbound_rule.value.ip_range
    }
  }
}

# Agents: nothing open but SSH (as for the master).
resource "scaleway_instance_security_group" "agent" {
  name                    = "${var.name}-agent"
  zone                    = var.zone
  inbound_default_policy  = "drop"
  outbound_default_policy = "accept"

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

resource "scaleway_instance_server" "k3s" {
  name = var.name
  zone = var.zone
  type = var.instance_type
  # The placeholder satisfies the provider's "image or root_volume.volume_id"
  # validation after cleanup; ignore_changes below keeps it from ever being
  # applied. Fresh creates require image_pipeline=true.
  image             = var.image_pipeline ? scaleway_instance_image.flatcar[0].id : "image-pipeline-disabled-see-README"
  ip_id             = scaleway_instance_ip.public.id
  security_group_id = scaleway_instance_security_group.k3s.id

  lifecycle {
    # The image is only consulted at create time; ignoring changes to it lets
    # the import pipeline (image included) be destroyed after deploy without
    # terraform proposing to replace the running server.
    ignore_changes = [image]
  }

  root_volume {
    volume_type = "l_ssd"
    size_in_gb  = var.root_volume_size_gb
  }

  # Flatcar's Scaleway OEM reads the Ignition config from this key on first boot.
  user_data = {
    "cloud-init" = data.ct_config.master.rendered
  }
}

resource "scaleway_instance_server" "agent" {
  count             = var.agent_count
  name              = "${var.name}-agent-${count.index}"
  zone              = var.zone
  type              = var.agent_instance_type
  image             = var.image_pipeline ? scaleway_instance_image.flatcar[0].id : "image-pipeline-disabled-see-README"
  enable_dynamic_ip = true # outbound internet (image pulls); inbound is SSH-only
  security_group_id = scaleway_instance_security_group.agent.id

  lifecycle {
    ignore_changes = [image]
  }

  root_volume {
    volume_type = "l_ssd"
    size_in_gb  = var.root_volume_size_gb
  }

  user_data = {
    "cloud-init" = data.ct_config.agent[count.index].rendered
  }
}

# Private-network NICs with the reserved IPAM IPs (eth1 on the nodes). The
# NIC attaches moments after boot; the k3s install/start retry loops absorb
# the brief window where eth1 isn't up yet.
resource "scaleway_instance_private_nic" "master" {
  zone               = var.zone
  server_id          = scaleway_instance_server.k3s.id
  private_network_id = scaleway_vpc_private_network.cluster.id
  ipam_ip_ids        = [scaleway_ipam_ip.master.id]
}

resource "scaleway_instance_private_nic" "agent" {
  count              = var.agent_count
  zone               = var.zone
  server_id          = scaleway_instance_server.agent[count.index].id
  private_network_id = scaleway_vpc_private_network.cluster.id
  ipam_ip_ids        = [scaleway_ipam_ip.agent[count.index].id]
}
