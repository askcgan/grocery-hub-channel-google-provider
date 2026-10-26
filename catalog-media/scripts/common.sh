# Shared settings for the catalog-media scripts. Override with environment variables:
#   PROJECT_ID=groceryhub-channel REGION=us-central1 ./scripts/plan.sh
PROJECT_ID="${PROJECT_ID:-groceryhub-channel}"
REGION="${REGION:-us-central1}"
STATE_BUCKET="${STATE_BUCKET:-${PROJECT_ID}-tfstate}"
# The Terraform stack to run: catalog-media by default; STACK_DIR=<path> runs another stack in this folder (app-template)
# through the same plan → cost guard → apply path.
STACK_DIR="$(cd "${STACK_DIR:-$(dirname "${BASH_SOURCE[0]}")/..}" && pwd)"
# Every plan is checked for expensive resources before it can be applied (tools/cost-guard.py).
COST_GUARD="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tools/cost-guard.py"

# Terraform runs as this service account (created by bootstrap.sh), not as the person at the keyboard: you
# impersonate it, so every change is made by one identity with exactly the roles the stack needs.
# USE_DEPLOYER=0 runs as yourself (only for the very first bootstrap or to repair the deployer).
DEPLOYER_SA="${DEPLOYER_SA:-terraform-deployer@${PROJECT_ID}.iam.gserviceaccount.com}"
USE_DEPLOYER="${USE_DEPLOYER:-1}"
if [ "$USE_DEPLOYER" = "1" ]; then export GOOGLE_IMPERSONATE_SERVICE_ACCOUNT="$DEPLOYER_SA"; fi

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing '$1'. Run this in Cloud Shell (it has gcloud and terraform), or install it." >&2; exit 1; }; }
say() { printf '\n== %s\n' "$*"; }
