# modules/monitoring/main.tf
#
# Configures Cloud Monitoring for the cost calculator:
#   - Budget alert via Cloud Billing Budget API
#   - Email notification channel
#   - Uptime check for the dashboard
#   - Alert policies for function errors and LB health

# ──────────────────────────────────────────────
#  Email Notification Channel
# ──────────────────────────────────────────────
resource "google_monitoring_notification_channel" "email" {
  project      = var.project_id
  display_name = "Cost Calculator Alert Email"
  type         = "email"

  labels = {
    email_address = var.alert_email
  }

  force_delete = true
}

# ──────────────────────────────────────────────
#  Cloud Billing Budget (GCP equivalent of CloudWatch Billing Alarm)
# ──────────────────────────────────────────────
resource "google_billing_budget" "monthly_budget" {
  billing_account = var.billing_account_id
  display_name    = "${var.name_prefix}-monthly-budget"

  amount {
    specified_amount {
      currency_code = "USD"
      units         = tostring(var.budget_amount)
    }
  }

  # Alert at 50%, 80%, and 100% of budget
  threshold_rules {
    threshold_percent = 0.5
    spend_basis       = "CURRENT_SPEND"
  }

  threshold_rules {
    threshold_percent = 0.8
    spend_basis       = "CURRENT_SPEND"
  }

  threshold_rules {
    threshold_percent = 1.0
    spend_basis       = "CURRENT_SPEND"
  }

  # Also alert when forecasted spend exceeds budget
  threshold_rules {
    threshold_percent = 1.0
    spend_basis       = "FORECASTED_SPEND"
  }

  all_updates_rule {
    monitoring_notification_channels = [
      google_monitoring_notification_channel.email.id
    ]
    schema_version = "1.0"
  }
}

# ──────────────────────────────────────────────
#  Uptime Check — Dashboard Availability
# ──────────────────────────────────────────────
resource "google_monitoring_uptime_check_config" "dashboard" {
  project      = var.project_id
  display_name = "${var.name_prefix}-dashboard-uptime"
  timeout      = "10s"
  period       = "300s" # Every 5 minutes

  http_check {
    path         = "/index.html"
    port         = 80
    use_ssl      = false
    validate_ssl = false
  }

  monitored_resource {
    type = "uptime_url"
    labels = {
      project_id = var.project_id
      host       = var.load_balancer_ip
    }
  }
}

# ──────────────────────────────────────────────
#  Alert Policy — Dashboard Down
# ──────────────────────────────────────────────
resource "google_monitoring_alert_policy" "dashboard_down" {
  project      = var.project_id
  display_name = "${var.name_prefix}-dashboard-down"
  combiner     = "OR"

  conditions {
    display_name = "Dashboard Uptime Check Failed"

    condition_threshold {
      filter          = "resource.type = \"uptime_url\" AND metric.type = \"monitoring.googleapis.com/uptime_check/check_passed\" AND metric.labels.check_id = \"${google_monitoring_uptime_check_config.dashboard.uptime_check_id}\""
      comparison      = "COMPARISON_GT"
      threshold_value = 1
      duration        = "300s"

      trigger {
        count = 1
      }

      aggregations {
        alignment_period     = "300s"
        per_series_aligner   = "ALIGN_NEXT_OLDER"
        cross_series_reducer = "REDUCE_COUNT_FALSE"
        group_by_fields      = ["resource.label.project_id"]
      }
    }
  }

  notification_channels = [
    google_monitoring_notification_channel.email.id
  ]

  alert_strategy {
    auto_close = "604800s" # 7 days
  }

  documentation {
    content   = "The Cloud Cost Calculator dashboard is unreachable. Check the Load Balancer and Cloud Storage bucket configuration."
    mime_type = "text/markdown"
  }
}

# ──────────────────────────────────────────────
#  Alert Policy — Cloud Function Errors
# ──────────────────────────────────────────────
resource "google_monitoring_alert_policy" "function_errors" {
  project      = var.project_id
  display_name = "${var.name_prefix}-function-errors"
  combiner     = "OR"

  conditions {
    display_name = "Cloud Function Execution Errors"

    condition_threshold {
      filter          = "resource.type = \"cloud_function\" AND metric.type = \"cloudfunctions.googleapis.com/function/execution_count\" AND metric.labels.status != \"ok\""
      comparison      = "COMPARISON_GT"
      threshold_value = 5
      duration        = "300s"

      trigger {
        count = 1
      }

      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_RATE"
      }
    }
  }

  notification_channels = [
    google_monitoring_notification_channel.email.id
  ]

  alert_strategy {
    auto_close = "604800s"
  }

  documentation {
    content   = "One or more Cloud Functions in the Cost Calculator are experiencing elevated error rates. Check Cloud Logging for details."
    mime_type = "text/markdown"
  }
}
