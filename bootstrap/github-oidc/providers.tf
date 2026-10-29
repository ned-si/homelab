terraform {
  # 1.10: S3-native state locking (`use_lockfile`).
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # renovate: datasource=terraform-provider depName=hashicorp/aws
      version = "6.71.0"
    }
  }

  # Same bucket, region and settings in every module under bootstrap/; only the
  # key differs. Credentials come from the environment, see scripts/tofu.sh.
  backend "s3" {
    bucket       = "ned-si-homelab-tofu-state"
    key          = "bootstrap/github-oidc/terraform.tfstate"
    region       = "eu-central-1"
    encrypt      = true
    use_lockfile = true
  }

  # Client-side encryption of state and plans, as in every module.
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
