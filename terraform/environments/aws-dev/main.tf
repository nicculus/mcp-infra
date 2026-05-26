# =============================================================================
# DEV ENVIRONMENT - Serverless (Lambda + API Gateway)
# =============================================================================
# Phase 1 hardening complete: KMS, DLQ, X-Ray, immutable ECR tags, tflint, checkov.
# Backend config is intentionally partial — bucket and region are resolved at
# init time. In CI the bucket name is derived from the AWS account ID via
# `aws sts get-caller-identity`; locally, pass a .tfbackend file
# (see backend.tfbackend.example).
# =============================================================================

terraform {
  required_version = ">= 1.12.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.100"
    }
  }

  backend "s3" {
    key          = "dev/terraform.tfstate"
    use_lockfile = true
    encrypt      = true
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "mcp-infra"
      Environment = "dev"
      ManagedBy   = "terraform"
    }
  }
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

# --- ECR repository for MCP server images ------------------------------------

resource "aws_ecr_repository" "mcp_server" {
  name                 = "mcp-server"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = var.ecr_force_delete

  encryption_configuration {
    encryption_type = "KMS"
  }

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "mcp_server" {
  repository = aws_ecr_repository.mcp_server.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep only the 10 most recent images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 10
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}

resource "aws_ecr_repository_policy" "mcp_server" {
  repository = aws_ecr_repository.mcp_server.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "LambdaECRImageRetrievalPolicy"
        Effect = "Allow"
        Principal = {
          AWS = module.mcp_server.lambda_execution_role_arn
        }
        Action = [
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:BatchCheckLayerAvailability",
        ]
      }
    ]
  })
}

# --- MCP server (Lambda + API Gateway) ---------------------------------------

variable "alarm_email" {
  description = "Email address for CloudWatch alarm notifications"
  type        = string
}

variable "ecr_force_delete" {
  description = "Allow terraform destroy to delete ECR repo with existing images. Only enable in dev."
  type        = bool
  default     = true # Dev only — set to false in prod
}

module "mcp_server" {
  source = "../../modules/mcp-server-aws"

  container_image = "${aws_ecr_repository.mcp_server.repository_url}:latest"
  environment     = "dev"
  memory_size     = 512
  timeout         = 30
  alarm_email     = var.alarm_email
}

# --- Outputs -----------------------------------------------------------------

output "ecr_repository_url" {
  value = aws_ecr_repository.mcp_server.repository_url
}

output "mcp_endpoint" {
  value = module.mcp_server.service_url
}
