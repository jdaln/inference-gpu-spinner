resource "upcloud_server" "gpu" {
  hostname = var.hostname
  zone     = var.zone
  plan     = var.plan
  metadata = true # required for cloud-init on recent templates
  firewall = true # enforce upcloud_firewall_rules (see firewall.tf)

  # OS disk: provisioned from the GPU template (NVIDIA driver + CUDA + Docker preinstalled).
  template {
    storage               = var.os_template
    size                  = var.os_disk_size_gb
    filesystem_autoresize = true # grow the root FS when the disk is resized
  }

  login {
    keys            = var.ssh_public_keys
    create_password = false
  }

  network_interface {
    type = "public"
  }

  # Attach the persistent weights/cert disk by UUID. This is an ATTACH (not a clone),
  # so the disk's data is preserved across spin-ups.
  storage_devices {
    storage = local.weights_id
  }

  # Minimal first-boot: claim the floating IP at the OS level (netplan /32 on eth0).
  user_data = templatefile("${path.module}/templates/cloud-init.yaml.tftpl", {
    floating_ip = local.floating_ip
  })
}

# (Re)attach the persistent floating IP to THIS server's NIC MAC on every spin-up.
# The UpCloud API binding (below) is required IN ADDITION to the guest netplan /32
# done in cloud-init — neither alone routes traffic. terraform_data is built-in
# (no null provider needed); triggers_replace re-runs it whenever the server changes.
resource "terraform_data" "attach_floating_ip" {
  triggers_replace = [
    upcloud_server.gpu.network_interface[0].mac_address,
    local.floating_ip,
  ]

  provisioner "local-exec" {
    # UPCLOUD_TOKEN (a ucat_ token) must be exported in the environment running tofu.
    command = <<-EOT
      curl -fsS -X PATCH \
        -H "Authorization: Bearer $UPCLOUD_TOKEN" \
        -H "Content-Type: application/json" \
        "https://api.upcloud.com/1.3/ip_address/${local.floating_ip}" \
        --data-binary "{\"ip_address\":{\"mac\":\"${upcloud_server.gpu.network_interface[0].mac_address}\"}}"
    EOT
  }
}
