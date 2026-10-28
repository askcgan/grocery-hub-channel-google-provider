# Event topics for the operations agents (grocery-hub-channel-ai roadmap; contract in grocery-hub-channel-api
# docs/kafka-pubsub/AGENT_EVENT_TOPICS.md). Off by default: nothing here is created until agent_events_enabled = true.
# Kept in this stack because it already owns the API's Pub/Sub grants and the push account.
#
# One subscription per topic in agent_topics (default: grocery.order.lifecycle only), agents.<topic>, read by the
# agents' event trigger: pull by default (the trigger's
# account pulls), or push with an OIDC token once agent_push_url is set. Deliveries that fail 5 times go to
# agents.dead-letter and wait 7 days there.
#
# After applying, switch the API's publishing on for the same topics (APP_MESSAGING_ENABLED_TOPICS); the API has no
# right to create topics in Google Cloud.

locals {
  # The topics in agent_topics (variables.tf lists the allowed ones). catalog.media.processed is published by the media
  # processor and already exists in pubsub.tf, so it only gets a subscription. Add a topic only when its agent exists
  # (grocery-hub-channel-api docs/kafka-pubsub/AGENT_EVENT_TOPICS.md §0).
  agent_api_topics = var.agent_events_enabled ? toset([for t in var.agent_topics : t if t != "catalog.media.processed"]) : toset([])

  agent_subscriptions = var.agent_events_enabled ? merge(
    { for t in local.agent_api_topics : t => google_pubsub_topic.agent[t].id },
    contains(var.agent_topics, "catalog.media.processed") ? { "catalog.media.processed" = google_pubsub_topic.processed.id } : {},
  ) : {}

  agent_push_url = trimsuffix(var.agent_push_url, "/")
}

resource "google_pubsub_topic" "agent" {
  for_each                   = local.agent_api_topics
  name                       = "${var.topic_prefix}${each.value}"
  message_retention_duration = "86400s" # 1 day on the topic: lets a new subscription seek back after an outage
  depends_on                 = [google_project_service.apis]
}

resource "google_pubsub_topic_iam_member" "api_publishes_agent_events" {
  for_each = local.api_member != "" ? local.agent_api_topics : toset([])
  topic    = google_pubsub_topic.agent[each.key].id
  role     = "roles/pubsub.publisher"
  member   = local.api_member
}

resource "google_pubsub_topic" "agent_dead_letter" {
  count      = var.agent_events_enabled ? 1 : 0
  name       = "${var.topic_prefix}agents.dead-letter"
  depends_on = [google_project_service.apis]
}

resource "google_pubsub_topic_iam_member" "pubsub_dead_letters_agents" {
  count  = var.agent_events_enabled ? 1 : 0
  topic  = google_pubsub_topic.agent_dead_letter[0].id
  role   = "roles/pubsub.publisher"
  member = local.pubsub_agent
}

resource "google_pubsub_subscription" "agent_dead_letter" {
  count                      = var.agent_events_enabled ? 1 : 0
  name                       = "${var.topic_prefix}agents.dead-letter"
  topic                      = google_pubsub_topic.agent_dead_letter[0].id
  message_retention_duration = "604800s"
  ack_deadline_seconds       = 60
  expiration_policy {
    ttl = ""
  }
}

resource "google_pubsub_subscription" "agent" {
  for_each                   = local.agent_subscriptions
  name                       = "${var.topic_prefix}agents.${each.key}"
  topic                      = each.value
  ack_deadline_seconds       = 60
  message_retention_duration = "604800s" # 7 days: the agents can be down for a weekend without losing events

  dynamic "push_config" {
    for_each = local.agent_push_url == "" ? [] : [1]
    content {
      push_endpoint = "${local.agent_push_url}?topic=${each.key}"
      oidc_token {
        service_account_email = google_service_account.pusher.email
        audience              = local.agent_push_url
      }
    }
  }
  retry_policy {
    minimum_backoff = "10s"
    maximum_backoff = "600s"
  }
  dead_letter_policy {
    dead_letter_topic     = google_pubsub_topic.agent_dead_letter[0].id
    max_delivery_attempts = 5
  }
  expiration_policy {
    ttl = ""
  }
}

resource "google_pubsub_subscription_iam_member" "pubsub_forwards_agent_dead_letters" {
  for_each     = local.agent_subscriptions
  subscription = google_pubsub_subscription.agent[each.key].id
  role         = "roles/pubsub.subscriber"
  member       = local.pubsub_agent
}

# Pull: the agents' runtime account reads (and acknowledges) its own subscriptions only.
resource "google_pubsub_subscription_iam_member" "agents_pull" {
  for_each     = var.agent_service_account_email != "" ? local.agent_subscriptions : {}
  subscription = google_pubsub_subscription.agent[each.key].id
  role         = "roles/pubsub.subscriber"
  member       = "serviceAccount:${var.agent_service_account_email}"
}

resource "google_pubsub_subscription_iam_member" "agents_read_dead_letters" {
  count        = var.agent_events_enabled && var.agent_service_account_email != "" ? 1 : 0
  subscription = google_pubsub_subscription.agent_dead_letter[0].id
  role         = "roles/pubsub.subscriber"
  member       = "serviceAccount:${var.agent_service_account_email}"
}

# Push: the push account may call the agents' Cloud Run service (which stays private).
resource "google_cloud_run_v2_service_iam_member" "pusher_invokes_agents" {
  count    = var.agent_events_enabled && local.agent_push_url != "" ? 1 : 0
  location = var.region
  name     = var.agent_service_name
  role     = "roles/run.invoker"
  member   = google_service_account.pusher.member
}
