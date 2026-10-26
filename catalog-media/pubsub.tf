# The media pipeline's topics. The API publishes ingest requests; the processor publishes results; deliveries that
# fail 5 times go to the dead-letter topic and wait 7 days in a pull subscription for someone to look.

resource "google_pubsub_topic" "ingest" {
  name       = "${var.topic_prefix}catalog.media.ingest-requested"
  depends_on = [google_project_service.apis]
}

resource "google_pubsub_topic" "processed" {
  name       = "${var.topic_prefix}catalog.media.processed"
  depends_on = [google_project_service.apis]
}

resource "google_pubsub_topic" "dead_letter" {
  name       = "${var.topic_prefix}catalog.media.dead-letter"
  depends_on = [google_project_service.apis]
}

resource "google_pubsub_subscription" "dead_letter" {
  name                       = "${var.topic_prefix}media.dead-letter"
  topic                      = google_pubsub_topic.dead_letter.id
  message_retention_duration = "604800s" # 7 days
  ack_deadline_seconds       = 60
  expiration_policy {
    ttl = "" # never expires
  }
}

# Who may publish where.
resource "google_pubsub_topic_iam_member" "api_publishes_ingest" {
  count  = local.api_member != "" ? 1 : 0
  topic  = google_pubsub_topic.ingest.id
  role   = "roles/pubsub.publisher"
  member = local.api_member
}

resource "google_pubsub_topic_iam_member" "processor_publishes_results" {
  topic  = google_pubsub_topic.processed.id
  role   = "roles/pubsub.publisher"
  member = google_service_account.processor.member
}

resource "google_pubsub_topic_iam_member" "pubsub_dead_letters" {
  topic  = google_pubsub_topic.dead_letter.id
  role   = "roles/pubsub.publisher"
  member = local.pubsub_agent
}

# ---- push subscriptions: created once the receiving service is deployed (its URL is the OIDC audience) ------------

locals {
  pushes = merge(
    var.processor_url == "" ? {} : {
      processor = { name = "media-processor.ingest", topic = google_pubsub_topic.ingest.id, url = trimsuffix(var.processor_url, "/"), path = "/pubsub/ingest", ack = 120 }
    },
    var.api_url == "" ? {} : {
      api = { name = "api.media-processed", topic = google_pubsub_topic.processed.id, url = trimsuffix(var.api_url, "/"), path = "/internal/pubsub/media-processed", ack = 30 }
    },
  )
}

resource "google_pubsub_subscription" "push" {
  for_each             = local.pushes
  name                 = "${var.topic_prefix}${each.value.name}"
  topic                = each.value.topic
  ack_deadline_seconds = each.value.ack

  push_config {
    push_endpoint = "${each.value.url}${each.value.path}"
    oidc_token {
      service_account_email = google_service_account.pusher.email
      audience              = each.value.url
    }
  }
  retry_policy {
    minimum_backoff = "5s"
    maximum_backoff = "300s"
  }
  dead_letter_policy {
    dead_letter_topic     = google_pubsub_topic.dead_letter.id
    max_delivery_attempts = 5
  }
  expiration_policy {
    ttl = ""
  }
}

# Pub/Sub must be allowed to take messages off a subscription to forward them to the dead-letter topic.
resource "google_pubsub_subscription_iam_member" "pubsub_forwards_dead_letters" {
  for_each     = local.pushes
  subscription = google_pubsub_subscription.push[each.key].id
  role         = "roles/pubsub.subscriber"
  member       = local.pubsub_agent
}

# The push account may call the receiving Cloud Run services (both stay private).
resource "google_cloud_run_v2_service_iam_member" "pusher_invokes_processor" {
  count    = var.processor_url == "" ? 0 : 1
  location = var.region
  name     = var.processor_service_name
  role     = "roles/run.invoker"
  member   = google_service_account.pusher.member
}

resource "google_cloud_run_v2_service_iam_member" "pusher_invokes_api" {
  count    = var.api_url == "" ? 0 : 1
  location = var.region
  name     = var.api_service_name
  role     = "roles/run.invoker"
  member   = google_service_account.pusher.member
}
