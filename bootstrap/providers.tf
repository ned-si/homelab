terraform {
  # 1.10: S3-native state locking (`use_lockfile`).
  required_version = "1.16.5"

  required_providers {
    kubernetes = {
      source = "hashicorp/kubernetes"
      # renovate: datasource=terraform-provider depName=hashicorp/kubernetes
      version = "3.3.0"
    }
    helm = {
      source = "hashicorp/helm"
      # renovate: datasource=terraform-provider depName=hashicorp/helm
      version = "3.3.0"
    }
  }

  # Remote state in the state bucket (bootstrap/tofu-state). The state holds
  # the age key and the Git PAT. Run through scripts/tofu.sh, which supplies the
  # AWS session and the passphrase.
  backend "s3" {
    bucket       = "ned-si-homelab-tofu-state"
    key          = "bootstrap/terraform.tfstate"
    region       = "eu-central-1"
    encrypt      = true
    use_lockfile = true
  }

  # Client-side encryption of state and plans, so the age key and the PAT never
  # reach S3 in cleartext. LOSE THE PASSPHRASE AND THE STATE IS UNREADABLE.
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

provider "kubernetes" {
  config_path = var.kubeconfig_path
}

provider "helm" {
  # Provider v3 flattened this block; in v2 it was `kubernetes { ... }`.
  kubernetes = {
    config_path = var.kubeconfig_path
  }
}
