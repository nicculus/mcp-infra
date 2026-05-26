# =============================================================================
# MCP Server Module — Variable declarations
# =============================================================================

# --- Compute -----------------------------------------------------------------

variable "container_image" {
  type        = string
  description = "ECR image URI for the MCP server Lambda"
}

variable "memory_size" {
  description = "Memory limit in MiB"
  type        = number
  default     = 512

  validation {
    condition     = var.memory_size >= 128 && var.memory_size <= 10240
    error_message = "Lambda memory must be between 128 and 10240 MB."
  }
}

variable "timeout" {
  description = "Request timeout in seconds"
  type        = number
  default     = 30

  validation {
    condition     = var.timeout >= 1 && var.timeout <= 900
    error_message = "Lambda timeout must be between 1 and 900 seconds."
  }
}

variable "reserved_concurrent_executions" {
  type        = number
  default     = 10
  description = "Max concurrent Lambda executions. Caps cost and blast radius."

  validation {
    condition     = var.reserved_concurrent_executions >= 1 && var.reserved_concurrent_executions <= 1000
    error_message = "Reserved concurrency must be between 1 and 1000."
  }
}

# --- Environment -------------------------------------------------------------

variable "environment" {
  description = "Deployment environment"
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "Environment must be dev, staging, or prod."
  }
}

# --- Networking / API Gateway ------------------------------------------------

variable "allowed_origins" {
  description = "CORS allowed origins. Default '*' allows any origin — restrict in production."
  type        = list(string)
  default     = ["*"]
}

variable "throttle_rate_limit" {
  type        = number
  default     = 10
  description = "Max sustained requests per second"

  validation {
    condition     = var.throttle_rate_limit >= 1
    error_message = "Throttle rate limit must be at least 1."
  }
}

variable "throttle_burst_limit" {
  type        = number
  default     = 50
  description = "Max concurrent requests (burst)"

  validation {
    condition     = var.throttle_burst_limit >= 1
    error_message = "Throttle burst limit must be at least 1."
  }
}

# --- Monitoring --------------------------------------------------------------

variable "alarm_email" {
  type        = string
  description = "Email address to notify on Lambda invocation or error spikes"
}

variable "alarm_invocations_threshold" {
  type        = number
  default     = 1000
  description = "Lambda invocations per 5 minutes before alerting"
}
