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

# An optional second disk, for running one model without disturbing what is cached on the primary.
#
# Why this exists: the primary disk is an LRU cache you grow as models get bigger, and UpCloud can
# never shrink a disk. So a one-off experiment on a large checkpoint either forces a permanent
# growth of the primary, or evicts weights someone else is about to use. A separate, disposable
# disk avoids both. Created 2026-09-21 to serve `custom_model` while a 364 GB k2-horizon cache sat
# on the primary.
#
# Deliberately without prevent_destroy, unlike the primary: this one is meant to be thrown away. Set
# weights_alt_size_gb back to 0 (or run the destroy) when the experiment is done, and its standing
# cost goes with it.
resource "upcloud_storage" "weights_alt" {
  count = var.weights_alt_size_gb > 0 ? 1 : 0

  title = "${var.prefix}-weights-alt"
  size  = var.weights_alt_size_gb
  tier  = var.weights_tier
  zone  = var.zone
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
