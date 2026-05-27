resource "google_kms_key_ring" "mcp" {
  name     = "mcp-server-${var.environment}"
  location = var.gcp_region
}

resource "google_kms_crypto_key" "mcp" {
  name            = "mcp-server-${var.environment}"
  key_ring        = google_kms_key_ring.mcp.id
  rotation_period = "7776000s" # 90 days

  lifecycle {
    prevent_destroy = true
  }
}

# Grant Cloud Run service account access to decrypt with this key
resource "google_kms_crypto_key_iam_member" "cloudrun_decrypt" {
  crypto_key_id = google_kms_crypto_key.mcp.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${google_service_account.mcp_server.email}"
}
