terraform {
  required_version = ">= 1.3"

  required_providers {
    local = {
      source  = "hashicorp/local"
      version = "~> 2.4.0"
    }
    tfe = {
      source  = "hashicorp/tfe"
      version = "~> 0.78"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2.1"
    }
  }
}

# Token comes from TFE_TOKEN / TF_TOKEN_<host> or the `terraform login`
# credentials file; only the hostname is configured here so TFE (self-hosted)
# installs work by setting tfHostname.
provider "tfe" {
  hostname = var.tfHostname
}
