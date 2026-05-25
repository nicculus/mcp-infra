# =============================================================================
# MCP Server GCP Module - Cloud Run behind built-in HTTPS (zero idle cost)
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

# --- Cloud Run service -------------------------------------------------------

resource "google_cloud_run_v2_service" "mcp_server" {
  name                = "mcp-server-${var.environment}"
  location            = var.gcp_region
  ingress             = "INGRESS_TRAFFIC_ALL"
  deletion_protection = false

  template {
    service_account = google_service_account.mcp_server.email

    scaling {
      min_instance_count = 0
      max_instance_count = var.max_instances
    }

    containers {
      image = var.container_image

      env {
        name  = "CLOUD_PROVIDER"
        value = "gcp"
      }
      env {
        name  = "ENVIRONMENT"
        value = var.environment
      }
      env {
        name  = "API_KEY_SECRET"
        value = "projects/${var.gcp_project_id}/secrets/${google_secret_manager_secret.api_key.secret_id}/versions/latest"
      }
      env {
        name  = "GITHUB_PAT_SECRET"
        value = "projects/${var.gcp_project_id}/secrets/${google_secret_manager_secret.github_pat.secret_id}/versions/latest"
      }

      resources {
        limits = {
          memory = "${var.memory_size}Mi"
          cpu    = var.cpu
        }
      }


    }

    timeout = "${var.timeout}s"
  }

  # Image URI is managed by the deploy-image-gcp workflow after initial creation
  lifecycle {
    ignore_changes = [template[0].containers[0].image]
  }

  depends_on = [
    google_secret_manager_secret_iam_member.api_key,
    google_secret_manager_secret_iam_member.github_pat,
  ]
}

# Allow unauthenticated invocations (API key auth is enforced in app code)
resource "google_cloud_run_v2_service_iam_member" "public" {
  name     = google_cloud_run_v2_service.mcp_server.name
  location = var.gcp_region
  role     = "roles/run.invoker"
  member   = "allUsers"
}
