#!/usr/bin/env bash
set -euo pipefail

# No TASK_FAMILY/IMAGE fallback: prepare an exact immutable revision first.
exec python3 "$(dirname "${BASH_SOURCE[0]}")/ecs_deploy.py" deploy
