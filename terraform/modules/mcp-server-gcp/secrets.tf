# Secret Manager secrets — created here as empty shells.
# Populate with actual values before first Cloud Run invocation:
#   gcloud secrets versions add mcp-api-key-{env} --data-file=-
#   gcloud secrets versions add mcp-github-pat-{env} --data-file=-

resource "google_secret_manager_secret" "api_key" {
  secret_id = "mcp-api-key-${var.environment}"

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret" "github_pat" {
  secret_id = "mcp-github-pat-${var.environment}"

  replication {
    auto {}
  }
}
