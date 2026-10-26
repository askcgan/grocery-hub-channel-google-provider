terraform {
  required_version = ">= 1.6"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 6.0, < 8.0"
    }
  }
  # State lives in a versioned bucket created by scripts/bootstrap.sh; the bucket name is passed at init time
  # (scripts/plan.sh: terraform init -backend-config="bucket=<project>-tfstate").
  backend "gcs" {
    prefix = "catalog-media"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
  default_labels = {
    app        = "grocery-hub-channel"
    stack      = "catalog-media"
    managed-by = "terraform"
  }
}
