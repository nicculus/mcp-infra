output "service_url" {
  description = "Container App FQDN (MCP endpoint base URL)"
  value       = "https://${azurerm_container_app.mcp_server.latest_revision_fqdn}"
}

output "container_app_name" {
  description = "Container App name"
  value       = azurerm_container_app.mcp_server.name
}

output "managed_identity_principal_id" {
  description = "System-assigned managed identity principal ID"
  value       = azurerm_container_app.mcp_server.identity[0].principal_id
}

output "key_vault_name" {
  description = "Key Vault name (populate secrets before first invocation)"
  value       = azurerm_key_vault.mcp.name
}

output "key_vault_uri" {
  description = "Key Vault URI"
  value       = azurerm_key_vault.mcp.vault_uri
}

output "api_key_secret_name" {
  description = "Key Vault secret name for the API key"
  value       = azurerm_key_vault_secret.api_key.name
}

output "github_pat_secret_name" {
  description = "Key Vault secret name for the GitHub PAT"
  value       = azurerm_key_vault_secret.github_pat.name
}
