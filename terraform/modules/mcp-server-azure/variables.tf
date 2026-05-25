variable "resource_group_name" {
  description = "Azure resource group name"
  type        = string
}

variable "location" {
  description = "Azure region"
  type        = string
  default     = "eastus"
}

variable "environment" {
  description = "Deployment environment"
  type        = string
  default     = "dev"
  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "Environment must be dev, staging, or prod."
  }
}

variable "container_image" {
  description = "Full container image URI (including tag)"
  type        = string
}

variable "memory_size" {
  description = "Memory allocation (e.g. '0.5Gi', '1Gi')"
  type        = string
  default     = "0.5Gi"
}

variable "cpu" {
  description = "CPU allocation (e.g. 0.25, 0.5, 1.0)"
  type        = number
  default     = 0.25
}

variable "max_replicas" {
  description = "Maximum number of Container App replicas"
  type        = number
  default     = 10
  validation {
    condition     = var.max_replicas >= 1 && var.max_replicas <= 300
    error_message = "Max replicas must be between 1 and 300."
  }
}

variable "acr_login_server" {
  description = "Azure Container Registry login server (e.g. myregistry.azurecr.io)"
  type        = string
}

variable "alarm_email" {
  description = "Email address for monitoring alert notifications"
  type        = string
}
