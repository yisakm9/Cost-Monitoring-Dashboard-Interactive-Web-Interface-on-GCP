# environments/dev/main.tf
#
# Root module — Composes all 9 Terraform modules into a complete
# GCP Cloud Cost Calculator infrastructure.

# ──────────────────────────────────────────────
#  Random suffix for globally unique names
# ──────────────────────────────────────────────
resource "random_id" "suffix" {
  byte_length = 4
}

locals {
  name_prefix = "${var.app_name}-${var.environment}"
  labels = {
    project     = var.app_name
    environment = var.environment
    managed_by  = "terraform"
  }
}

# ──────────────────────────────────────────────
#  Data Sources
# ──────────────────────────────────────────────
data "google_project" "current" {
  project_id = var.project_id
}

# ──────────────────────────────────────────────
#  1. Enable Required GCP APIs
# ──────────────────────────────────────────────
module "apis" {
  source     = "../../modules/apis"
  project_id = var.project_id
}

# ──────────────────────────────────────────────
#  2. IAM — Service Accounts with Least Privilege
# ──────────────────────────────────────────────
module "iam" {
  source      = "../../modules/iam"
  project_id  = var.project_id
  name_prefix = local.name_prefix

  depends_on = [module.apis]
}

# ──────────────────────────────────────────────
#  3. Cloud KMS — Encryption Key Management
# ──────────────────────────────────────────────
module "kms" {
  source      = "../../modules/kms"
  project_id  = var.project_id
  region      = var.region
  name_prefix = local.name_prefix
  labels      = local.labels

  depends_on = [module.apis]
}

# ──────────────────────────────────────────────
#  4. Secret Manager — SendGrid API Key
# ──────────────────────────────────────────────
resource "google_secret_manager_secret" "sendgrid_api_key" {
  project   = var.project_id
  secret_id = "${local.name_prefix}-sendgrid-key"

  replication {
    auto {}
  }

  labels = local.labels

  depends_on = [module.apis]
}

# Note: The secret VERSION must be created manually or via CLI:
#   gcloud secrets versions add costcalc-dev-sendgrid-key \
#     --data-file=- <<< "YOUR_SENDGRID_API_KEY"

# ──────────────────────────────────────────────
#  5. Pub/Sub — Event-Driven Messaging
# ──────────────────────────────────────────────
module "pubsub" {
  source      = "../../modules/pubsub"
  project_id  = var.project_id
  project_number = data.google_project.current.number
  name_prefix = local.name_prefix
  labels      = local.labels

  depends_on = [module.apis]
}

# ──────────────────────────────────────────────
#  6. Cloud Storage — Frontend Static Assets
# ──────────────────────────────────────────────
module "storage" {
  source      = "../../modules/storage"
  project_id  = var.project_id
  region      = var.region
  name_prefix = local.name_prefix
  suffix      = random_id.suffix.hex
  labels      = local.labels

  depends_on = [module.apis]
}

# ──────────────────────────────────────────────
#  7. Cloud Functions — Serverless Compute
# ──────────────────────────────────────────────
module "cloud_functions" {
  source      = "../../modules/cloud_functions"
  project_id  = var.project_id
  region      = var.region
  name_prefix = local.name_prefix
  suffix      = random_id.suffix.hex

  # Service Accounts
  cost_api_sa_email    = module.iam.cost_api_sa_email
  cost_report_sa_email = module.iam.cost_report_sa_email

  # Source Code Paths
  cost_api_source_path    = abspath("${path.root}/../../src/functions/get_cost_api/")
  cost_report_source_path = abspath("${path.root}/../../src/functions/get_cost_report/")

  # BigQuery Billing Export Configuration
  billing_project_id = var.billing_project_id
  billing_dataset_id = var.billing_dataset_id
  billing_table_id   = var.billing_table_id

  # Email Configuration
  sender_email         = var.notification_email
  recipient_email      = var.notification_email
  sendgrid_secret_name = google_secret_manager_secret.sendgrid_api_key.secret_id

  # Pub/Sub Trigger
  report_trigger_topic_id = module.pubsub.report_trigger_topic_id

  labels = local.labels

  depends_on = [module.apis, module.iam, module.pubsub]
}

# ──────────────────────────────────────────────
#  8. Global HTTP(S) Load Balancer + Cloud CDN
# ──────────────────────────────────────────────
module "load_balancer" {
  source      = "../../modules/load_balancer"
  project_id  = var.project_id
  region      = var.region
  name_prefix = local.name_prefix

  frontend_bucket_name   = module.storage.bucket_name
  cost_api_function_name = module.cloud_functions.cost_api_function_name

  depends_on = [module.storage, module.cloud_functions]
}

# ──────────────────────────────────────────────
#  9. Cloud Scheduler — Weekly Report Trigger
# ──────────────────────────────────────────────
module "scheduler" {
  source      = "../../modules/scheduler"
  project_id  = var.project_id
  region      = var.region
  name_prefix = local.name_prefix

  pubsub_topic_id = module.pubsub.report_trigger_topic_id
  schedule        = var.report_schedule

  depends_on = [module.pubsub, module.cloud_functions]
}

# ──────────────────────────────────────────────
#  10. Cloud Monitoring — Alerts & Budgets
# ──────────────────────────────────────────────
module "monitoring" {
  source         = "../../modules/monitoring"
  project_id     = var.project_id
  project_number = data.google_project.current.number
  name_prefix    = local.name_prefix

  alert_email            = var.notification_email
  billing_account_id     = var.billing_account_id
  budget_amount          = var.budget_amount
  budget_alerts_topic_id = module.pubsub.budget_alerts_topic_id
  load_balancer_ip       = module.load_balancer.load_balancer_ip

  depends_on = [module.load_balancer, module.pubsub]
}
