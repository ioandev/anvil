variable "name" {
  description = "Name of this platform: server hostname, Scaleway resource names, bucket prefixes"
  type        = string
  default     = "anvil"
}

variable "zone" {
  description = "Scaleway availability zone"
  type        = string
  default     = "fr-par-1"
}

variable "region" {
  description = "Scaleway region (must contain var.zone)"
  type        = string
  default     = "fr-par"
}

variable "instance_type" {
  description = "Instance commercial type"
  type        = string
  default     = "DEV1-L"
}

variable "domain" {
  description = "Primary domain (a Cloudflare zone you own), e.g. example.com. Sites are listed in sites.yaml; this one names the cluster and the ACME fallback"
  type        = string
}

variable "acme_email" {
  description = "Email for the Let's Encrypt account (only used when not behind Cloudflare)"
  type        = string
  default     = ""
}

variable "acme_ca_server" {
  description = "ACME CA URL. Empty = Let's Encrypt production. While iterating, set to https://acme-staging-v02.api.letsencrypt.org/directory to avoid production rate limits."
  type        = string
  default     = ""
}

variable "k3s_channel" {
  description = "k3s release channel (stable, latest, or a v1.xx minor channel)"
  type        = string
  default     = "stable"
}

variable "ssh_public_key_path" {
  description = "Public key granted to the 'core' user (make ssh-key generates it)"
  type        = string
  default     = "~/.ssh/id_ed25519_anvil.pub"
}

variable "image_path" {
  description = "Local path of the Flatcar Scaleway qcow2 (make fetch downloads it)"
  type        = string
  default     = "downloads/flatcar_production_scaleway_image.qcow2"
}

variable "bucket_name" {
  description = "Object Storage bucket prefix for the image import (random suffix appended; bucket names are unique per region)"
  type        = string
  default     = "anvil-flatcar-import"
}

variable "agent_instance_type" {
  description = "Instance type of the optional agent (worker) nodes: small and cheap, for light work only"
  type        = string
  default     = "DEV1-S"
}

variable "agent_count" {
  description = "Number of optional agent (worker) nodes joining the master. 0 = single server (default). Agents are tainted: only pods that tolerate anvil/light run there"
  type        = number
  default     = 0
}

variable "cloudflare_api_token" {
  description = "OPTIONAL: Cloudflare API token with Zone.DNS Edit on the domain's zone. Used only on this machine (terraform provider + Cloudflare mode flag); it is NOT sent to the server. In Cloudflare mode the origin uses Origin CA certs (platform/origin-ca). Leave empty to skip Cloudflare: then Traefik uses Let's Encrypt via TLS-ALPN. Set via TF_VAR_cloudflare_api_token in .env."
  type        = string
  sensitive   = true
  default     = ""
}

variable "cloudflare_zone_id" {
  description = "OPTIONAL: Cloudflare zone ID of the parent domain (dashboard -> domain overview, right column). Set via TF_VAR_cloudflare_zone_id in .env."
  type        = string
  default     = ""

  validation {
    condition     = (var.cloudflare_api_token == "") == (var.cloudflare_zone_id == "")
    error_message = "Set both cloudflare_api_token and cloudflare_zone_id, or neither."
  }
}

variable "extra_domains" {
  description = "Additional Cloudflare-proxied hostnames served by this cluster, as FQDN => zone ID (wildcards like \"*.example.com\" work). Each becomes a proxied A record on the master's IP; serving it also needs an Ingress on the cluster (cert auto-issues via DNS-01). The API token must have Zone.DNS Edit on every listed zone."
  type        = map(string)
  default     = {}

  validation {
    condition     = length(var.extra_domains) == 0 || var.cloudflare_zone_id != ""
    error_message = "extra_domains requires Cloudflare mode (set cloudflare_api_token and cloudflare_zone_id)."
  }
}

variable "cloudflare_ipv4_ranges" {
  description = "Cloudflare edge IPv4 ranges allowed to reach the master on 80/443 (https://www.cloudflare.com/ips/)"
  type        = list(string)
  default = [
    "173.245.48.0/20", "103.21.244.0/22", "103.22.200.0/22", "103.31.4.0/22",
    "141.101.64.0/18", "108.162.192.0/18", "190.93.240.0/20", "188.114.96.0/20",
    "197.234.240.0/22", "198.41.128.0/17", "162.158.0.0/15", "104.16.0.0/13",
    "104.24.0.0/14", "172.64.0.0/13", "131.0.72.0/22",
  ]
}

variable "image_pipeline" {
  description = "Keep the image-import chain (bucket, uploaded qcow2, snapshot, image). Must be true for the initial deploy and for any server replacement; set false afterwards (make cleanup) to delete those resources — the running server is unaffected."
  type        = bool
  default     = true
}

variable "root_volume_size_gb" {
  description = "Root l_ssd size. DEV1-L includes 80 GB of local SSD (its whole allowance); Flatcar grows the root fs to fill it on first boot, and k3s local-path PVCs (databases) live on it."
  type        = number
  default     = 80
}

variable "swap_size_mb" {
  description = "Swapfile size in MiB"
  type        = number
  default     = 2048
}

variable "registry_password" {
  description = "Password (Scaleway secret key) for the Scaleway registry of var.region (rg.<region>.scw.cloud), user nologin. Written to /etc/rancher/k3s/registries.yaml on first boot. Set via TF_VAR_registry_password in .env. Empty = no private registry auth."
  type        = string
  sensitive   = true
  default     = ""
}

variable "tailscale_version" {
  description = "Tailscale sysext version from github.com/flatcar/sysext-bakery releases (tag tailscale-<version>). Empty = no Tailscale."
  type        = string
  default     = "v1.104.1"
}

variable "tailscale_auth_key" {
  description = "OPTIONAL Tailscale auth key (admin console -> Settings -> Keys; reusable or one-off). When set, nodes join the tailnet on first boot. Set via TF_VAR_tailscale_auth_key in .env. Empty = run `sudo tailscale up` once by hand."
  type        = string
  sensitive   = true
  default     = ""
}

variable "ssh_allowed_cidrs" {
  description = "CIDRs allowed to reach SSH (22). Open to the world by default (key-only auth): SSH must keep working even if Tailscale is lost. Everything else public is 80/443 from Cloudflare only."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "ssh_port" {
  description = "SSH port (sshd.socket drop-in on first boot + the security-group rule). Non-standard to stay out of the internet-wide port-22 scans. Avoid 6443, 10250 and 30000-32767 (k3s)."
  type        = number
  default     = 2222
}

variable "origin_pull_ca_path" {
  description = "CA certificate for Authenticated Origin Pulls (Traefik requires client certs it signed; the client cert itself is uploaded to every zone by scripts/cloudflare-zones.py). Kept outside git with the other restore data. Empty or missing file = origin pulls not enforced."
  type        = string
  default     = "../.data/cloudflare-aop/ca.crt"
}

variable "agent_k3s_version" {
  description = "k3s version for pool nodes (never newer than the master's): scripts/pool sets ANVIL_AGENT_K3S_VERSION from the running master. Empty: the channel."
  type        = string
  default     = ""
}
