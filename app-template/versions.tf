terraform {
  required_version = ">= 1.6"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 6.0, < 8.0"
    }
    # Google's modules use the beta provider too; configured here so it gets the same project, region and labels.
    google-beta = {
      source  = "hashicorp/google-beta"
      version = ">= 6.0, < 8.0"
    }
  }
  # Same state bucket as catalog-media (scripts/bootstrap.sh), its own prefix.
  backend "gcs" {
    prefix = "app-template"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
  default_labels = {
    app        = "grocery-hub-channel"
    stack      = "app-template"
    managed-by = "terraform"
  }
}

provider "google-beta" {
  project = var.project_id
  region  = var.region
  default_labels = {
    app        = "grocery-hub-channel"
    stack      = "app-template"
    managed-by = "terraform"
  }
}
