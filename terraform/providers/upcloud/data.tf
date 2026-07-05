# Operator allowlist source. Priority: var.operator_cidrs > var.operator_ip > auto-detect.
# The external IP lookup runs ONLY when neither is set (count = 0 otherwise).
data "http" "myip" {
  count = (length(var.operator_cidrs) == 0 && var.operator_ip == "") ? 1 : 0
  url   = "https://api.ipify.org"
  retry {
    attempts = 3
  }
}

# Read the stable floating IP + weights disk UUID from the persistent stack's state.
data "terraform_remote_state" "persistent" {
  backend = "local"
  config = {
    # Anchored to this module's directory so it resolves regardless of the process CWD.
    path = var.persistent_state_path != "" ? var.persistent_state_path : "${path.module}/../../persistent/terraform.tfstate"
  }
}

locals {
  floating_ip = data.terraform_remote_state.persistent.outputs.floating_ip
  sslip_host  = data.terraform_remote_state.persistent.outputs.sslip_host
  weights_id  = data.terraform_remote_state.persistent.outputs.weights_storage_id

  # Allowlisted sources for SSH(22) + HTTPS(443): explicit CIDRs, else a single
  # operator_ip, else this machine's auto-detected public IP. Bare IPs -> /32.
  _allow_raw = length(var.operator_cidrs) > 0 ? var.operator_cidrs : (
    var.operator_ip != "" ? [var.operator_ip] : ["${trimspace(data.http.myip[0].response_body)}/32"]
  )
  operator_cidrs_norm = [for s in local._allow_raw : strcontains(s, "/") ? s : "${s}/32"]

  # UpCloud firewall rules are range-based (IPv4): convert each CIDR to a start/end pair.
  operator_ranges = [for c in local.operator_cidrs_norm : {
    start = cidrhost(c, 0)
    end   = cidrhost(c, pow(2, 32 - tonumber(split("/", c)[1])) - 1)
  }]

  # One accept rule per (source range x port) for SSH + HTTPS.
  operator_rules = flatten([
    for r in local.operator_ranges : [
      for p in ["22", "443"] : {
        start   = r.start
        end     = r.end
        port    = p
        comment = "Operator ${p == "22" ? "SSH" : "HTTPS"}"
      }
    ]
  ])
}
