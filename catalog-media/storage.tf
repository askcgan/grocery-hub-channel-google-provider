# ---- catalog extractor: private ------------------------------------------------------------------------------------
# Runs of the catalog extractor: out/<run>/products.csv, catalog-import.csv, assets/ (cut-out and found images),
# cards/ and snapshots/ (OCR evidence), plus categories.txt and brands.txt at the top. Never public: it holds other
# sites' screenshots and images. The app reads and writes it with its runtime account (ADC), no keys.
resource "google_storage_bucket" "extractor" {
  name                        = local.extractor_bucket
  location                    = var.region
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false

  soft_delete_policy {
    retention_duration_seconds = var.extractor_soft_delete_days * 86400
  }

  # No lifecycle rule: lifecycle conditions match name prefixes and suffixes only, and the OCR evidence worth
  # expiring (out/<run>/cards/, out/<run>/snapshots/) can't be told apart from a run's CSVs and product images
  # (out/<run>/…) that way. Delete old runs from the extractor's UI or with gcloud storage rm instead.

  depends_on = [google_project_service.apis]
}

resource "google_storage_bucket_iam_member" "extractor_rw" {
  bucket = google_storage_bucket.extractor.name
  role   = "roles/storage.objectUser"
  member = google_service_account.extractor.member
}

# ---- media originals: private --------------------------------------------------------------------------------------
# Images uploaded in the admin console, as received. The API only creates objects; the processor only reads them.
resource "google_storage_bucket" "originals" {
  name                        = local.originals_bucket
  location                    = var.region
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false

  lifecycle {
    prevent_destroy = true
  }
  depends_on = [google_project_service.apis]
}

resource "google_storage_bucket_iam_member" "processor_reads_originals" {
  bucket = google_storage_bucket.originals.name
  role   = "roles/storage.objectViewer"
  member = google_service_account.processor.member
}

resource "google_storage_bucket_iam_member" "api_uploads_originals" {
  count  = local.api_member != "" ? 1 : 0
  bucket = google_storage_bucket.originals.name
  role   = "roles/storage.objectCreator"
  member = local.api_member
}

# ---- processed media: public read ----------------------------------------------------------------------------------
# Resized WebP copies at catalog/<tenant>/<hh>/<sha256>/w<width>.webp, content-addressed (cached as immutable).
# The storefront web and mobile apps load them straight from here: the API returns
# <APP_MEDIA_PUBLIC_BASE_URL>/<storageKey>/w<width>.webp.
resource "google_storage_bucket" "media" {
  name                        = local.media_bucket
  location                    = var.region
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = var.media_public_read ? "inherited" : "enforced"
  force_destroy               = false

  cors {
    origin          = var.media_cors_origins
    method          = ["GET", "HEAD"]
    response_header = ["Content-Type"]
    max_age_seconds = 3600
  }

  lifecycle {
    prevent_destroy = true
  }
  depends_on = [google_project_service.apis]
}

# Anyone may read an object whose name they know; nobody can list the bucket (legacyObjectReader, not objectViewer).
resource "google_storage_bucket_iam_member" "media_public" {
  count  = var.media_public_read ? 1 : 0
  bucket = google_storage_bucket.media.name
  role   = "roles/storage.legacyObjectReader"
  member = "allUsers"
}

resource "google_storage_bucket_iam_member" "processor_writes_media" {
  bucket = google_storage_bucket.media.name
  role   = "roles/storage.objectUser"
  member = google_service_account.processor.member
}
