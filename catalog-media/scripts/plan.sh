#!/usr/bin/env bash
# Shows what Terraform would create or change, and saves the plan (tfplan) for apply.sh. Changes nothing.
set -euo pipefail
source "$(dirname "$0")/common.sh"
need terraform; need gcloud
cd "$STACK_DIR"
[ -f terraform.tfvars ] || { cp terraform.tfvars.example terraform.tfvars; echo "Created terraform.tfvars from the example; review it."; }

terraform init -input=false -reconfigure -backend-config="bucket=${STATE_BUCKET}"
terraform fmt -check -recursive || { echo "Run 'terraform fmt -recursive' first." >&2; exit 1; }
terraform validate
terraform plan -input=false -var="project_id=${PROJECT_ID}" -var="region=${REGION}" -out=tfplan
say "Review the plan above. To make these changes: ./scripts/apply.sh"
