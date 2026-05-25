# =============================================================================
# GCP DEV ENVIRONMENT - Serverless (Cloud Run)
# =============================================================================
# Backend config is intentionally partial — bucket is resolved at init time.
# Locally: terraform init -backend-config=backend.tfbackend
# CI: bucket derived from GCP_STATE_BUCKET secret.
# =============================================================================

terraform {
  required_version = ">= 1.12.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }

  backend "gcs" {
    prefix = "gcp-dev/terraform.tfstate"
  }
}

provider "google" {
  project = var.gcp_project_id
  region  = var.gcp_region

  default_labels = {
    project     = "mcp-infra"
    environment = "gcp-dev"
    managed_by  = "terraform"
  }
}

variable "gcp_project_id" {
  type    = string
  default = "mcp-infra-gcp"
}

variable "gcp_region" {
  type    = string
  default = "us-central1"
}

variable "alarm_email" {
  description = "Email address for Cloud Monitoring alert notifications"
  type        = string
}

module "mcp_server" {
  source = "../../modules/mcp-server-gcp"

  gcp_project_id  = var.gcp_project_id
  gcp_region      = var.gcp_region
  # Placeholder image for initial Terraform apply — deploy-image-gcp workflow
  # pushes the real image and updates the service via gcloud run services update.
  container_image = "us-docker.pkg.dev/cloudrun/container/hello:latest"
  environment     = "dev"
  memory_size     = 512
  timeout         = 30
  max_instances   = 10
  alarm_email     = var.alarm_email
}

output "mcp_endpoint" {
  value = "${module.mcp_server.service_url}/mcp"
}

output "api_key_secret_id" {
  value = module.mcp_server.api_key_secret_id
}

output "github_pat_secret_id" {
  value = module.mcp_server.github_pat_secret_id
}
