output "extractor_bucket" {
  description = "Private bucket for catalog-extractor runs."
  value       = google_storage_bucket.extractor.name
}

output "originals_bucket" {
  description = "Private bucket for uploaded originals."
  value       = google_storage_bucket.originals.name
}

output "media_bucket" {
  description = "Public-read bucket of processed images."
  value       = google_storage_bucket.media.name
}

output "media_public_base_url" {
  description = "Base URL the API puts in front of processed image keys (APP_MEDIA_PUBLIC_BASE_URL)."
  value       = "https://storage.googleapis.com/${google_storage_bucket.media.name}"
}

output "service_accounts" {
  description = "Runtime identities to deploy the Cloud Run services with (--service-account)."
  value = {
    catalog_extractor = google_service_account.extractor.email
    media_processor   = google_service_account.processor.email
    pubsub_pusher     = google_service_account.pusher.email
  }
}

output "topics" {
  description = "Pub/Sub topic names."
  value = {
    ingest_requested = google_pubsub_topic.ingest.name
    processed        = google_pubsub_topic.processed.name
    dead_letter      = google_pubsub_topic.dead_letter.name
  }
}

output "push_subscriptions" {
  description = "Push subscriptions created (empty until processor_url / api_url are set)."
  value       = { for k, s in google_pubsub_subscription.push : k => s.name }
}

# Environment for each app, ready to paste (scripts/app-env.sh prints these).
output "app_env" {
  description = "Environment variables that connect each app to these resources."
  value = {
    catalog_extractor = {
      STORAGE_PROVIDER = "gcs"
      GCS_BUCKET       = google_storage_bucket.extractor.name
      GCP_PROJECT_ID   = var.project_id
    }
    media_processor = {
      MEDIA_STORAGE          = "gcs"
      MEDIA_ORIGINALS_BUCKET = google_storage_bucket.originals.name
      MEDIA_BUCKET           = google_storage_bucket.media.name
      PUBSUB_PROJECT_ID      = var.project_id
      PUBSUB_TOPIC_PREFIX    = var.topic_prefix
      PUSH_SERVICE_ACCOUNT   = google_service_account.pusher.email
    }
    api = {
      APP_MEDIA_INGEST_ENABLED       = "true"
      APP_MEDIA_PUBLIC_BASE_URL      = "https://storage.googleapis.com/${google_storage_bucket.media.name}"
      APP_MEDIA_ORIGINALS_PROVIDER   = "gcs"
      APP_MEDIA_ORIGINALS_BUCKET     = google_storage_bucket.originals.name
      APP_MEDIA_PUSH_SERVICE_ACCOUNT = google_service_account.pusher.email
    }
  }
}
