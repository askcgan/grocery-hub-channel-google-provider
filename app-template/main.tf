# A sample app stack: a Cloud Run service with a Cloud SQL database, its password in Secret Manager, and a bucket
# mounted into the service. Rewritten from the Google Application Design Center export that used to sit at the
# top of this folder. That export would have created, in us-central1:
#   Cloud SQL MySQL, ENTERPRISE_PLUS, db-perf-optimized-N-8 (8 vCPU, 64 GB), REGIONAL (two copies), data cache on
#     → about $1,400–1,600 a month on its own
#   Cloud Run with at least one instance always running plus a Prometheus sidecar → about $15–40 a month
# This version keeps the same shape at a few dollars a month (README.md), and refuses to plan until
# acknowledge_billable_resources = true. Every plan also goes through tools/cost-guard.py (scripts).

# The gate: nothing below is planned until someone states, in terraform.tfvars, that they mean to pay for it.
resource "terraform_data" "billing_acknowledged" {
  lifecycle {
    precondition {
      condition     = var.acknowledge_billable_resources
      error_message = "This stack creates billable resources (Cloud SQL is billed every hour it exists). Set acknowledge_billable_resources = true in terraform.tfvars if you mean to run it; see README.md for the cost."
    }
  }
}

module "web" {
  source       = "github.com/GoogleCloudPlatform/terraform-google-cloud-run//modules/v2?ref=v0.34.1"
  project_id   = var.project_id
  location     = var.region
  service_name = var.service_name
  containers = [
    {
      container_image = var.container_image
      container_name  = "service-container"
      resources = {
        limits = { cpu = "1", memory = "512Mi" }
      }
      env_secret_vars = {
        db_secret_SECRET = module.db-secret.env_vars.SECRET
      }
      env_vars = {
        db_CLOUD_SQL_DATABASE_CONNECTION_NAME = module.db.instance_connection_name
        db_CLOUD_SQL_DATABASE_NAME            = module.db.env_vars.CLOUD_SQL_DATABASE_NAME
      }
      ports = {
        container_port = 8080
      }
      volume_mounts = [{ mount_path = "/cloudsql", name = "cloudsql" }, { mount_path = "/gcs-bucket-vol", name = "gcs-bucket-vol" }]
    },
  ]
  service_account_project_roles = ["roles/secretmanager.secretAccessor", "roles/cloudsql.instanceUser", "roles/cloudsql.client"]
  # Private unless run_invokers says otherwise (the export had no invokers either, but ingress open to all).
  members                       = var.run_invokers
  ingress                       = "INGRESS_TRAFFIC_ALL"
  cloud_run_deletion_protection = false
  # Scale to zero: no always-on instance, no metrics sidecar (each was a standing cost in the export).
  enable_prometheus_sidecar = false
  service_scaling = {
    min_instance_count = 0
  }
  template_scaling = {
    min_instance_count = 0
    max_instance_count = var.run_max_instances
  }
  volumes = [
    { name = "cloudsql", cloud_sql_instance = { instances = [module.db.instance_connection_name] } },
    { name = "gcs-bucket-vol", gcs = { bucket = module.gcs-bucket.name } },
  ]

  depends_on = [terraform_data.billing_acknowledged]
}

module "db-secret" {
  source      = "github.com/GoogleCloudPlatform/terraform-google-secret-manager//modules/simple-secret?ref=v0.9.0"
  project_id  = var.project_id
  name        = var.db_secret_name
  secret_data = module.db.generated_user_password
  depends_on  = [terraform_data.billing_acknowledged]
}

module "db" {
  source           = "github.com/terraform-google-modules/terraform-google-sql-db//modules/mysql?ref=v28.2.0"
  project_id       = var.project_id
  region           = var.region
  name             = var.db_name
  database_version = var.db_database_version
  # ENTERPRISE edition and a small tier (validated in variables.tf); single zone unless asked for.
  edition            = "ENTERPRISE"
  tier               = var.db_tier
  availability_type  = var.db_high_availability ? "REGIONAL" : "ZONAL"
  data_cache_enabled = false
  disk_type          = "PD_SSD"
  disk_size          = 10
  disk_autoresize    = true
  # Growth is capped: an unbounded auto-resize is an unbounded bill.
  disk_autoresize_limit = var.db_disk_limit_gb
  # Both protections on: Terraform refuses to destroy it, and so does Cloud SQL (README.md: how to tear it down).
  deletion_protection         = true
  deletion_protection_enabled = true
  iam_users = [
    {
      email = module.web.service_account_id.email
      id    = module.web.service_account_id.id
      type  = "CLOUD_IAM_SERVICE_ACCOUNT"
    },
  ]
  database_flags = [
    {
      name  = "cloudsql_iam_authentication"
      value = "on"
    },
  ]
  backup_configuration = {
    binary_log_enabled             = true
    enabled                        = true
    retained_backups               = 7
    transaction_log_retention_days = "3"
  }
  ip_configuration = {
    ssl_mode = "ENCRYPTED_ONLY"
  }
  depends_on = [terraform_data.billing_acknowledged]
}

module "gcs-bucket" {
  source     = "github.com/terraform-google-modules/terraform-google-cloud-storage//modules/simple_bucket?ref=v12.3.0"
  project_id = var.project_id
  location   = var.region
  name       = var.bucket_name
  iam_members = [
    {
      member = module.web.service_account_id.member
      role   = "roles/storage.objectAdmin"
    },
  ]
  storage_class            = "STANDARD"
  public_access_prevention = "enforced"
  depends_on               = [terraform_data.billing_acknowledged]
}
