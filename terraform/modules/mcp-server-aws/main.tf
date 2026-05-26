# =============================================================================
# MCP Server Module - Lambda behind API Gateway (zero idle cost)
# =============================================================================

terraform {
  required_version = ">= 1.12.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.100"
    }
  }
}

# --- Data sources ------------------------------------------------------------

data "aws_caller_identity" "current" {}

# --- Lambda function (container image) ---------------------------------------

resource "aws_lambda_function" "mcp_server" {
  function_name = "mcp-server-${var.environment}"
  role          = aws_iam_role.lambda.arn
  package_type  = "Image"
  image_uri     = var.container_image
  memory_size   = var.memory_size
  timeout       = var.timeout

  # checkov:skip=CKV_AWS_117: Lambda VPC requires NAT gateway (~$32/month) which breaks the zero-cost promise
  # checkov:skip=CKV_AWS_272: Code-signing is an enterprise feature out of scope for this template

  reserved_concurrent_executions = var.reserved_concurrent_executions

  tracing_config {
    mode = "Active"
  }

  dead_letter_config {
    target_arn = aws_sqs_queue.dlq.arn
  }

  environment {
    variables = {
      ENVIRONMENT       = var.environment
      CLOUD_PROVIDER    = "aws"
      GITHUB_PAT_SECRET = "mcp-infra/github-pat"
      API_KEY_SECRET    = "mcp-infra/api-key"
    }
  }

  kms_key_arn = aws_kms_key.mcp.arn

  # image_uri is managed by the deploy-image workflow (SHA-tagged pushes).
  # Terraform only sets it on creation; subsequent image updates go through
  # `aws lambda update-function-code` in CI, not through Terraform.
  lifecycle {
    ignore_changes = [image_uri]
  }

  depends_on = [
    aws_iam_role_policy_attachment.lambda_basic,
    aws_cloudwatch_log_group.mcp_server,
  ]
}
