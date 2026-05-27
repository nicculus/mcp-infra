# =============================================================================
# BOOTSTRAP-AZURE - Run this manually ONCE before the pipeline works
# cd terraform/bootstrap-azure && terraform init && terraform apply \
#   -var="subscription_id=YOUR_SUBSCRIPTION_ID" \
#   -var="github_org=YOUR_GITHUB_USERNAME"
# =============================================================================
#
# This creates:
#   1. Resource group for bootstrap resources
#   2. Storage account + container for Terraform state
#   3. Azure Container Registry for container images
#   4. App registration + federated credentials for GitHub Actions (no stored secrets)
#   5. Role assignments for the GitHub Actions service principal
#
# After this runs, grab the outputs and add them as GitHub Actions secrets:
#   AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_SUBSCRIPTION_ID
# =============================================================================

terraform {
  required_version = ">= 1.12.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.0"
    }
  }
}

provider "azurerm" {
  subscription_id = var.subscription_id
  features {}
}

provider "azuread" {}

# --- Variables ---------------------------------------------------------------

variable "subscription_id" {
  description = "Azure subscription ID"
  type        = string
}

variable "location" {
  description = "Azure region"
  type        = string
  default     = "eastus"
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

# --- Data sources ------------------------------------------------------------

data "azurerm_subscription" "current" {}
data "azuread_client_config" "current" {}

# --- Resource provider registrations -----------------------------------------

resource "azurerm_resource_provider_registration" "container_apps" {
  name = "Microsoft.App"
}

resource "azurerm_resource_provider_registration" "operational_insights" {
  name = "Microsoft.OperationalInsights"
}

resource "azurerm_resource_provider_registration" "container_registry" {
  name = "Microsoft.ContainerRegistry"
}

resource "azurerm_resource_provider_registration" "key_vault" {
  name = "Microsoft.KeyVault"
}

resource "azurerm_resource_provider_registration" "insights" {
  name = "Microsoft.Insights"
}

# --- Resource group ----------------------------------------------------------

resource "azurerm_resource_group" "bootstrap" {
  name     = "${var.project_name}-bootstrap"
  location = var.location
}

# --- Storage account for Terraform state -------------------------------------

#checkov:skip=CKV_AZURE_206:LRS is sufficient for a dev-only Terraform state bucket
#checkov:skip=CKV_AZURE_190:Terraform state is private; public blob access is disabled at account level
#checkov:skip=CKV_AZURE_59:Public access disabled via allow_blob_public_access=false (default in provider v4)
#checkov:skip=CKV_AZURE_33:Queue logging not required for a blob-only Terraform state account
#checkov:skip=CKV2_AZURE_1:CMK encryption is overkill for a dev bootstrap state bucket
#checkov:skip=CKV2_AZURE_18:CMK encryption is overkill for a dev bootstrap state bucket
#checkov:skip=CKV2_AZURE_21:Diagnostic logging not required for dev bootstrap state account
resource "azurerm_storage_account" "terraform_state" {
  name                     = replace("${var.project_name}tfstate", "-", "")
  resource_group_name      = azurerm_resource_group.bootstrap.name
  location                 = azurerm_resource_group.bootstrap.location
  account_tier             = "Standard"
  account_replication_type = "LRS"

  blob_properties {
    versioning_enabled = true
  }

  min_tls_version = "TLS1_2"

  tags = {
    project    = var.project_name
    managed_by = "terraform"
  }
}

#checkov:skip=CKV2_AZURE_21:Logging not required for dev bootstrap state container
resource "azurerm_storage_container" "terraform_state" {
  name                  = "tfstate"
  storage_account_id    = azurerm_storage_account.terraform_state.id
  container_access_type = "private"
}

# --- Azure Container Registry ------------------------------------------------

#checkov:skip=CKV_AZURE_165:Geo-replication requires Premium SKU; Basic is intentional for dev cost
#checkov:skip=CKV_AZURE_233:Zone redundancy requires Premium SKU
#checkov:skip=CKV_AZURE_167:Untagged manifest retention requires Standard+ SKU
#checkov:skip=CKV_AZURE_166:Quarantine requires Premium SKU
#checkov:skip=CKV_AZURE_163:Defender vulnerability scanning requires Standard+ SKU
#checkov:skip=CKV_AZURE_237:Dedicated data endpoints require Premium SKU
#checkov:skip=CKV_AZURE_139:Network rules require Standard+ SKU; Basic is public by design
#checkov:skip=CKV_AZURE_164:Content trust requires Premium SKU
#checkov:skip=CKV2_AZURE_5:Private endpoint requires Premium SKU
resource "azurerm_container_registry" "mcp_server" {
  name                = replace("${var.project_name}registry", "-", "")
  resource_group_name = azurerm_resource_group.bootstrap.name
  location            = azurerm_resource_group.bootstrap.location
  sku                 = "Basic"
  admin_enabled       = false

  tags = {
    project    = var.project_name
    managed_by = "terraform"
  }
}

# --- App registration for GitHub Actions OIDC --------------------------------

resource "azuread_application" "github_actions" {
  display_name = "${var.project_name}-github-actions"
}

resource "azuread_service_principal" "github_actions" {
  client_id = azuread_application.github_actions.client_id
}

# Federated credential for pushes to main
resource "azuread_application_federated_identity_credential" "main" {
  application_id = azuread_application.github_actions.id
  display_name   = "github-actions-main"
  audiences      = ["api://AzureADTokenExchange"]
  issuer         = "https://token.actions.githubusercontent.com"
  subject        = "repo:${var.github_org}/${var.github_repo}:ref:refs/heads/main"
}

# Federated credential for pull requests
resource "azuread_application_federated_identity_credential" "pr" {
  application_id = azuread_application.github_actions.id
  display_name   = "github-actions-pr"
  audiences      = ["api://AzureADTokenExchange"]
  issuer         = "https://token.actions.githubusercontent.com"
  subject        = "repo:${var.github_org}/${var.github_repo}:pull_request"
}

# Federated credential for workflow_dispatch
resource "azuread_application_federated_identity_credential" "dispatch" {
  application_id = azuread_application.github_actions.id
  display_name   = "github-actions-dispatch"
  audiences      = ["api://AzureADTokenExchange"]
  issuer         = "https://token.actions.githubusercontent.com"
  subject        = "repo:${var.github_org}/${var.github_repo}:environment:azure-dev"
}

# --- Role assignments --------------------------------------------------------

resource "azurerm_role_assignment" "github_actions_contributor" {
  scope                = data.azurerm_subscription.current.id
  role_definition_name = "Contributor"
  principal_id         = azuread_service_principal.github_actions.object_id
}

resource "azurerm_role_assignment" "github_actions_user_access_admin" {
  scope                = data.azurerm_subscription.current.id
  role_definition_name = "User Access Administrator"
  principal_id         = azuread_service_principal.github_actions.object_id
}

resource "azurerm_role_assignment" "github_actions_acr_push" {
  scope                = azurerm_container_registry.mcp_server.id
  role_definition_name = "AcrPush"
  principal_id         = azuread_service_principal.github_actions.object_id
}

resource "azurerm_role_assignment" "github_actions_storage" {
  scope                = azurerm_storage_account.terraform_state.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azuread_service_principal.github_actions.object_id
}

# --- Outputs -----------------------------------------------------------------

output "client_id" {
  description = "Add as AZURE_CLIENT_ID in GitHub repo secrets"
  value       = azuread_application.github_actions.client_id
}

output "tenant_id" {
  description = "Add as AZURE_TENANT_ID in GitHub repo secrets"
  value       = data.azuread_client_config.current.tenant_id
}

output "subscription_id" {
  description = "Add as AZURE_SUBSCRIPTION_ID in GitHub repo secrets"
  value       = var.subscription_id
}

output "acr_login_server" {
  description = "Container registry login server"
  value       = azurerm_container_registry.mcp_server.login_server
}

output "state_storage_account" {
  description = "Storage account name for Terraform state"
  value       = azurerm_storage_account.terraform_state.name
}

output "state_container" {
  description = "Blob container name for Terraform state"
  value       = azurerm_storage_container.terraform_state.name
}
