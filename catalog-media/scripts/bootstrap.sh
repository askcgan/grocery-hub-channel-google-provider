#!/usr/bin/env bash
# One time per project: the APIs Terraform itself needs, and a versioned private bucket for Terraform's state.
# Safe to re-run (every step checks first). Creates: gs://<project>-tfstate.
set -euo pipefail
source "$(dirname "$0")/common.sh"
need gcloud

say "Project ${PROJECT_ID} (signed in as $(gcloud config get-value account 2>/dev/null))"
gcloud projects describe "$PROJECT_ID" --format='value(projectId)' >/dev/null

say "APIs Terraform needs to manage the rest"
gcloud services enable serviceusage.googleapis.com cloudresourcemanager.googleapis.com storage.googleapis.com \
  iam.googleapis.com --project="$PROJECT_ID"

say "State bucket gs://${STATE_BUCKET}"
if gcloud storage buckets describe "gs://${STATE_BUCKET}" --project="$PROJECT_ID" >/dev/null 2>&1; then
  echo "exists"
else
  gcloud storage buckets create "gs://${STATE_BUCKET}" --project="$PROJECT_ID" --location="$REGION" \
    --default-storage-class=STANDARD --uniform-bucket-level-access --public-access-prevention
fi
# Versioning keeps every earlier state (undo for a bad apply); old versions expire after 30 days.
gcloud storage buckets update "gs://${STATE_BUCKET}" --versioning
printf '{"rule":[{"action":{"type":"Delete"},"condition":{"isLive":false,"daysSinceNoncurrentTime":30}}]}' > /tmp/tfstate-lifecycle.json
gcloud storage buckets update "gs://${STATE_BUCKET}" --lifecycle-file=/tmp/tfstate-lifecycle.json
rm -f /tmp/tfstate-lifecycle.json

say "Done. Next: ./scripts/plan.sh"
