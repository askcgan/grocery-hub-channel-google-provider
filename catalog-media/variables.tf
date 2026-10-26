variable "project_id" {
  description = "Project that owns the buckets, topics and service accounts (billing: grocery-hub-billing-account)."
  type        = string
  default     = "groceryhub-channel"
}

variable "region" {
  description = "Location of the buckets and the Cloud Run services that use them. asia-south1 (Mumbai) is closest to shoppers in India."
  type        = string
  default     = "asia-south1"
}

# ---- catalog extractor -------------------------------------------------------------------------------------------

variable "extractor_bucket_name" {
  description = "Private bucket for catalog-extractor runs (products.csv, catalog-import.csv, cut-out images, screenshots). Empty = <project>-catalog-extractor."
  type        = string
  default     = ""
}

variable "extractor_soft_delete_days" {
  description = "Days a deleted or replaced extractor object can be restored (Cloud Storage soft delete). Re-running an extraction replaces a run's files, and soft-deleted bytes are billed, so keep this short."
  type        = number
  default     = 7
}

variable "extractor_signs_image_links" {
  description = "Let the extractor's service account sign its own time-limited image links (the import CSV's media_url in IMPORT_MEDIA_MODE=signed, so the media processor can fetch images from the private bucket). Grants roles/iam.serviceAccountTokenCreator on that account only."
  type        = bool
  default     = true
}

# ---- media pipeline (grocery-hub-media-processor) ----------------------------------------------------------------

variable "media_public_read" {
  description = "Make the processed-media bucket readable by anyone (the storefronts load images straight from it). Set false when a CDN backend bucket serves it instead, or an org policy forbids allUsers."
  type        = bool
  default     = true
}

variable "media_cors_origins" {
  description = "Origins allowed to GET processed images from the browser (CORS)."
  type        = list(string)
  default     = ["*"]
}

variable "topic_prefix" {
  description = "Prefix of the Pub/Sub topic names; must equal the API's app.messaging.pubsub.topic-prefix and the processor's PUBSUB_TOPIC_PREFIX."
  type        = string
  default     = ""
}

variable "api_service_account_email" {
  description = "The API's Cloud Run runtime account (it uploads originals and publishes ingest requests). Empty = skip its grants until the API is deployed."
  type        = string
  default     = ""
}

variable "processor_url" {
  description = "Deployed grocery-hub-media-processor URL (https://grocery-hub-media-processor-<number>.<region>.run.app). Empty = no push subscription to it yet."
  type        = string
  default     = ""
}

variable "processor_service_name" {
  description = "Cloud Run service name of the media processor (for the push account's run.invoker grant)."
  type        = string
  default     = "grocery-hub-media-processor"
}

variable "api_url" {
  description = "Deployed API URL that receives processing results at /internal/pubsub/media-processed. Empty = no push subscription to it yet."
  type        = string
  default     = ""
}

variable "api_service_name" {
  description = "Cloud Run service name of the API (for the push account's run.invoker grant)."
  type        = string
  default     = "grocery-hub-channel-api"
}
