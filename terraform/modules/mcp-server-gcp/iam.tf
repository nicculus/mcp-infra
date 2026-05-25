# Service account for the Cloud Run service
resource "google_service_account" "mcp_server" {
  account_id   = "mcp-server-${var.environment}"
  display_name = "MCP Server ${var.environment}"
  description  = "Runtime identity for the MCP server Cloud Run service"
}

# Secret Manager access — api-key
resource "google_secret_manager_secret_iam_member" "api_key" {
  secret_id = google_secret_manager_secret.api_key.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.mcp_server.email}"
}

# Secret Manager access — github-pat
resource "google_secret_manager_secret_iam_member" "github_pat" {
  secret_id = google_secret_manager_secret.github_pat.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.mcp_server.email}"
}

# Allow Cloud Run to use the service account
resource "google_project_iam_member" "mcp_server_run" {
  project = var.gcp_project_id
  role    = "roles/run.invoker"
  member  = "serviceAccount:${google_service_account.mcp_server.email}"
}
