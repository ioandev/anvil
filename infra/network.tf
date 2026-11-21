# All cluster traffic (API 6443, flannel VXLAN 8472/udp, kubelet 10250) runs
# over a private network. Scaleway security groups only filter the public
# interface, so nothing cluster-related needs opening publicly.

resource "scaleway_vpc_private_network" "cluster" {
  name   = var.name
  region = var.region
}

# Static private IPs so each node's identity is known at plan time
# (agents need the master's address in their first-boot config).
resource "scaleway_ipam_ip" "master" {
  region = var.region
  source {
    private_network_id = scaleway_vpc_private_network.cluster.id
  }
}

resource "scaleway_ipam_ip" "agent" {
  count  = var.agent_count
  region = var.region
  source {
    private_network_id = scaleway_vpc_private_network.cluster.id
  }
}

# Shared join secret between master and agents.
resource "random_password" "k3s_token" {
  length  = 48
  special = false
}

# Only when Cloudflare creds are set: proxied record (orange cloud) —
# visitors hit Cloudflare's edge, which fetches from the master. The origin
# cert stays a real Let's Encrypt cert via DNS-01, so set the zone's SSL
# mode to "Full (strict)". Without creds, DNS is managed manually (see the
# dns_record output).
locals {
  # Terraform-owned proxied hostnames -> zone ID. The sites' own records are NOT owned here: scripts/cutover.py
  # points each site's host at the server (sites.yaml), so a site can be moved or rolled back without Terraform.
  cloudflare_records = local.cloudflare_enabled ? var.extra_domains : {}
}

resource "cloudflare_dns_record" "site" {
  for_each = local.cloudflare_records
  zone_id  = each.value
  name     = each.key
  type     = "A"
  content  = scaleway_instance_ip.public.address
  proxied  = true
  ttl      = 1
}
