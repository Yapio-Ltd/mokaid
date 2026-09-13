#!/usr/bin/env python3
"""Explicit production dispatch through the authoritative CI/release workflow."""
import json
import os
import re
import subprocess
import sys

REPOSITORY = "Yapio-Ltd/mokaid"


class Failure(RuntimeError):
    pass


def gh(*arguments):
    environment = dict(os.environ, GH_HOST="github.com", GH_PROMPT_DISABLED="1")
    try:
        result = subprocess.run(["gh", *arguments], env=environment, capture_output=True,
                                text=True, timeout=60, check=False)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise Failure("GitHub CLI unavailable or timed out; no direct deployment fallback") from error
    if result.returncode:
        raise Failure("GitHub request failed; check CLI authentication and repository access (response suppressed)")
    return result.stdout


def production_head():
    value = gh("api", "--hostname", "github.com", f"repos/{REPOSITORY}/commits/prod", "--jq", ".sha").strip()
    if not re.fullmatch(r"[a-f0-9]{40}", value):
        raise Failure("GitHub did not return a valid production commit")
    return value


def dispatch(arguments):
    if arguments != ["prod"]:
        raise Failure("Usage: infra/scripts/deploy-web-ecs.sh prod — no tags, other environments or direct deployment inputs are accepted")
    commit = production_head()
    try:
        runs = json.loads(gh("run", "list", "--repo", REPOSITORY, "--workflow", "ci.yml", "--commit", commit,
                            "--branch", "prod", "--event", "push", "--json", "conclusion,status"))
    except ValueError as error:
        raise Failure("GitHub returned an invalid CI result") from error
    if not isinstance(runs, list) or not any(isinstance(run, dict) and run.get("status") == "completed"
                                            and run.get("conclusion") == "success" for run in runs):
        raise Failure("Production head has no successful completed push CI; wait for CI before requesting deployment")
    if production_head() != commit:
        raise Failure("Production head changed during preflight; retry after its CI completes")
    try:
        gh("workflow", "run", "deploy.yml", "--repo", REPOSITORY, "--ref", "prod", "--field", "environment=prod")
    except Failure:
        raise Failure("Dispatch outcome unconfirmed; inspect the production workflow before retrying; no direct deployment fallback") from None
    print(f"Requested production workflow for {REPOSITORY}; this is not deployment confirmation.")
    print("The workflow rechecks the production commit, CI, installer readiness and production approvals.")
    print(f"Follow the result: https://github.com/{REPOSITORY}/actions/workflows/deploy.yml")


def main():
    try:
        dispatch(sys.argv[1:])
        return 0
    except (Failure, KeyboardInterrupt) as error:
        print(f"ERROR: {error or 'Dispatch interrupted; inspect GitHub before retrying'}", file=sys.stderr)
        return 1
    except Exception:
        print("ERROR: Unexpected dispatch response; no direct deployment fallback", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
