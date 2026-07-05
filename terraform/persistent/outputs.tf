output "weights_storage_id" {
  description = "UUID of the persistent weights/cert disk (attached by the ephemeral stack)."
  value       = upcloud_storage.weights.id
}

output "floating_ip" {
  description = "Stable public IPv4, reused across spin-ups."
  value       = upcloud_floating_ip_address.vip.ip_address
}

output "floating_ip_dashed" {
  description = "Floating IP with dots -> dashes (the sslip.io label)."
  value       = replace(upcloud_floating_ip_address.vip.ip_address, ".", "-")
}

output "sslip_host" {
  description = "Stable TLS hostname: <dashed-ip>.sslip.io."
  value       = "${replace(upcloud_floating_ip_address.vip.ip_address, ".", "-")}.sslip.io"
}

output "zone" {
  value = var.zone
}
