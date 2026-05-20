# =============================================================================
# DEV ENVIRONMENT - Serverless (Lambda + API Gateway)
# =============================================================================
# After running bootstrap, fill in the backend config below with the
# bucket name from the bootstrap outputs.
# =============================================================================

terraform {
  required_version = ">= 1.12.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket         = "REPLACE-WITH-BOOTSTRAP-OUTPUT"  # state_bucket output
    key            = "dev/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "mcp-infra-tflock"
    encrypt        = true
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
  default = "us-east-1"
}

# --- ECR repository for MCP server images ------------------------------------

resource "aws_ecr_repository" "mcp_server" {
  name                 = "mcp-server"
  image_tag_mutability = "MUTABLE"
  force_delete         = true  # Dev only - remove for prod

  image_scanning_configuration {
    scan_on_push = true
  }
}

# --- MCP server (Lambda + API Gateway) ---------------------------------------

module "mcp_server" {
  source = "../../modules/mcp-server"

  container_image = "${aws_ecr_repository.mcp_server.repository_url}:latest"
  environment     = "dev"
  memory_size     = 512
  timeout         = 30
}

# --- Outputs -----------------------------------------------------------------

output "ecr_repository_url" {
  value = aws_ecr_repository.mcp_server.repository_url
}

output "mcp_endpoint" {
  value = module.mcp_server.api_endpoint
}
