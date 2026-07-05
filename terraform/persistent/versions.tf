terraform {
  required_version = ">= 1.7"

  required_providers {
    upcloud = {
      source = "UpCloudLtd/upcloud"
      # >= 5.25 for the floating-IP `release_policy` argument (added in 5.25.0).
      # Token (ucat_) auth has worked since 5.20.
      version = ">= 5.25, < 6.0"
    }
  }
}
