# =============================================================================
# MCP Server Module — Outputs
# =============================================================================

output "api_endpoint" {
  description = "MCP server endpoint URL"
  value       = aws_apigatewayv2_api.mcp.api_endpoint
}

output "lambda_function_name" {
  value = aws_lambda_function.mcp_server.function_name
}

output "lambda_execution_role_arn" {
  description = "ARN of the Lambda execution role (used to grant ECR pull access)"
  value       = aws_iam_role.lambda.arn
}
