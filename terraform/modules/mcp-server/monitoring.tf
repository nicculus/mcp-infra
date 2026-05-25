# =============================================================================
# MCP Server Module — CloudWatch log groups, alarms, SNS, DLQ
# =============================================================================

# --- Dead Letter Queue -------------------------------------------------------

resource "aws_sqs_queue" "dlq" {
  name                      = "mcp-server-${var.environment}-dlq"
  message_retention_seconds = 1209600 # 14 days
  kms_master_key_id         = aws_kms_key.mcp.arn
}

# --- CloudWatch log groups ---------------------------------------------------

resource "aws_cloudwatch_log_group" "mcp_server" {
  name              = "/aws/lambda/mcp-server-${var.environment}"
  retention_in_days = 365
  kms_key_id        = aws_kms_key.mcp.arn
}

resource "aws_cloudwatch_log_group" "api_gw" {
  name              = "/aws/apigateway/mcp-${var.environment}"
  retention_in_days = 365
  kms_key_id        = aws_kms_key.mcp.arn
}

# --- SNS topic and email subscription ----------------------------------------

resource "aws_sns_topic" "alarms" {
  name              = "mcp-server-alarms-${var.environment}"
  kms_master_key_id = aws_kms_key.mcp.arn
}

resource "aws_sns_topic_subscription" "alarms_email" {
  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

# --- CloudWatch alarms -------------------------------------------------------

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
