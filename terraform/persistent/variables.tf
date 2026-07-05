variable "zone" {
  description = "UpCloud zone. GPUs (and therefore this whole project) only exist in fi-hel2."
  type        = string
  default     = "fi-hel2"
}

variable "prefix" {
  description = "Name prefix for resources created by this project."
  type        = string
  default     = "gpu-spinner"
}

variable "weights_size_gb" {
  description = <<-EOT
    Size (GB) of the persistent data disk. Holds the Hugging Face model cache + Caddy TLS store, which
    survive the daily teardown. This disk bills 24/7, so it IS your standing cost — keep it small.
    Default 150 GB fits the FP8/NVFP4 profiles one-or-a-few at a time (~€34/mo MaxIOPS) and is an LRU
    cache. Large models need more: GLM-5.2 NVFP4 (~377 GB) needs ~500 GB — set it via WEIGHTS_SIZE_GB
    (see .env.example). Existing disks GROW to this on the next `bin/spin persistent-init`; UpCloud
    cannot shrink a disk (to reduce, `bin/spin persistent-destroy` then re-init smaller).
  EOT
  type        = number
  default     = 150
}

variable "weights_tier" {
  description = "Storage tier for the data disk. 'maxiops' is recommended for fast model load."
  type        = string
  default     = "maxiops"
}
