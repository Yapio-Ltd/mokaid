#!/usr/bin/env bash
# Copy Terraform-managed Secrets Manager values from one stack prefix to another.
# Used once when promoting mokaid-dev → mokaid-prod.
#
# Usage:
#   aws sso login --profile mokaid
#   ./scripts/copy-stack-secrets.sh mokaid-dev mokaid-prod

set -euo pipefail

FROM_PREFIX="${1:?source prefix required (e.g. mokaid-dev)}"
TO_PREFIX="${2:?target prefix required (e.g. mokaid-prod)}"
PROFILE="${AWS_PROFILE:-mokaid}"
REGION="${AWS_REGION:-il-central-1}"

KEYS="secret_key_base worker_auth_token openai_api_key anthropic_api_key deepseek_api_key tranzila_public_key tranzila_private_key figma_client_id figma_client_secret google_client_id google_client_secret github_client_id github_client_secret linear_client_id linear_client_secret slack_client_id slack_client_secret slack_signing_secret slack_app_id slack_verification_token notion_client_id notion_client_secret"

ALL_SECRETS="$(aws secretsmanager list-secrets --profile "$PROFILE" --region "$REGION" \
  --query 'SecretList[].Name' --output text | tr '\t' '\n')"

resolve_secret() {
  local prefix="$1" key="$2"
  printf '%s\n' "$ALL_SECRETS" | grep -E "^${prefix}/${key}(-|$)" | head -1 || true
}

for key in $KEYS; do
  src="$(resolve_secret "$FROM_PREFIX" "$key")"
  dst="$(resolve_secret "$TO_PREFIX" "$key")"
  if [ -z "$src" ]; then
    echo "skip  $key (no source)"
    continue
  fi
  if [ -z "$dst" ]; then
    echo "skip  $key (no destination yet)"
    continue
  fi
  value="$(aws secretsmanager get-secret-value --secret-id "$src" \
    --profile "$PROFILE" --region "$REGION" --query SecretString --output text)"
  if [ -z "$value" ] || [ "$value" = "CHANGE_ME" ]; then
    echo "skip  $key (empty/placeholder source)"
    continue
  fi
  aws secretsmanager put-secret-value --secret-id "$dst" \
    --secret-string "$value" --profile "$PROFILE" --region "$REGION" >/dev/null
  echo "copy  $key"
done

echo "done"
