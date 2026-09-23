variable "zone" {
  type    = string
  default = "fi-hel2" # must match the zone the weights disk lives in
}

variable "hostname" {
  type    = string
  default = "gpu-spinner-prefetch"
}

variable "plan" {
  description = <<-EOT
    Plan for the download box. This is the whole point of the stack: a GPU sits idle during a
    weights pull, and on 4x RTX PRO 6000 that idle time costs 6.60 EUR/h against 0.0446 for
    2xCPU-4GB — about 150x. Downloads are network- and disk-bound, not CPU-bound, so a small
    plan is not slower in any way that matters.

    RAM is the binding constraint, not CPU. Measured 2026-09-20: on 2xCPU-4GB (3.8 GB usable, no
    swap) the `hf` downloader reached ~3.5 GB RSS and the kernel OOM-killed it five times out of
    ten profiles — the Xet backend buffers chunks in memory and scales with concurrency, not with
    file size. CLOUDNATIVE-2xCPU-8GB is both cheaper (0.0357/h vs 0.0446) and twice the RAM, so it
    is the default; the play also adds swap. Prices come from /1.3/price; tests/plans.txt covers
    GPU plans only. Its storage_size is 0, which just means no bundled disk — the template block
    below supplies one.
  EOT
  type        = string
  default     = "CLOUDNATIVE-2xCPU-8GB"
}

variable "os_template" {
  description = <<-EOT
    OS template TITLE or UUID. A plain Ubuntu image, NOT the GPU (NVIDIA+CUDA) template the
    ephemeral stack uses — there is no GPU here and the CUDA image is 20 GB of boot disk this
    box never reads. Discover values with: upctl storage list --public --template
  EOT
  type        = string
  default     = "Ubuntu Server 24.04 LTS (Noble Numbat)"
}

variable "os_disk_size_gb" {
  description = "Boot disk (GB). Nothing large lands here: weights and Docker images both go to the attached /data disk. Destroyed with the server."
  type        = number
  default     = 40
}

variable "ssh_public_keys" {
  description = "SSH public keys installed for root login."
  type        = list(string)
  default     = []
}

variable "operator_ip" {
  description = "Single public IP to allowlist for SSH. Empty = auto-detect via api.ipify.org. Ignored if operator_cidrs is set."
  type        = string
  default     = ""
}

variable "operator_cidrs" {
  description = "Allowlisted source IPs/CIDRs for SSH (IPv4 only; a bare IP is treated as /32). Takes priority over operator_ip."
  type        = list(string)
  default     = []
}

variable "persistent_state_path" {
  description = "Override path to the persistent stack's local state file. Empty = anchored to this module dir."
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
