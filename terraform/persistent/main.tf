# LONG-LIVED stack. These resources are intentionally NOT destroyed during the
# daily spin up/down cycle — they hold the stable public IP and the model/cert
# data. prevent_destroy guards against an accidental `tofu destroy` here.

resource "upcloud_storage" "weights" {
  title = "${var.prefix}-weights"
  size  = var.weights_size_gb
  tier  = var.weights_tier
  zone  = var.zone

  lifecycle {
    prevent_destroy = true
  }
}

resource "upcloud_floating_ip_address" "vip" {
  zone   = var.zone
  family = "IPv4"
  access = "public"
  # Retain the address when it is detached from a destroyed server (provider >= 5.25).
  release_policy = "keep"

  # The ephemeral stack (re)binds this IP to each new server's NIC MAC out-of-band
  # (via the UpCloud API), so MAC changes here are expected and must not cause drift.
  # NOTE: deleting this resource RELEASES the IP — never manage it from the ephemeral stack.
  lifecycle {
    prevent_destroy = true
    ignore_changes  = [mac_address]
  }
}
