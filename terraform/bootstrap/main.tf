# =============================================================================
# BOOTSTRAP - Run this manually ONCE before the pipeline works
# cd terraform/bootstrap && terraform init && terraform apply
# =============================================================================
#
# This creates:
#   1. S3 bucket for Terraform state
#   2. DynamoDB table for state locking
#   3. IAM OIDC provider for GitHub Actions
#   4. IAM role that GitHub Actions assumes
#
# After this runs, grab the role ARN from the output and add it as a
# GitHub Actions secret called AWS_ROLE_ARN.
# =============================================================================

terraform {
  required_version = ">= 1.12.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

variable "aws_region" {
  default = "us-east-1"
}

variable "github_org" {
  description = "Your GitHub username or org"
  type        = string
}

variable "github_repo" {
  description = "Repository name (without org prefix)"
  type        = string
  default     = "mcp-infra"
}

variable "project_name" {
  default = "mcp-infra"
}

# --- S3 bucket for Terraform state -------------------------------------------

resource "aws_s3_bucket" "terraform_state" {
  bucket = "${var.project_name}-tfstate-${data.aws_caller_identity.current.account_id}"

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "terraform_state" {
  bucket                  = aws_s3_bucket.terraform_state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# --- DynamoDB table for state locking ----------------------------------------

resource "aws_dynamodb_table" "terraform_locks" {
  name         = "${var.project_name}-tflock"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }
}

# --- GitHub OIDC provider ----------------------------------------------------

data "aws_caller_identity" "current" {}

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

# --- IAM role for GitHub Actions ---------------------------------------------

data "aws_iam_policy_document" "github_actions_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_org}/${var.github_repo}:*"]
    }
  }
}

resource "aws_iam_role" "github_actions" {
  name               = "${var.project_name}-github-actions"
  assume_role_policy = data.aws_iam_policy_document.github_actions_assume.json
}

# Scope this down as you learn what your infra actually needs
resource "aws_iam_role_policy_attachment" "github_actions" {
  role       = aws_iam_role.github_actions.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

# --- Outputs -----------------------------------------------------------------

output "role_arn" {
  description = "Add this as AWS_ROLE_ARN in your GitHub repo secrets"
  value       = aws_iam_role.github_actions.arn
}

output "state_bucket" {
  description = "Use this in your backend config"
  value       = aws_s3_bucket.terraform_state.id
}

output "lock_table" {
  description = "Use this in your backend config"
  value       = aws_dynamodb_table.terraform_locks.name
}
