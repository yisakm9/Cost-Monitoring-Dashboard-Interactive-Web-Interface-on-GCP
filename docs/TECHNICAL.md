# Technical Implementation Guide

This document details the technical implementation, configuration instructions, and operational procedures for the GCP Cloud Cost Calculator.

## 1. System Components

### 1.1 Serverless Compute (Cloud Functions Gen2)
The application relies on two Gen2 Cloud Functions, which run as managed Knative services on Cloud Run.
*   **`get_cost_api`**: An HTTP-triggered function that serves as the backend for the React/Vanilla JS frontend. It accepts cross-origin resource sharing (CORS) requests, executes a parameter-safe query against the BigQuery billing export, and returns a JSON payload detailing costs by service.
*   **`get_cost_report`**: An Eventarc/PubSub-triggered function invoked by Cloud Scheduler. It queries the same BigQuery dataset to compile a weekly summary, formats the data into a responsive HTML email, and dispatches it via the SendGrid API.

### 1.2 Global Load Balancing & Storage
*   **Cloud Storage Bucket**: A GCS bucket configured with uniform bucket-level access hosts the static frontend assets (`index.html`, `script.js`, `style.css`). It is configured with `website { main_page_suffix = "index.html" }` to ensure root requests resolve correctly.
*   **Global External HTTP(S) Load Balancer**: Routes incoming internet traffic. Path matching sends `/` and frontend asset requests to the Cloud Storage Backend Bucket, while `/costs` requests are routed to a Serverless Network Endpoint Group (NEG) attached to the `get_cost_api` function.

### 1.3 Monitoring & Alerting
*   **Cloud Billing Budget**: Configured via Terraform to track actual spend against a defined limit. It publishes messages to a Pub/Sub topic when spend exceeds 50%, 80%, and 100%.
*   **Cloud Monitoring**: A Notification Channel (Email) is linked to Alert Policies. Specifically, a Pub/Sub-triggered alert policy listens to the budget topic and dispatches an email via GCP's native alerting mechanism.

## 2. Infrastructure as Code (Terraform)

The infrastructure is broken down into highly cohesive, decoupled modules:
1.  **`apis`**: Enables 18 necessary GCP Service APIs.
2.  **`iam`**: Provisions two Service Accounts (`cost-api-sa` and `cost-report-sa`) with least privilege (e.g., BigQuery Data Viewer, Job User, Secret Manager Secret Accessor).
3.  **`kms`**: Creates a KeyRing and CryptoKey with a 90-day automatic rotation period for encrypting resources where CMEK (Customer-Managed Encryption Keys) is supported.
4.  **`storage`**: Creates the frontend hosting bucket and configures CORS and public object viewing.
5.  **`cloud_functions`**: Deploys the Python code from `src/functions` to GCS, then provisions the Gen2 functions. Includes Eventarc IAM bindings (`roles/run.invoker`) for the default compute service account to allow Pub/Sub triggers.
6.  **`load_balancer`**: Provisions the URL map, target proxies, forwarding rules, and backend services/buckets.
7.  **`pubsub`**: Creates the event topics for budget alerts and report scheduling.
8.  **`scheduler`**: Creates a cron job (`0 8 * * 1`) that pushes an empty payload to the report Pub/Sub topic.
9.  **`monitoring`**: Configures the budget, notification channels, and alert policies.

## 3. Deployment Pipeline (GitHub Actions)

The CI/CD pipeline uses Workload Identity Federation (WIF) to avoid storing long-lived service account keys in GitHub Secrets.

### Pipeline Stages:
1.  **Terraform Format & Validate**: Ensures HCL code meets style guidelines.
2.  **TFLint & Checkov**: Performs static analysis and security scanning on the Terraform code to prevent misconfigurations (e.g., open firewalls, missing encryption).
3.  **Terraform Plan & Apply**: Executes the infrastructure provisioning.
4.  **Frontend Deployment**: Uses `gsutil rsync` to sync `frontend/public/` to the GCS bucket. Crucially, it uses `sed` to inject the dynamically generated Cloud Function API URL into `script.js` before uploading, ensuring the frontend knows where to fetch data.

## 4. Manual Post-Deployment Steps

While the infrastructure is 99% automated, two manual steps are required due to GCP API limitations:

1.  **BigQuery Billing Export**: Billing exports must be configured in the GCP Console at the **Billing Account** level. You must create the `billing_export` dataset and configure the billing account to export "Standard usage cost" to it.
2.  **SendGrid API Key**: You must inject your real SendGrid API key into Secret Manager:
    ```bash
    echo -n "SG.your_actual_api_key" | gcloud secrets versions add costcalc-dev-sendgrid-key --data-file=-
    ```

## 5. Troubleshooting Guide

*   **API returns 500 Error**: Verify that the BigQuery billing export table exists. If the table is missing, ensure the billing export was set up in the GCP Console.
*   **Dashboard shows XML instead of website**: Ensure the Storage Bucket has the `website` configuration applied. Cache invalidation on the Load Balancer may take 5-10 minutes.
*   **Email Reports not arriving**: Check the logs for `get_cost_report` (`gcloud functions logs read costcalc-dev-get-cost-report`). Look for `401 Unauthorized` (Eventarc IAM issue) or SendGrid authentication failures (Secret Manager key is invalid).
*   **Budget Deployment Failure (Invalid Argument)**: Ensure the `currency_code` in `modules/monitoring/main.tf` matches the native currency of your GCP Billing Account (e.g., `USD` vs `HKD`).
