# --- Email notification channel ----------------------------------------------

resource "google_monitoring_notification_channel" "email" {
  display_name = "mcp-server-${var.environment}-email"
  type         = "email"

  labels = {
    email_address = var.alarm_email
  }
}

# --- Alert: high error rate --------------------------------------------------

resource "google_monitoring_alert_policy" "error_rate" {
  display_name = "mcp-server-${var.environment}-errors"
  combiner     = "OR"

  conditions {
    display_name = "Cloud Run request errors > 10 in 5 min"

    condition_threshold {
      filter          = "resource.type=\"cloud_run_revision\" AND resource.labels.service_name=\"mcp-server-${var.environment}\" AND metric.type=\"run.googleapis.com/request_count\" AND metric.labels.response_code_class!=\"2xx\""
      duration        = "300s"
      comparison      = "COMPARISON_GT"
      threshold_value = 10

      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_SUM"
      }
    }
  }

  notification_channels = [google_monitoring_notification_channel.email.name]

  alert_strategy {
    auto_close = "1800s"
  }
}

# --- Alert: high request volume ----------------------------------------------

resource "google_monitoring_alert_policy" "request_volume" {
  display_name = "mcp-server-${var.environment}-high-traffic"
  combiner     = "OR"

  conditions {
    display_name = "Cloud Run requests > 1000 in 5 min"

    condition_threshold {
      filter          = "resource.type=\"cloud_run_revision\" AND resource.labels.service_name=\"mcp-server-${var.environment}\" AND metric.type=\"run.googleapis.com/request_count\""
      duration        = "300s"
      comparison      = "COMPARISON_GT"
      threshold_value = 1000

      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_SUM"
      }
    }
  }

  notification_channels = [google_monitoring_notification_channel.email.name]

  alert_strategy {
    auto_close = "1800s"
  }
}
