# Rules are evaluated in declared order; there is NO implicit deny, so the final
# catch-all drop (action+direction only) MUST be last. UpCloud's firewall is range-based
# (not CIDR): a single host is start == end. We allow one SSH+HTTPS pair per operator
# source range (see local.operator_rules in data.tf) so a rotating egress can be covered
# by listing the broader CIDR(s) in operator_cidrs.
#
# NOTE: only `direction = "in"` rules are defined; outbound is left default-allow (verified live:
# ACME egress, HF model downloads and replies to inbound flows all work with the drop-last inbound
# set). If you ever add `direction = "out"` rules, re-verify return traffic against UpCloud's
# current firewall semantics before relying on it.
resource "upcloud_firewall_rules" "gpu" {
  server_id = upcloud_server.gpu.id

  # (1) HTTP from anywhere — REQUIRED for Let's Encrypt HTTP-01 (validators come from many
  #     un-allowlistable IPs). Caddy serves only the ACME challenge + redirect here.
  firewall_rule {
    direction              = "in"
    action                 = "accept"
    protocol               = "tcp"
    family                 = "IPv4"
    source_address_start   = "0.0.0.0"
    source_address_end     = "255.255.255.255"
    destination_port_start = "80"
    destination_port_end   = "80"
    comment                = "ACME HTTP-01 (Let's Encrypt)"
  }

  # (2) Operator allowlist — SSH(22) + HTTPS(443) for each allowed source range.
  #     Set operator_cidrs to your covering range(s) when your egress IP rotates.
  dynamic "firewall_rule" {
    for_each = local.operator_rules
    content {
      direction              = "in"
      action                 = "accept"
      protocol               = "tcp"
      family                 = "IPv4"
      source_address_start   = firewall_rule.value.start
      source_address_end     = firewall_rule.value.end
      destination_port_start = firewall_rule.value.port
      destination_port_end   = firewall_rule.value.port
      comment                = firewall_rule.value.comment
    }
  }

  # (3) Catch-all DROP — MUST be last (no implicit deny).
  firewall_rule {
    direction = "in"
    action    = "drop"
    comment   = "Default deny inbound"
  }
}
