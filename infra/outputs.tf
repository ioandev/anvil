output "public_ip" {
  description = "Master's public IPv4"
  value       = scaleway_instance_ip.public.address
}

output "dns_record" {
  description = "DNS status / required manual action"
  value = local.cloudflare_enabled ? (
    "managed by terraform on Cloudflare (proxied): ${join(", ", keys(local.cloudflare_records))}"
    ) : (
    "Create manually at your DNS provider: ${var.domain}  A  ${scaleway_instance_ip.public.address}"
  )
}

output "agent_public_ips" {
  description = "Agents' dynamic public IPv4s (SSH only)"
  # provider >= 2.79 exposes IPs as the public_ips block, not a public_ip string
  value = [for s in scaleway_instance_server.agent : try(s.public_ips[0].address, null)]
}

output "master_private_ip" {
  description = "Master's private-network IP (cluster API endpoint)"
  value       = local.master_private_ip
}

output "url" {
  value = "https://${var.domain}${local.cloudflare_enabled ? " (proxied by Cloudflare)" : ""}"
}

output "ssh_command" {
  value = "ssh -i ${trimsuffix(var.ssh_public_key_path, ".pub")} -p ${var.ssh_port} core@${scaleway_instance_ip.public.address}"
}

output "ssh_port" {
  value = var.ssh_port
}
