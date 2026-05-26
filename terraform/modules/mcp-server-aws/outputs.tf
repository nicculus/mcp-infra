# =============================================================================
# MCP Server Module — Outputs
# =============================================================================

output "service_url" {
  description = "MCP server base URL (shared output name across all cloud modules)"
  value       = aws_apigatewayv2_api.mcp.api_endpoint
}

output "api_endpoint" {
  description = "MCP server endpoint URL (alias for service_url)"
  value       = aws_apigatewayv2_api.mcp.api_endpoint
}

output "lambda_function_name" {
  description = "Lambda function name"
  value       = aws_lambda_function.mcp_server.function_name
}

output "lambda_execution_role_arn" {
  description = "ARN of the Lambda execution role (used to grant ECR pull access)"
  value       = aws_iam_role.lambda.arn
}
