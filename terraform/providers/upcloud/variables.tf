variable "zone" {
  type    = string
  default = "fi-hel2" # the only UpCloud zone with GPUs
}

variable "hostname" {
  type    = string
  default = "gpu-spinner"
}

variable "plan" {
  description = "UpCloud GPU plan. Default L40S — the smallest tier that fits the current FP8 models (the L4's 24 GB fits none of them). Use --plan for RTX PRO 6000 (GPU-16xCPU-80GB-1xRTXPRO6000, 96 GB), H100 (GPU-12xCPU-240GB-1xH100) or B200 (GPU-12xCPU-240GB-1xB200). Identifiers: https://upcloud.com/docs/products/gpu-servers/configurations/"
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
