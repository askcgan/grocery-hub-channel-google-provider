#!/usr/bin/env bash
# One time per project, run by a project OWNER as themselves:
#   1. the APIs Terraform itself needs;
#   2. a versioned private bucket for Terraform's state (gs://<project>-tfstate);
#   3. the deployer: service account terraform-deployer, with the project roles this stack needs, and the right for
#      the people in DEPLOYER_USERS to impersonate it.
# Why the deployer is made here and not by Terraform: whoever manages the deployer's project roles must be able to
# grant project roles (projectIamAdmin), i.e. could make itself owner. Keeping that out of the deployer's hands
# means a Terraform run can change this stack, but never escalate its own access.
# Safe to re-run: every step checks first; IAM bindings are additive.
#   DEPLOYER_USERS="user:a@example.com,group:infra@example.com" ./scripts/bootstrap.sh   (default: you)
set -euo pipefail
source "$(dirname "$0")/common.sh"
need gcloud
ME="$(gcloud config get-value account 2>/dev/null)"
DEPLOYER_USERS="${DEPLOYER_USERS:-user:${ME}}"

say "Project ${PROJECT_ID} (signed in as ${ME})"
gcloud projects describe "$PROJECT_ID" --format='value(projectId)' >/dev/null

say "APIs Terraform needs to manage the rest"
gcloud services enable serviceusage.googleapis.com cloudresourcemanager.googleapis.com storage.googleapis.com \
  iam.googleapis.com iamcredentials.googleapis.com --project="$PROJECT_ID"

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

say "Deployer ${DEPLOYER_SA}"
gcloud iam service-accounts describe "$DEPLOYER_SA" --project="$PROJECT_ID" >/dev/null 2>&1 || \
  gcloud iam service-accounts create terraform-deployer --project="$PROJECT_ID" \
    --display-name="Terraform deployer (catalog-media)" \
    --description="Runs Terraform for catalog-media. Impersonated by people; never has keys."
# What the stack manages, and nothing more: no project IAM admin, no owner/editor.
for ROLE in roles/storage.admin roles/pubsub.admin roles/iam.serviceAccountAdmin roles/run.admin \
            roles/artifactregistry.admin roles/serviceusage.serviceUsageAdmin roles/browser; do
  gcloud projects add-iam-policy-binding "$PROJECT_ID" --member="serviceAccount:${DEPLOYER_SA}" \
    --role="$ROLE" --condition=None --quiet >/dev/null
  echo "  granted $ROLE"
done
# Who may run Terraform as the deployer.
IFS=',' read -r -a MEMBERS <<< "$DEPLOYER_USERS"
for M in "${MEMBERS[@]}"; do
  gcloud iam service-accounts add-iam-policy-binding "$DEPLOYER_SA" --project="$PROJECT_ID" \
    --member="$M" --role=roles/iam.serviceAccountTokenCreator --quiet >/dev/null
  echo "  $M may impersonate it"
done

say "Done. Next: ./scripts/plan.sh  (runs as ${DEPLOYER_SA})"
echo "Outside Cloud Shell, sign in for Terraform first: gcloud auth application-default login"
