terraform {
  required_version = ">= 0.13"
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "2.37.1"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "1.19.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "2.17.0"
    }
  }
}

provider "kubernetes" {
  config_path = "${path.module}/../kubeconfig-homelab"
}

provider "helm" {
  kubernetes {
    config_path = "${path.module}/../kubeconfig-homelab"
  }
}

provider "kubectl" {
  config_path = "${path.module}/../kubeconfig-homelab"
}
