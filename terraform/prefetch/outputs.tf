output "ssh_host" {
  description = "Public IP of the prefetch box (Ansible/SSH target)."
  value       = upcloud_server.prefetch.network_interface[0].ip_address
}

output "server_uuid" {
  value = upcloud_server.prefetch.id
}

output "operator_allowlist" {
  value = local.operator_cidrs_norm
}
