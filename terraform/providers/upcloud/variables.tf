variable "zone" {
  type    = string
  default = "fi-hel2" # the only UpCloud zone with GPUs
}

variable "hostname" {
  type    = string
  default = "gpu-spinner"
}

variable "plan" {
  description = "UpCloud GPU plan. bin/spin normally supplies this from the model profile's min_plan (or a swap preset's swap_plan), so this default only applies when nothing else resolves — it stays L40S to match the default model, qwen36. The full allowlist is tests/plans.txt. Identifiers: https://upcloud.com/docs/products/gpu-servers/configurations/"
  type        = string
  default     = "GPU-8xCPU-64GB-1xL40S"
}

variable "os_template" {
  description = <<-EOT
    OS template TITLE or UUID. Use UpCloud's GPU template that pre-ships the NVIDIA
    driver + CUDA + NVIDIA Container Toolkit + Docker. Discover the exact value with:
      upctl storage list --public --template
    (look for the NVIDIA/CUDA Ubuntu template), then set it in terraform.tfvars.
  EOT
  type        = string
  default     = ""

  validation {
    condition     = length(var.os_template) > 0
    error_message = "Set os_template to the UpCloud GPU (NVIDIA+CUDA) template title or UUID — see `upctl storage list --public --template`."
  }
}

variable "os_disk_size_gb" {
  description = "Boot disk size (GB). The vLLM CUDA image is large and is stored on the boot disk (/var/lib), so this needs headroom beyond the OS. Model weights live on the separate /data disk."
  type        = number
  default     = 100
}

variable "ssh_public_keys" {
  description = "SSH public keys installed for root login."
  type        = list(string)
  default     = []
}

variable "operator_ip" {
  description = "Single public IP to allowlist for SSH/HTTPS. Empty = auto-detect this machine's IP via api.ipify.org. Ignored if operator_cidrs is set."
  type        = string
  default     = ""
}

variable "operator_cidrs" {
  description = <<-EOT
    Allowlisted source IPs/CIDRs for SSH(22) + HTTPS(443) — IPv4 only; a bare IP is treated
    as /32. Use this when your egress IP rotates: list the covering range(s), e.g.
    ["198.51.100.0/24", "203.0.113.0/24"]. Takes priority over operator_ip; empty falls back
    to operator_ip, then to auto-detection.
  EOT
  type        = list(string)
  default     = []
}

variable "persistent_state_path" {
  description = "Override path to the persistent stack's local state file. Empty = anchored to this module dir (../../persistent/terraform.tfstate), so it works regardless of CWD."
  type        = string
  default     = ""
}

variable "weights_disk" {
  description = <<-EOT
    Which persistent data disk to attach: "primary" (the shared cache) or "alt" (the optional
    second disk, see weights_alt_size_gb in terraform/persistent). bin/spin passes this from
    WEIGHTS_DISK. Choosing "alt" when no alt disk exists is an error rather than a silent
    fallback — attaching the wrong disk would quietly re-download or evict someone's cache.
  EOT
  type        = string
  default     = "primary"

  validation {
    condition     = contains(["primary", "alt"], var.weights_disk)
    error_message = "weights_disk must be \"primary\" or \"alt\"."
  }
}
