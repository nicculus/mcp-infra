# =============================================================================
# AZURE DEV ENVIRONMENT - Serverless (Container Apps)
# =============================================================================
# Backend config is intentionally partial — storage account resolved at init time.
# Locally: terraform init -backend-config=backend.tfbackend
# CI: storage account name derived from AZURE_STATE_STORAGE_ACCOUNT secret.
# =============================================================================

terraform {
  required_version = ">= 1.12.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }

  backend "azurerm" {
    container_name = "tfstate"
    key            = "azure-dev/terraform.tfstate"
  }
}

provider "azurerm" {
  subscription_id = var.subscription_id
  features {}
}

variable "subscription_id" {
  type = string
}

variable "location" {
  type    = string
  default = "eastus"
}

variable "acr_login_server" {
  description = "ACR login server from bootstrap output"
  type        = string
}

variable "alarm_email" {
  description = "Email address for alert notifications"
  type        = string
}

resource "azurerm_resource_group" "mcp_dev" {
  name     = "mcp-infra-dev"
  location = var.location
}

module "mcp_server" {
  source = "../../modules/mcp-server-azure"

  resource_group_name = azurerm_resource_group.mcp_dev.name
  location            = var.location
  # Placeholder image for initial Terraform apply — deploy-image-azure workflow
  # pushes the real image and updates the Container App via az containerapp update.
  container_image  = "mcr.microsoft.com/azuredocs/containerapps-helloworld:latest"
  environment      = "dev"
  memory_size      = "0.5Gi"
  cpu              = 0.25
  max_replicas     = 10
  acr_login_server = var.acr_login_server
  alarm_email      = var.alarm_email
}

output "mcp_endpoint" {
  value = "${module.mcp_server.service_url}/mcp"
}

output "key_vault_name" {
  value = module.mcp_server.key_vault_name
}

output "api_key_secret_name" {
  value = module.mcp_server.api_key_secret_name
}

output "github_pat_secret_name" {
  value = module.mcp_server.github_pat_secret_name
}
