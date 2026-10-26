# ---- the gate ------------------------------------------------------------------------------------------------------

variable "acknowledge_billable_resources" {
  description = "Must be true to plan or apply. This stack creates a Cloud SQL instance (billed every hour it exists, about $9–25 a month at the allowed tiers), a Cloud Run service, a secret and a bucket. Set it in terraform.tfvars only when you mean to run them."
  type        = bool
  default     = false
}

# ---- where -------------------------------------------------------------------------------------------------------

variable "project_id" {
  description = "Project to deploy to."
  type        = string
  default     = "groceryhub-channel"
}

variable "region" {
  description = "Region for every resource (Cloud SQL, Cloud Run, bucket)."
  type        = string
  default     = "us-central1"
}

# ---- web: Cloud Run ----------------------------------------------------------------------------------------------

variable "service_name" {
  description = "Cloud Run service name."
  type        = string
  default     = "test-service"
}

variable "container_image" {
  description = "Image to run (Google's hello container until there is a real one)."
  type        = string
  default     = "us-docker.pkg.dev/cloudrun/container/hello"
}

variable "run_max_instances" {
  description = "Most instances Cloud Run may start; caps the bill under load."
  type        = number
  default     = 2
  validation {
    condition     = var.run_max_instances >= 1 && var.run_max_instances <= 10
    error_message = "run_max_instances must be 1 to 10."
  }
}

variable "run_invokers" {
  description = "Who may call the service (e.g. [\"user:someone@example.com\"]). Empty = private. \"allUsers\" makes it public."
  type        = list(string)
  default     = []
}

# ---- db: Cloud SQL -----------------------------------------------------------------------------------------------

variable "db_name" {
  description = "Cloud SQL instance name."
  type        = string
  default     = "poc-db"
}

variable "db_database_version" {
  description = "Engine and version. The platform's own database is PostgreSQL (POSTGRES_16); this template was generated for MySQL."
  type        = string
  default     = "MYSQL_8_0"
}

variable "db_tier" {
  description = "Machine tier. Only small tiers are allowed: shared-core db-f1-micro (about $9/month) and db-g1-small (about $25/month), or 1–2 vCPU custom tiers."
  type        = string
  default     = "db-f1-micro"
  validation {
    condition     = can(regex("^(db-f1-micro|db-g1-small|db-custom-[12]-[0-9]+)$", var.db_tier))
    error_message = "db_tier must be db-f1-micro, db-g1-small or db-custom-1-…/db-custom-2-…. Larger tiers cost hundreds of dollars a month: change this rule deliberately, with a cost review."
  }
}

variable "db_high_availability" {
  description = "Regional (two-zone) instance. Doubles the database cost; for production only."
  type        = bool
  default     = false
}

variable "db_disk_limit_gb" {
  description = "Most the disk may auto-grow to (GB)."
  type        = number
  default     = 20
}

variable "db_secret_name" {
  description = "Secret Manager secret holding the generated database password."
  type        = string
  default     = "poc-db-pass"
}

# ---- bucket ------------------------------------------------------------------------------------------------------

variable "bucket_name" {
  description = "Bucket mounted into the service."
  type        = string
  default     = "groceryhub-storage"
}
