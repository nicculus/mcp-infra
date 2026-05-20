# =============================================================================
# MCP Server Module - Lambda behind API Gateway (zero idle cost)
# =============================================================================

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

# --- Data sources ------------------------------------------------------------

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

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

resource "aws_iam_role_policy" "mcp_secrets" {
  name = "mcp-secrets"
  role = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = "arn:aws:secretsmanager:*:${data.aws_caller_identity.current.account_id}:secret:mcp-infra/*"
    }]
  })
}

# --- CloudWatch log group ----------------------------------------------------

resource "aws_cloudwatch_log_group" "mcp_server" {
  name              = "/aws/lambda/mcp-server-${var.environment}"
  retention_in_days = 14
}

# --- Lambda function (container image) ---------------------------------------

resource "aws_lambda_function" "mcp_server" {
  function_name = "mcp-server-${var.environment}"
  role          = aws_iam_role.lambda.arn
  package_type  = "Image"
  image_uri     = var.container_image
  memory_size   = var.memory_size
  timeout       = var.timeout

  environment {
    variables = {
      ENVIRONMENT       = var.environment
      GITHUB_PAT_SECRET = "mcp-infra/github-pat"
    }
  }

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
    allow_origins = ["*"]
    allow_methods = ["GET", "POST", "OPTIONS"]
    allow_headers = ["Content-Type", "Authorization"]
    max_age       = 3600
  }
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.mcp.id
  name        = "$default"
  auto_deploy = true

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
  retention_in_days = 14
}

resource "aws_apigatewayv2_integration" "lambda" {
  api_id                 = aws_apigatewayv2_api.mcp.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.mcp_server.invoke_arn
  integration_method     = "POST"
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "catch_all" {
  api_id    = aws_apigatewayv2_api.mcp.id
  route_key = "$default"
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}

resource "aws_lambda_permission" "api_gw" {
  statement_id  = "AllowAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.mcp_server.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.mcp.execution_arn}/*/*"
}

# --- Outputs -----------------------------------------------------------------

output "api_endpoint" {
  description = "MCP server endpoint URL"
  value       = aws_apigatewayv2_api.mcp.api_endpoint
}

output "lambda_function_name" {
  value = aws_lambda_function.mcp_server.function_name
}
