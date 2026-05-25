variable "gcp_project_id" {
  description = "GCP project ID"
  type        = string
}

variable "gcp_region" {
  description = "GCP region for Cloud Run and other resources"
  type        = string
  default     = "us-central1"
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
  description = "Memory limit in MiB"
  type        = number
  default     = 512
  validation {
    condition     = var.memory_size >= 128 && var.memory_size <= 32768
    error_message = "Memory must be between 128 and 32768 MiB."
  }
}

variable "cpu" {
  description = "CPU allocation (e.g. '1', '2')"
  type        = string
  default     = "1"
}

variable "timeout" {
  description = "Request timeout in seconds"
  type        = number
  default     = 30
  validation {
    condition     = var.timeout >= 1 && var.timeout <= 3600
    error_message = "Timeout must be between 1 and 3600 seconds."
  }
}

variable "max_instances" {
  description = "Maximum number of Cloud Run instances"
  type        = number
  default     = 10
  validation {
    condition     = var.max_instances >= 1 && var.max_instances <= 1000
    error_message = "Max instances must be between 1 and 1000."
  }
}

variable "alarm_email" {
  description = "Email address for monitoring alert notifications"
  type        = string
}
