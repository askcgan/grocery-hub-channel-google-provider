#!/usr/bin/env bash
# Applies exactly the plan saved by plan.sh (nothing else), after asking.
set -euo pipefail
source "$(dirname "$0")/common.sh"
need terraform
cd "$STACK_DIR"
[ -f tfplan ] || { echo "No saved plan. Run ./scripts/plan.sh first." >&2; exit 1; }

terraform show -no-color tfplan | tail -n 3
read -r -p "Apply this plan to ${PROJECT_ID}? Type 'apply': " answer
[ "$answer" = "apply" ] || { echo "Not applied."; exit 1; }
terraform apply -input=false tfplan
rm -f tfplan
say "Applied. Check it: ./scripts/verify.sh   App settings: ./scripts/app-env.sh"
