#!/usr/bin/env bash
# Shows what Terraform would create or change, and saves the plan (tfplan) for apply.sh. Changes nothing.
# Runs as the deployer service account (common.sh); USE_DEPLOYER=0 runs as yourself.
set -euo pipefail
source "$(dirname "$0")/common.sh"
need terraform; need gcloud
cd "$STACK_DIR"
[ -f terraform.tfvars ] || { cp terraform.tfvars.example terraform.tfvars; echo "Created terraform.tfvars from the example; review it."; }

# Terraform signs in with Application Default Credentials (Cloud Shell has them; elsewhere:
# gcloud auth application-default login) and from there impersonates the deployer.
gcloud auth application-default print-access-token >/dev/null 2>&1 || \
  { echo "No Application Default Credentials. Run: gcloud auth application-default login" >&2; exit 1; }
BACKEND=(-backend-config="bucket=${STATE_BUCKET}")
if [ "$USE_DEPLOYER" = "1" ]; then
  echo "Running as ${DEPLOYER_SA}"
  BACKEND+=(-backend-config="impersonate_service_account=${DEPLOYER_SA}")
fi

terraform init -input=false -reconfigure "${BACKEND[@]}"
terraform fmt -check -recursive || { echo "Run 'terraform fmt -recursive' first." >&2; exit 1; }
terraform validate
terraform plan -input=false -var="project_id=${PROJECT_ID}" -var="region=${REGION}" -out=tfplan

say "Cost guard"
terraform show -json tfplan > tfplan.json
python3 "$COST_GUARD" tfplan.json || { rm -f tfplan tfplan.json; echo "Plan discarded: nothing can be applied." >&2; exit 1; }
rm -f tfplan.json
say "Review the plan above. To make these changes: ./scripts/apply.sh"
