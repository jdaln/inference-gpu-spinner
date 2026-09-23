# Same allowlist logic as the ephemeral stack: explicit CIDRs > operator_ip > auto-detect.
data "http" "myip" {
  count = (length(var.operator_cidrs) == 0 && var.operator_ip == "") ? 1 : 0
  url   = "https://api.ipify.org"
  retry {
    attempts = 3
  }
}

# Only the weights disk is read from the persistent stack. The floating IP is deliberately NOT
# touched: it carries the TLS cert and the stable hostname, and binding it to a throwaway download
# box would move it off the serving path for no reason.
data "terraform_remote_state" "persistent" {
  backend = "local"
  config = {
    path = var.persistent_state_path != "" ? var.persistent_state_path : "${path.module}/../persistent/terraform.tfstate"
  }
}

locals {
  _alt_id    = try(data.terraform_remote_state.persistent.outputs.weights_alt_storage_id, "")
  weights_id = var.weights_disk == "alt" ? local._alt_id : data.terraform_remote_state.persistent.outputs.weights_storage_id

  _allow_raw = length(var.operator_cidrs) > 0 ? var.operator_cidrs : (
    var.operator_ip != "" ? [var.operator_ip] : ["${trimspace(data.http.myip[0].response_body)}/32"]
  )
  operator_cidrs_norm = [for s in local._allow_raw : strcontains(s, "/") ? s : "${s}/32"]

  operator_ranges = [for c in local.operator_cidrs_norm : {
    start = cidrhost(c, 0)
    end   = cidrhost(c, pow(2, 32 - tonumber(split("/", c)[1])) - 1)
  }]
}
