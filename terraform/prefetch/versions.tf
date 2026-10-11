terraform {
  required_version = ">= 1.7"

  required_providers {
    upcloud = {
      source  = "UpCloudLtd/upcloud"
      version = ">= 5.25, < 6.0"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.4"
    }
  }
}
