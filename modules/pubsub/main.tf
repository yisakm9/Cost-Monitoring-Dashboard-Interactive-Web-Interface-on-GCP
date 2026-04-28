# modules/pubsub/main.tf
#
# Creates Pub/Sub topics for event-driven communication.
# - Report trigger topic: Cloud Scheduler → Cloud Function
# - Budget alert topic: Cloud Billing Budget → Notification

resource "google_pubsub_topic" "report_trigger" {
  project = var.project_id
  name    = "${var.name_prefix}-report-trigger"
  labels  = var.labels

  message_retention_duration = "86400s" # 24 hours
}

resource "google_pubsub_topic" "budget_alerts" {
  project = var.project_id
  name    = "${var.name_prefix}-budget-alerts"
  labels  = var.labels

  message_retention_duration = "86400s"
}

# Grant the Cloud Billing service account permission to publish
# budget alert messages to the Pub/Sub topic.
resource "google_pubsub_topic_iam_member" "billing_publisher" {
  project = var.project_id
  topic   = google_pubsub_topic.budget_alerts.name
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:service-${var.project_number}@gcp-sa-cloudbilling.iam.gserviceaccount.com"
}
