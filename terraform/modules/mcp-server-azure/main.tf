# =============================================================================
# MCP Server Azure Module - Container Apps (zero idle cost)
# =============================================================================

terraform {
  required_version = ">= 1.12.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

# --- Container Apps environment ----------------------------------------------

resource "azurerm_container_app_environment" "mcp" {
  name                = "mcp-server-${var.environment}"
  location            = var.location
  resource_group_name = var.resource_group_name
}

# --- Container App -----------------------------------------------------------

resource "azurerm_container_app" "mcp_server" {
  name                         = "mcp-server-${var.environment}"
  container_app_environment_id = azurerm_container_app_environment.mcp.id
  resource_group_name          = var.resource_group_name
  revision_mode                = "Single"

  identity {
    type = "SystemAssigned"
  }

  registry {
    server   = var.acr_login_server
    identity = "System"
  }

  ingress {
    external_enabled = true
    target_port      = 8080

    traffic_weight {
      percentage      = 100
      latest_revision = true
    }
  }

  template {
    min_replicas = 0
    max_replicas = var.max_replicas

    container {
      name   = "mcp-server"
      image  = var.container_image
      cpu    = var.cpu
      memory = var.memory_size

      env {
        name  = "CLOUD_PROVIDER"
        value = "azure"
      }
      env {
        name  = "ENVIRONMENT"
        value = var.environment
      }
      env {
        name  = "AZURE_VAULT_URL"
        value = azurerm_key_vault.mcp.vault_uri
      }
      env {
        name  = "API_KEY_SECRET"
        value = "mcp-api-key-${var.environment}"
      }
      env {
        name  = "GITHUB_PAT_SECRET"
        value = "mcp-github-pat-${var.environment}"
      }

      liveness_probe {
        transport = "TCP"
        port      = 8080
      }

      startup_probe {
        transport               = "TCP"
        port                    = 8080
        initial_delay           = 2
        interval_seconds        = 5
        failure_count_threshold = 3
      }
    }
  }

  # Image URI is managed by the deploy-image-azure workflow after initial creation
  lifecycle {
    ignore_changes = [
      template[0].container[0].image,
    ]
  }
}
