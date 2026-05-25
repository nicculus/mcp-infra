# =============================================================================
# BOOTSTRAP-GCP - Run this manually ONCE before the pipeline works
# cd terraform/bootstrap-gcp && terraform init && terraform apply \
#   -var="gcp_project_id=mcp-infra-gcp" \
#   -var="github_org=YOUR_GITHUB_USERNAME" \
#   -var="billing_account=YOUR_BILLING_ACCOUNT_ID"
# =============================================================================
#
# This creates:
#   1. Enables required GCP APIs
#   2. GCS bucket for Terraform state (versioned, CMEK-encrypted)
#   3. KMS keyring + key for state bucket encryption
#   4. Workload Identity Federation for GitHub Actions (no stored credentials)
#   5. Service account that GitHub Actions impersonates
#   6. Artifact Registry repository for container images
#   7. GCP billing budget alert
#
# After this runs, grab the workload_identity_provider and
# service_account_email outputs and add them as GitHub Actions secrets.
# =============================================================================

terraform {
  required_version = ">= 1.12.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}

provider "google" {
  project = var.gcp_project_id
  region  = var.gcp_region
}

# --- Variables ---------------------------------------------------------------

variable "gcp_project_id" {
  description = "GCP project ID"
  type        = string
}

variable "gcp_region" {
  description = "GCP region"
  type        = string
  default     = "us-central1"
}

variable "github_org" {
  description = "GitHub username or org"
  type        = string
}

variable "github_repo" {
  description = "GitHub repository name"
  type        = string
  default     = "mcp-infra"
}

variable "project_name" {
  type    = string
  default = "mcp-infra"
}

variable "billing_account" {
  description = "GCP billing account ID (format: XXXXXX-XXXXXX-XXXXXX)"
  type        = string
}

variable "budget_limit_usd" {
  description = "Monthly budget limit in USD"
  type        = number
  default     = 5
}

# --- Enable required APIs ----------------------------------------------------

resource "google_project_service" "apis" {
  for_each = toset([
    "cloudresourcemanager.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "sts.googleapis.com",
    "cloudkms.googleapis.com",
    "storage.googleapis.com",
    "artifactregistry.googleapis.com",
    "run.googleapis.com",
    "secretmanager.googleapis.com",
    "cloudbilling.googleapis.com",
    "billingbudgets.googleapis.com",
    "monitoring.googleapis.com",
    "logging.googleapis.com",
  ])

  service            = each.value
  disable_on_destroy = false
}

# --- KMS for state bucket encryption -----------------------------------------

resource "google_kms_key_ring" "bootstrap" {
  name     = "${var.project_name}-bootstrap"
  location = var.gcp_region

  depends_on = [google_project_service.apis]
}

resource "google_kms_crypto_key" "state" {
  name            = "tfstate"
  key_ring        = google_kms_key_ring.bootstrap.id
  rotation_period = "7776000s" # 90 days

  lifecycle {
    prevent_destroy = true
  }
}

# Grant GCS service account access to use the KMS key
data "google_storage_project_service_account" "gcs" {}

resource "google_kms_crypto_key_iam_member" "gcs_encrypt" {
  crypto_key_id = google_kms_crypto_key.state.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${data.google_storage_project_service_account.gcs.email_address}"
}

# --- GCS bucket for Terraform state ------------------------------------------

resource "google_storage_bucket" "terraform_state" {
  name                        = "${var.project_name}-tfstate-${var.gcp_project_id}"
  location                    = var.gcp_region
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  versioning {
    enabled = true
  }

  encryption {
    default_kms_key_name = google_kms_crypto_key.state.id
  }

  lifecycle_rule {
    condition {
      num_newer_versions = 10
    }
    action {
      type = "Delete"
    }
  }

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [google_kms_crypto_key_iam_member.gcs_encrypt]
}

# --- Workload Identity Federation for GitHub Actions -------------------------

resource "google_iam_workload_identity_pool" "github" {
  workload_identity_pool_id = "github-actions"
  display_name              = "GitHub Actions"
  description               = "Identity pool for GitHub Actions OIDC"

  depends_on = [google_project_service.apis]
}

resource "google_iam_workload_identity_pool_provider" "github" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github-oidc"
  display_name                       = "GitHub OIDC"

  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.repository" = "assertion.repository"
    "attribute.ref"        = "assertion.ref"
  }

  attribute_condition = "assertion.repository == '${var.github_org}/${var.github_repo}'"

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

# --- Service account for GitHub Actions --------------------------------------

resource "google_service_account" "github_actions" {
  account_id   = "${var.project_name}-github-actions"
  display_name = "MCP Infra GitHub Actions"
  description  = "Impersonated by GitHub Actions via Workload Identity Federation"
}

resource "google_service_account_iam_member" "github_actions_wif" {
  service_account_id = google_service_account.github_actions.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository/${var.github_org}/${var.github_repo}"
}

# --- IAM roles for the GitHub Actions service account ------------------------

locals {
  github_actions_roles = [
    "roles/run.admin",
    "roles/artifactregistry.admin",
    "roles/iam.serviceAccountAdmin",
    "roles/iam.serviceAccountUser",
    "roles/resourcemanager.projectIamAdmin",
    "roles/secretmanager.admin",
    "roles/monitoring.admin",
    "roles/cloudkms.admin",
    "roles/storage.admin",
    "roles/logging.admin",
    "roles/iam.workloadIdentityPoolAdmin",
  ]
}

resource "google_project_iam_member" "github_actions" {
  for_each = toset(local.github_actions_roles)

  project = var.gcp_project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.github_actions.email}"
}

# --- Artifact Registry repository --------------------------------------------

resource "google_artifact_registry_repository" "mcp_server" {
  repository_id = "mcp-server"
  location      = var.gcp_region
  format        = "DOCKER"
  description   = "MCP server container images"

  cleanup_policies {
    id     = "keep-10-most-recent"
    action = "KEEP"
    most_recent_versions {
      keep_count = 10
    }
  }

  depends_on = [google_project_service.apis]
}

# --- Billing budget alert ----------------------------------------------------

resource "google_billing_budget" "mcp_infra" {
  billing_account = var.billing_account
  display_name    = "${var.project_name}-monthly"

  budget_filter {
    projects = ["projects/${var.gcp_project_id}"]
  }

  amount {
    specified_amount {
      currency_code = "USD"
      units         = tostring(var.budget_limit_usd)
    }
  }

  threshold_rules {
    threshold_percent = 0.8
    spend_basis       = "CURRENT_SPEND"
  }

  all_updates_rule {
    monitoring_notification_channels = []
    disable_default_iam_recipients   = false
  }

  depends_on = [google_project_service.apis]
}

# --- Outputs -----------------------------------------------------------------

output "workload_identity_provider" {
  description = "Add this as GCP_WORKLOAD_IDENTITY_PROVIDER in GitHub repo secrets"
  value       = google_iam_workload_identity_pool_provider.github.name
}

output "service_account_email" {
  description = "Add this as GCP_SERVICE_ACCOUNT in GitHub repo secrets"
  value       = google_service_account.github_actions.email
}

output "artifact_registry_url" {
  description = "Container image registry URL"
  value       = "${var.gcp_region}-docker.pkg.dev/${var.gcp_project_id}/${google_artifact_registry_repository.mcp_server.repository_id}"
}

output "state_bucket" {
  description = "GCS bucket for Terraform state"
  value       = google_storage_bucket.terraform_state.name
}
