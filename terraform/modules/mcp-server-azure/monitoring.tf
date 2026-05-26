resource "azurerm_monitor_action_group" "email" {
  name                = "mcp-server-${var.environment}-email"
  resource_group_name = var.resource_group_name
  short_name          = "mcp-email"

  email_receiver {
    name          = "admin"
    email_address = var.alarm_email
  }
}

resource "azurerm_monitor_metric_alert" "request_errors" {
  name                = "mcp-server-${var.environment}-errors"
  resource_group_name = var.resource_group_name
  scopes              = [azurerm_container_app.mcp_server.id]
  description         = "Alert when Container App request errors exceed threshold"

  criteria {
    metric_namespace = "Microsoft.App/containerApps"
    metric_name      = "Requests"
    aggregation      = "Total"
    operator         = "GreaterThan"
    threshold        = 10

    dimension {
      name     = "statusCodeCategory"
      operator = "Include"
      values   = ["5xx"]
    }
  }

  window_size = "PT5M"
  frequency   = "PT5M"
  severity    = 2

  action {
    action_group_id = azurerm_monitor_action_group.email.id
  }
}
