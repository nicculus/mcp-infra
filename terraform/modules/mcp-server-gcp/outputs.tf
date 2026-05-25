output "service_url" {
  description = "Cloud Run service URL (MCP endpoint)"
  value       = google_cloud_run_v2_service.mcp_server.uri
}

output "service_name" {
  description = "Cloud Run service name"
  value       = google_cloud_run_v2_service.mcp_server.name
}

output "service_account_email" {
  description = "Service account email for the Cloud Run service"
  value       = google_service_account.mcp_server.email
}

output "api_key_secret_id" {
  description = "Secret Manager secret ID for the API key (populate before first invocation)"
  value       = google_secret_manager_secret.api_key.secret_id
}

output "github_pat_secret_id" {
  description = "Secret Manager secret ID for the GitHub PAT (populate before first invocation)"
  value       = google_secret_manager_secret.github_pat.secret_id
}
