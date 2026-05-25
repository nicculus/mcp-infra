data "azurerm_client_config" "current" {}

resource "azurerm_key_vault" "mcp" {
  name                = "mcp-${var.environment}-kv"
  location            = var.location
  resource_group_name = var.resource_group_name
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "standard"

  # Allow the Container App's managed identity to access secrets
  rbac_authorization_enabled = false

  purge_protection_enabled   = false
  soft_delete_retention_days = 7
}

# Access policy for the Container App's system-assigned identity
resource "azurerm_key_vault_access_policy" "mcp_server" {
  key_vault_id = azurerm_key_vault.mcp.id
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = azurerm_container_app.mcp_server.identity[0].principal_id

  secret_permissions = ["Get", "List"]
}

# Access policy for the Terraform runner (to create secrets)
resource "azurerm_key_vault_access_policy" "terraform" {
  key_vault_id = azurerm_key_vault.mcp.id
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = data.azurerm_client_config.current.object_id

  secret_permissions = ["Get", "List", "Set", "Delete", "Purge", "Recover"]
}

# Secret shells — populate before first invocation:
#   az keyvault secret set --vault-name mcp-dev-kv --name mcp-api-key-dev --value "YOUR_API_KEY"
#   az keyvault secret set --vault-name mcp-dev-kv --name mcp-github-pat-dev --value "YOUR_PAT"

resource "azurerm_key_vault_secret" "api_key" {
  name         = "mcp-api-key-${var.environment}"
  value        = "YOUR_API_KEY"
  key_vault_id = azurerm_key_vault.mcp.id

  lifecycle {
    ignore_changes = [value]
  }

  depends_on = [azurerm_key_vault_access_policy.terraform]
}

resource "azurerm_key_vault_secret" "github_pat" {
  name         = "mcp-github-pat-${var.environment}"
  value        = "YOUR_GITHUB_PAT"
  key_vault_id = azurerm_key_vault.mcp.id

  lifecycle {
    ignore_changes = [value]
  }

  depends_on = [azurerm_key_vault_access_policy.terraform]
}
