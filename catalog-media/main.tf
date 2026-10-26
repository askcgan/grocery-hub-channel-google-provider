# Catalog images and data, end to end:
#
#   catalog-extractor (Cloud Run, private)
#     └─ gs://<project>-catalog-extractor            private: runs, CSVs, cut-out images
#          import CSV → API (media_url)
#   API ─ upload ─► gs://<project>-media-originals   private: originals uploaded in the admin console
#   API ─ publish ─► catalog.media.ingest-requested ─push (OIDC)─► grocery-hub-media-processor
#   media processor ─► gs://<project>-media          public read: resized WebP copies (w200…w1200)
#   media processor ─ publish ─► catalog.media.processed ─push (OIDC)─► API /internal/pubsub/media-processed
#   storefront web + mobile ─► https://storage.googleapis.com/<project>-media/catalog/…  (later: a CDN domain)
#
# Names match grocery-hub-media-processor/cloudbuild.yaml, so its build finds these resources instead of creating
# them. Remove its ensure-infrastructure / wire-subscriptions steps once this stack is applied (README.md).

data "google_project" "this" {
  project_id = var.project_id
}

locals {
  extractor_bucket = var.extractor_bucket_name != "" ? var.extractor_bucket_name : "${var.project_id}-catalog-extractor"
  originals_bucket = "${var.project_id}-media-originals"
  media_bucket     = "${var.project_id}-media"
  pubsub_agent     = "serviceAccount:service-${data.google_project.this.number}@gcp-sa-pubsub.iam.gserviceaccount.com"
  api_member       = var.api_service_account_email != "" ? "serviceAccount:${var.api_service_account_email}" : ""
}

# APIs this stack needs. disable_on_destroy = false: destroying the stack must never switch off an API other
# services in the project use.
resource "google_project_service" "apis" {
  for_each = toset([
    "storage.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com", # signed image links; OIDC tokens for Pub/Sub push
    "pubsub.googleapis.com",
    "run.googleapis.com",
  ])
  service            = each.value
  disable_on_destroy = false
}

# ---- service accounts (runtime identities; no keys are ever created for them) --------------------------------------

resource "google_service_account" "extractor" {
  account_id   = "catalog-extractor-runner"
  display_name = "Catalog extractor (Cloud Run runtime)"
  description  = "Reads and writes the catalog-extractor bucket. Nothing else."
  depends_on   = [google_project_service.apis]
}

resource "google_service_account" "processor" {
  account_id   = "media-processor-runner"
  display_name = "Media processor (Cloud Run runtime)"
  description  = "Reads originals, writes processed media, publishes results."
  depends_on   = [google_project_service.apis]
}

resource "google_service_account" "pusher" {
  account_id   = "media-pubsub-pusher"
  display_name = "Pub/Sub push to media processor and API"
  description  = "Pub/Sub signs push requests as this account; the receivers check its tokens."
  depends_on   = [google_project_service.apis]
}

# Pub/Sub mints the OIDC tokens of push requests as the pusher account.
resource "google_service_account_iam_member" "pubsub_signs_as_pusher" {
  service_account_id = google_service_account.pusher.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = local.pubsub_agent
}

# Signed image links: the extractor signs with its own identity (IAM signBlob), only when enabled.
resource "google_service_account_iam_member" "extractor_signs_itself" {
  count              = var.extractor_signs_image_links ? 1 : 0
  service_account_id = google_service_account.extractor.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = google_service_account.extractor.member
}
