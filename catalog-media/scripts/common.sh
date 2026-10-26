# Shared settings for the catalog-media scripts. Override with environment variables:
#   PROJECT_ID=groceryhub-channel REGION=asia-south1 ./scripts/plan.sh
PROJECT_ID="${PROJECT_ID:-groceryhub-channel}"
REGION="${REGION:-asia-south1}"
STATE_BUCKET="${STATE_BUCKET:-${PROJECT_ID}-tfstate}"
STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing '$1'. Run this in Cloud Shell (it has gcloud and terraform), or install it." >&2; exit 1; }; }
say() { printf '\n== %s\n' "$*"; }
