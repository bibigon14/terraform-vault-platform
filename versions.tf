terraform {
  required_version = ">= 1.7"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }

  # Backend configured via -backend-config at init time.
  # See docs/bootstrap.md for local setup, .github/workflows/ for CI.
  backend "s3" {}
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "terraform-vault-platform"
      ManagedBy = "terraform"
    }
  }
}
