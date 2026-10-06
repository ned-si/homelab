terraform {
  # 1.10: S3-native state locking (`use_lockfile`).
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # renovate: datasource=terraform-provider depName=hashicorp/aws
      version = "6.19.0"
    }
  }

  # Same bucket, region and settings in every module under bootstrap/; only the
  # key differs (`<module path>/terraform.tfstate`). Credentials come from the
  # environment, see scripts/tofu.sh.
  backend "s3" {
    bucket       = "ned-si-homelab-tofu-state"
    key          = "bootstrap/tofu-state/terraform.tfstate"
    region       = "eu-central-1"
    encrypt      = true
    use_lockfile = true
  }

  # Client-side encryption of state and plans. `enforced` makes OpenTofu refuse
  # to write either one unencrypted. The passphrase is a variable so it is never
  # in git; scripts/tofu.sh supplies it. LOSE IT AND THE STATE IS UNREADABLE.
  encryption {
    key_provider "pbkdf2" "state" {
      passphrase = var.state_passphrase
    }

    method "aes_gcm" "state" {
      keys = key_provider.pbkdf2.state
    }

    state {
      method   = method.aes_gcm.state
      enforced = true
    }

    plan {
      method   = method.aes_gcm.state
      enforced = true
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project = "homelab"
      Managed = "opentofu"
    }
  }
}
