# The Docker repository every service's build pushes to (catalog-extractor, media processor; later the API and
# console). Cleanup keeps storage from growing with every build: the extractor's image alone is 1.5–2 GB.
#   KEEP the newest `images_keep_recent` versions of each image (rollback targets), whatever their age;
#   DELETE any other version older than `images_delete_after_days`.
# KEEP wins over DELETE. Cleanup runs about once a day, so a deleted version can linger a day.
resource "google_artifact_registry_repository" "images" {
  repository_id = var.image_repository
  location      = var.region
  format        = "DOCKER"
  description   = "Grocery Hub container images (catalog-extractor, media processor, API, console)"

  cleanup_policy_dry_run = false

  cleanup_policies {
    id     = "keep-recent"
    action = "KEEP"
    most_recent_versions {
      keep_count = var.images_keep_recent
    }
  }

  cleanup_policies {
    id     = "delete-old"
    action = "DELETE"
    condition {
      tag_state  = "ANY"
      older_than = "${var.images_delete_after_days * 86400}s"
    }
  }

  # On-push vulnerability scanning (Artifact Analysis) is billed per image scanned; INHERITED = on when the
  # Container Scanning API is enabled, which scan_images does below.
  vulnerability_scanning_config {
    enablement_config = var.scan_images ? "INHERITED" : "DISABLED"
  }

  depends_on = [google_project_service.apis, google_project_service.scanning]
}

resource "google_project_service" "scanning" {
  count              = var.scan_images ? 1 : 0
  service            = "containerscanning.googleapis.com"
  disable_on_destroy = false
}
