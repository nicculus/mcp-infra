# =============================================================================
# MCP Server Module - Lambda behind API Gateway (zero idle cost)
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

variable "environment" {
  type    = string
  default = "dev"
}

variable "container_image" {
  type        = string
  description = "ECR image URI for the MCP server Lambda"
}

variable "memory_size" {
  type    = number
  default = 512
}

variable "timeout" {
  type    = number
  default = 30
}

variable "allowed_origins" {
  description = "CORS allowed origins. Default '*' allows any origin — restrict in production."
  type        = list(string)
  default     = ["*"]
}

variable "reserved_concurrent_executions" {
  type        = number
  default     = 10
  description = "Max concurrent Lambda executions. Caps cost and blast radius."
}

# --- Data sources ------------------------------------------------------------

data "aws_caller_identity" "current" {}

# --- KMS key (shared across CloudWatch, SNS, Lambda env vars) ----------------

resource "aws_kms_key" "mcp" {
  description             = "mcp-server-${var.environment} encryption key"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "Enable IAM User Permissions"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "Allow CloudWatch Logs"
        Effect = "Allow"
        Principal = {
          Service = "logs.amazonaws.com"
        }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:DescribeKey",
        ]
        Resource = "*"
        Condition = {
          ArnLike = {
            "kms:EncryptionContext:aws:logs:arn" = "arn:aws:logs:*:${data.aws_caller_identity.current.account_id}:*"
          }
        }
      }
    ]
  })
}

resource "aws_kms_alias" "mcp" {
  name          = "alias/mcp-server-${var.environment}"
  target_key_id = aws_kms_key.mcp.key_id
}

# --- Lambda execution role ---------------------------------------------------

resource "aws_iam_role" "lambda" {
  name = "mcp-server-lambda-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "mcp_execution" {
  name = "mcp-execution"
  role = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = "arn:aws:secretsmanager:*:${data.aws_caller_identity.current.account_id}:secret:mcp-infra/*"
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = aws_kms_key.mcp.arn
      },
      {
        Effect   = "Allow"
        Action   = ["sqs:SendMessage"]
        Resource = aws_sqs_queue.dlq.arn
      },
      {
        Effect = "Allow"
        Action = [
          "xray:PutTraceSegments",
          "xray:PutTelemetryRecords",
        ]
        Resource = "*"
      },
    ]
  })
}

moved {
  from = aws_iam_role_policy.mcp_secrets
  to   = aws_iam_role_policy.mcp_execution
}

# --- Dead Letter Queue -------------------------------------------------------

resource "aws_sqs_queue" "dlq" {
  name                      = "mcp-server-${var.environment}-dlq"
  message_retention_seconds = 1209600 # 14 days
  kms_master_key_id         = aws_kms_key.mcp.arn
}

# --- CloudWatch log group ----------------------------------------------------

resource "aws_cloudwatch_log_group" "mcp_server" {
  name              = "/aws/lambda/mcp-server-${var.environment}"
  retention_in_days = 365
  kms_key_id        = aws_kms_key.mcp.arn
}

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
      GITHUB_PAT_SECRET = "mcp-infra/github-pat"
      API_KEY_SECRET    = "mcp-infra/api-key"
    }
  }

  kms_key_arn = aws_kms_key.mcp.arn

  depends_on = [
    aws_iam_role_policy_attachment.lambda_basic,
    aws_cloudwatch_log_group.mcp_server,
  ]
}

# --- Lambda function URL (simplest option, no API GW needed) -----------------
# If you just need an HTTPS endpoint with zero config, use this instead of
# API Gateway. Comment out the API Gateway section below if you prefer this.
#
# resource "aws_lambda_function_url" "mcp_server" {
#   function_name      = aws_lambda_function.mcp_server.function_name
#   authorization_type = "NONE"  # Switch to "AWS_IAM" for auth
# }

