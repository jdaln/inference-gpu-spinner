# Throwaway CPU box whose only job is to fill the persistent weights disk before a GPU session.
#
# WHY. Weight downloads are the largest single line item in a validation campaign, and they are
# billed at whatever the attached compute costs. Pulling 354 GB at ~126 MB/s is about 47 minutes:
# 5.17 EUR on 4x RTX PRO 6000, or 0.035 EUR here. The GPU box then starts with a warm cache and
# spends its expensive minutes on inference.
#
# A UpCloud storage device attaches to ONE server at a time, so this stack and the ephemeral GPU
# stack are mutually exclusive by construction. bin/spin prefetch refuses to run while a GPU
# server exists, and destroys this box when the pull finishes.
resource "upcloud_server" "prefetch" {
  hostname = var.hostname
  zone     = var.zone
  plan     = var.plan
  metadata = true
  firewall = true

  template {
    storage               = var.os_template
    size                  = var.os_disk_size_gb
    filesystem_autoresize = true
  }

  login {
    keys            = var.ssh_public_keys
    create_password = false
  }

  network_interface {
    type = "public"
  }

  # The same persistent disk the GPU box mounts at /data, by UUID. An ATTACH, not a clone.
  storage_devices {
    storage = local.weights_id
  }
}

# SSH only, from the operator allowlist, then drop. No 80/443: nothing is served from here, so
# there is no ACME challenge to answer and no endpoint to expose.
resource "upcloud_firewall_rules" "prefetch" {
  server_id = upcloud_server.prefetch.id

  dynamic "firewall_rule" {
    for_each = local.operator_ranges
    content {
      direction              = "in"
      action                 = "accept"
      protocol               = "tcp"
      family                 = "IPv4"
      source_address_start   = firewall_rule.value.start
      source_address_end     = firewall_rule.value.end
      destination_port_start = "22"
      destination_port_end   = "22"
      comment                = "Operator SSH"
    }
  }

  # No implicit deny on UpCloud: this catch-all MUST be last.
  firewall_rule {
    direction = "in"
    action    = "drop"
  }
}
