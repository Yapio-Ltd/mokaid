#!/usr/bin/env bash
# Pushes Mokaid runtime secrets to AWS Secrets Manager (il-central-1).
#
# Usage:
#   aws sso login --profile mokaid          # authenticate first (browser)
#   ./scripts/push-secrets-to-aws.sh
#
# Values are read from the local gitignored .env files so no secret ever
# lives in the repo or in shell history.
#
# Optional interactive prompts (never echoed):
#   PUSH_ADMIN_KEYS=1 ./scripts/push-secrets-to-aws.sh
# or:
#   ./scripts/push-secrets-to-aws.sh --admin-keys
#
# NEVER paste Admin API keys into chat, git, Terraform, or CI logs.

set -euo pipefail

PROFILE="${AWS_PROFILE:-mokaid}"
REGION="${AWS_REGION:-il-central-1}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PUSH_ADMIN_KEYS="${PUSH_ADMIN_KEYS:-0}"

for arg in "$@"; do
  case "$arg" in
    --admin-keys) PUSH_ADMIN_KEYS=1 ;;
  esac
done

env_value() { # env_value FILE KEY — tolerates missing or commented-out entries
  grep -E "^(# )?$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# Silent read of a secret from the terminal (never printed).
# Returns empty string if blank.
read_secret() {
  local prompt="$1"
  local value=""
  if [ ! -t 0 ]; then
    echo "skip interactive secret ($prompt) — stdin is not a TTY" >&2
    echo ""
    return
  fi
  # shellcheck disable=SC2162
  read -s -p "$prompt: " value
  echo "" >&2
  printf '%s' "$value"
}

put_secret() { # put_secret NAME VALUE DESCRIPTION
  local name="$1" value="$2" desc="$3"
  if [ -z "$value" ]; then
    echo "skip  $name (no local value)"
    return
  fi
  if aws secretsmanager describe-secret --secret-id "$name" \
    --profile "$PROFILE" --region "$REGION" > /dev/null 2>&1; then
    aws secretsmanager put-secret-value --secret-id "$name" \
      --secret-string "$value" --profile "$PROFILE" --region "$REGION" > /dev/null
    echo "update $name"
  else
    aws secretsmanager create-secret --name "$name" --description "$desc" \
      --secret-string "$value" --profile "$PROFILE" --region "$REGION" > /dev/null
    echo "create $name"
  fi
}

ANTHROPIC_KEY="$(env_value "$ROOT/apps/ai-worker/.env" ANTHROPIC_API_KEY)"
OPENAI_KEY="$(env_value "$ROOT/apps/ai-worker/.env" OPENAI_API_KEY)"
TRANZILA_PUBLIC="$(env_value "$ROOT/apps/api/.env" TRANZILA_PUBLIC_KEY)"
TRANZILA_PRIVATE="$(env_value "$ROOT/apps/api/.env" TRANZILA_PRIVATE_KEY)"

# Optional local admin keys (prefer interactive prompt so keys never sit in .env).
OPENAI_ADMIN_KEY="$(env_value "$ROOT/apps/api/.env" OPENAI_ADMIN_API_KEY)"
ANTHROPIC_ADMIN_KEY="$(env_value "$ROOT/apps/api/.env" ANTHROPIC_ADMIN_API_KEY)"

put_secret "mokaid/anthropic-api-key" "$ANTHROPIC_KEY" "Anthropic API key for the Mokaid AI worker"
put_secret "mokaid/openai-api-key" "$OPENAI_KEY" "OpenAI API key for the Mokaid AI worker"
put_secret "mokaid/tranzila-public-key" "$TRANZILA_PUBLIC" "Tranzila public app key for Mokaid billing"
put_secret "mokaid/tranzila-private-key" "$TRANZILA_PRIVATE" "Tranzila private/secret key for Mokaid billing"

# Terraform-managed stacks (mokaid-prod)
# create their own suffixed secrets consumed by the ECS task definitions —
# update those too wherever the stack exists.
update_stack_secret() { # update_stack_secret KEY VALUE
  local key="$1" value="$2"
  if [ -z "$value" ]; then
    echo "skip  stack secret $key (no value)"
    return
  fi
  # name_prefix format: mokaid-prod/openai_api_key-XXXX
  local names
  names="$(aws secretsmanager list-secrets --profile "$PROFILE" --region "$REGION" \
    --query "SecretList[?starts_with(Name, 'mokaid-prod/${key}-')].Name" \
    --output text 2>/dev/null || true)"
  if [ -z "$names" ]; then
    echo "skip  stack secret $key (no matching secret yet — run terraform apply first)"
    return
  fi
  for name in $names; do
    aws secretsmanager put-secret-value --secret-id "$name" \
      --secret-string "$value" --profile "$PROFILE" --region "$REGION" > /dev/null
    echo "update $name"
  done
}

update_stack_secret "anthropic_api_key" "$ANTHROPIC_KEY"
update_stack_secret "openai_api_key" "$OPENAI_KEY"
update_stack_secret "tranzila_public_key" "$TRANZILA_PUBLIC"
update_stack_secret "tranzila_private_key" "$TRANZILA_PRIVATE"

if [ "$PUSH_ADMIN_KEYS" = "1" ]; then
  echo ""
  echo "=== Provider Admin keys (costs only — never inference) ==="
  echo "Paste NEW keys created AFTER revoking any exposed ones."
  echo "Input is hidden. Leave blank to skip."
  echo ""
  if [ -z "$OPENAI_ADMIN_KEY" ]; then
    OPENAI_ADMIN_KEY="$(read_secret "OpenAI Admin API key (sk-admin-…)")"
  fi
  if [ -z "$ANTHROPIC_ADMIN_KEY" ]; then
    ANTHROPIC_ADMIN_KEY="$(read_secret "Anthropic Admin API key (sk-ant-admin-…)")"
  fi
fi

if [ -n "${OPENAI_ADMIN_KEY:-}" ]; then
  put_secret "mokaid/openai-admin-api-key" "$OPENAI_ADMIN_KEY" \
    "OpenAI Admin API key for organization costs (CRM/API only)"
  update_stack_secret "openai_admin_api_key" "$OPENAI_ADMIN_KEY"
fi

if [ -n "${ANTHROPIC_ADMIN_KEY:-}" ]; then
  put_secret "mokaid/anthropic-admin-api-key" "$ANTHROPIC_ADMIN_KEY" \
    "Anthropic Admin API key for organization costs (CRM/API only)"
  update_stack_secret "anthropic_admin_api_key" "$ANTHROPIC_ADMIN_KEY"
fi

echo ""
echo "Done. Redeploy the API so new secrets are loaded:"
echo "  aws ecs update-service --cluster mokaid-prod --service mokaid-prod-api --force-new-deployment"
echo "  # worker only if inference keys changed:"
echo "  aws ecs update-service --cluster mokaid-prod --service mokaid-prod-ai-worker --force-new-deployment"
