terraform {
  required_version = ">= 1.8"

  required_providers {
    kubernetes = {
      source = "hashicorp/kubernetes"
      # renovate: datasource=terraform-provider depName=hashicorp/kubernetes
      version = "2.38.0"
    }
    helm = {
      source = "hashicorp/helm"
      # renovate: datasource=terraform-provider depName=hashicorp/helm
      version = "3.0.2"
    }
  }
}

# NOTE: state is local. For a single-operator homelab that is a reasonable
# choice, but it means `bootstrap/terraform.tfstate` is the only record of what
# was applied -- and it contains the age key and the Git PAT in cleartext.
# It is git-ignored. Back it up somewhere encrypted, or move to a remote backend.

provider "kubernetes" {
  config_path = var.kubeconfig_path
}

provider "helm" {
  # Provider v3 flattened this block; in v2 it was `kubernetes { ... }`.
  kubernetes = {
    config_path = var.kubeconfig_path
  }
}