# --- API Gateway (HTTP API - cheaper than REST API) --------------------------

resource "aws_apigatewayv2_api" "mcp" {
  name          = "mcp-${var.environment}"
  protocol_type = "HTTP"

  cors_configuration {
    allow_origins = var.allowed_origins
    allow_methods = ["GET", "POST", "OPTIONS"]
    allow_headers = ["Content-Type", "Authorization"]
    max_age       = 3600
  }
}

variable "throttle_rate_limit" {
  type        = number
  default     = 10
  description = "Max sustained requests per second"
}

variable "throttle_burst_limit" {
  type        = number
  default     = 50
  description = "Max concurrent requests (burst)"
}

variable "alarm_email" {
  type        = string
  description = "Email address to notify on Lambda invocation or error spikes"
}

variable "alarm_invocations_threshold" {
  type        = number
  default     = 1000
  description = "Lambda invocations per 5 minutes before alerting"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.mcp.id
  name        = "$default"
  auto_deploy = true

  default_route_settings {
    throttling_rate_limit  = var.throttle_rate_limit
    throttling_burst_limit = var.throttle_burst_limit
  }

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_gw.arn
    format = jsonencode({
      requestId      = "$context.requestId"
      ip             = "$context.identity.sourceIp"
      method         = "$context.httpMethod"
      path           = "$context.path"
      status         = "$context.status"
      responseLength = "$context.responseLength"
      latency        = "$context.integrationLatency"
    })
  }
}

resource "aws_cloudwatch_log_group" "api_gw" {
  name              = "/aws/apigateway/mcp-${var.environment}"
  retention_in_days = 365
  kms_key_id        = aws_kms_key.mcp.arn
}

resource "aws_apigatewayv2_integration" "lambda" {
  api_id                 = aws_apigatewayv2_api.mcp.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.mcp_server.invoke_arn
  integration_method     = "POST"
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "catch_all" {
  # checkov:skip=CKV_AWS_309: Authorization is enforced in Lambda via x-api-key header check, not at the route level
  api_id             = aws_apigatewayv2_api.mcp.id
  route_key          = "$default"
  target             = "integrations/${aws_apigatewayv2_integration.lambda.id}"
  authorization_type = "NONE"
}

resource "aws_lambda_permission" "api_gw" {
  statement_id  = "AllowAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.mcp_server.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.mcp.execution_arn}/*/*"
}

# --- CloudWatch alarms -------------------------------------------------------

resource "aws_sns_topic" "alarms" {
  name              = "mcp-server-alarms-${var.environment}"
  kms_master_key_id = aws_kms_key.mcp.arn
}

resource "aws_sns_topic_subscription" "alarms_email" {
  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

resource "aws_cloudwatch_metric_alarm" "lambda_invocations" {
  alarm_name          = "mcp-server-${var.environment}-invocations"
  alarm_description   = "Lambda invocation spike — possible flood or abuse"
  namespace           = "AWS/Lambda"
  metric_name         = "Invocations"
  dimensions          = { FunctionName = aws_lambda_function.mcp_server.function_name }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = var.alarm_invocations_threshold
  comparison_operator = "GreaterThanThreshold"
  alarm_actions       = [aws_sns_topic.alarms.arn]
  treat_missing_data  = "notBreaching"
}

resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  alarm_name          = "mcp-server-${var.environment}-errors"
  alarm_description   = "Lambda error rate spike"
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = aws_lambda_function.mcp_server.function_name }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 10
  comparison_operator = "GreaterThanThreshold"
  alarm_actions       = [aws_sns_topic.alarms.arn]
  treat_missing_data  = "notBreaching"
}

# --- Outputs -----------------------------------------------------------------

output "api_endpoint" {
  description = "MCP server endpoint URL"
  value       = aws_apigatewayv2_api.mcp.api_endpoint
}

output "lambda_function_name" {
  value = aws_lambda_function.mcp_server.function_name
}
