output "ssh_host" {
  description = "Server's primary public IP — used by Ansible for SSH (reachable immediately)."
  value       = upcloud_server.gpu.network_interface[0].ip_address
}

output "server_uuid" {
  value = upcloud_server.gpu.id
}

output "floating_ip" {
  description = "Stable floating IP (from the persistent stack), bound to this server."
  value       = local.floating_ip
}

output "sslip_host" {
  value = local.sslip_host
}

output "endpoint" {
  description = "Operator-facing HTTPS endpoint (vLLM via Caddy)."
  value       = "https://${local.sslip_host}"
}

output "operator_allowlist" {
  description = "Source IPs/CIDRs allowlisted by the firewall for SSH/HTTPS."
  value       = local.operator_cidrs_norm
}

output "ssh_command" {
  value = "ssh root@${upcloud_server.gpu.network_interface[0].ip_address}"
}
