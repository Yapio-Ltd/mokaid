#!/usr/bin/env bash
# Request the production workflow. No local build, AWS mutation or Terraform apply.
set -euo pipefail
exec python3 "$(dirname "${BASH_SOURCE[0]}")/../../.github/scripts/dispatch_production.py" "$@"
