#!/usr/bin/env bash
# Prints the environment variables that connect each app to this stack (from Terraform's outputs).
#   ./scripts/app-env.sh                 all apps
#   ./scripts/app-env.sh catalog_extractor | media_processor | api
set -euo pipefail
source "$(dirname "$0")/common.sh"
need terraform
cd "$STACK_DIR"
terraform output -json app_env | python3 -c '
import json, sys
apps = json.load(sys.stdin); only = sys.argv[1] if len(sys.argv) > 1 else None
for app, env in apps.items():
    if only and app != only: continue
    print(f"# {app}")
    for k, v in env.items(): print(f"{k}={v}")
    print()
' "${1:-}"
