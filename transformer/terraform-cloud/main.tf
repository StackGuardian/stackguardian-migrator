terraform {
  required_version = "~> 1.2"

  required_providers {
    local = {
      source  = "hashicorp/local"
      version = "~> 2.4.0"
    }
    tfe = {
      source  = "hashicorp/tfe"
      version = "~> 0.48.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2.1"
    }
  }
}