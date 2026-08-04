terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # renovate: datasource=terraform-provider depName=hashicorp/aws
      version = "6.19.0"
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
