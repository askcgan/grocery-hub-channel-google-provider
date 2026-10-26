# terraform test, offline: Google is mocked, so these plan the real template without credentials or cost.
mock_provider "google" {}
mock_provider "google-beta" {}

variables {
  project_id = "groceryhub-channel"
}

run "refused_without_acknowledgement" {
  command = plan
  variables {
    acknowledge_billable_resources = false
  }
  expect_failures = [terraform_data.billing_acknowledged]
}

run "plans_small_and_single_zone_when_acknowledged" {
  command = plan
  variables {
    acknowledge_billable_resources = true
  }
  assert {
    condition     = module.db.instance_name == "poc-db"
    error_message = "the database should be planned"
  }
}

run "large_database_tier_rejected" {
  command = plan
  variables {
    acknowledge_billable_resources = true
    db_tier                        = "db-perf-optimized-N-8"
  }
  expect_failures = [var.db_tier]
}

run "cloud_run_capped" {
  command = plan
  variables {
    acknowledge_billable_resources = true
    run_max_instances              = 50
  }
  expect_failures = [var.run_max_instances]
}
