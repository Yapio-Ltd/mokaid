#!/usr/bin/env bash
# Provision a platform CRM admin without embedding secrets in git.
#
# Usage:
#   PLATFORM_ADMIN_EMAIL=ops@example.com \
#   PLATFORM_ADMIN_PASSWORD='...' \
#   ./scripts/provision-platform-admin.sh
#
# Production (ECS one-shot after deploy):
#   aws ecs run-task ... --overrides command:
#     ["bin/mokaid","eval","Mokaid.Release.provision_platform_admin(System.get_env(\"PLATFORM_ADMIN_EMAIL\"), System.get_env(\"PLATFORM_ADMIN_PASSWORD\"))"]
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EMAIL="${PLATFORM_ADMIN_EMAIL:-tomyy4136@gmail.com}"
PASSWORD="${PLATFORM_ADMIN_PASSWORD:-}"
FULL_NAME="${PLATFORM_ADMIN_FULL_NAME:-Platform Admin}"

if [[ -z "$PASSWORD" ]]; then
  echo "PLATFORM_ADMIN_PASSWORD is required (min 10 chars)." >&2
  exit 1
fi

cd "$ROOT/apps/api"
# Avoid binding :4000 if the API is already running
mix run --no-start -e "
Application.ensure_all_started(:ssl)
Application.ensure_all_started(:postgrex)
Application.ensure_all_started(:ecto_sql)
Application.ensure_all_started(:bcrypt_elixir)
Mokaid.Release.provision_platform_admin(
  \"$EMAIL\",
  System.fetch_env!(\"PLATFORM_ADMIN_PASSWORD\"),
  full_name: \"$FULL_NAME\"
)
"
