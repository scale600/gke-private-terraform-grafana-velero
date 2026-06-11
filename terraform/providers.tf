terraform {
  required_version = ">= 1.6"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }

  # Enable for team/production use (remote state management)
  # backend "gcs" {
  #   bucket = "tf-state-gke-private-demo-202606"
  #   prefix = "gke-private-demo"
  # }
}

provider "google" {
  project = var.project_id
  region  = var.region
}
