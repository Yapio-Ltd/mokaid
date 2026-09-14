# GitHub environment policy

`desired.json` is the reviewed, non-secret source of truth for the five managed
environments in **Yapio-Ltd/mokaid**. `reconcile.py` uses Python 3.11+ and an
authenticated `gh` CLI. It has no third-party runtime dependencies and performs
**GET requests only unless `--apply` is explicitly supplied**.

## Reviewed release contract

| Environment | Permitted deployment refs | Required reviewer |
| --- | --- | --- |
| `prod` | Branches `main`, `prod` | None added |
| `desktop-signing-stable` | Tags `desktop-v*`, branch `main` | `Tomyshh`, user ID `113070134` |
| `desktop-signing-beta` | Tags `desktop-v*` | `Tomyshh`, user ID `113070134` |
| `desktop-public-stable` | Branch `main` | `Tomyshh`, user ID `113070134` |
| `desktop-public-beta` | Branch `main` | `Tomyshh`, user ID `113070134` |

Both `prod` branches are intentional: a `workflow_run` deployment executes from
the default branch `main`, while its source CI run targets `prod`. The deployment
workflow must additionally validate the successful source workflow, source branch
and exact commit. The environment branch rule alone does not establish this.

Desktop candidate signing starts from a `desktop-v*` tag; the release workflow additionally
checks the tagged commit's ancestry and chooses stable/beta from its validated
version. Public promotion is a default-branch workflow dispatch and reuses the
verified candidate binaries. These workflow checks and AWS OIDC subjects remain
separate controls; this tool does not modify or certify them.

The owner-approved stable-only `main` extension admits the manually dispatched
[private Mac signing probe](../../apps/desktop/docs/private-macos-signing-probe.md).
It does not add `main` to beta, grant public promotion, change AWS roles, activate
desktop-only, or add a repository ruleset. An environment ref policy admits any
job on that ref which names this environment; it is not a workflow-file allowlist.
Before approving a main probe job, inspect its exact workflow/source SHA, the
current `main` SHA and the verified current-run unsigned archive identity. The
same required reviewer must approve access; no run is automatically approved.
The owner separately authorized the unsigned intermediate Actions artifact with
one-day retention on this public repository. This utility never uploads that
artifact, dispatches the probe, or publishes signed output.

**Before approving either signing environment**, the operator must inspect the
exact tag commit SHA, the workflow source at that SHA, its source ancestry, and
the frozen trusted tooling SHA and signing/package scripts it executes. A tag-triggered workflow comes from
that tag: its own ancestry check is not an independent authorization boundary.
The signing reviewer gate is required before real signing-secret access is wired.
Approving the environment authorizes the whole signing job, not just its later
AWS/Azure login step; `id-token: write` also applies to its earlier restore/tool
installation steps. Unsigned compilation, cooking, tests and staging now run in
separate jobs with neither OIDC permission nor a signing environment. The signing
jobs download exact current-run artifact IDs and verify source/tooling SHA,
platform, version, run attempt, public key and every archived file before restore.
The archive preserves native bundle symlinks and executable modes without running
the staged application. See [the stage-transfer contract](../../apps/desktop/distribution/STAGE_TRANSFER.md).
Never approve a run solely because the tag name matches `desktop-v*`.

Restrict creation, mutation and deletion of those tags with a separately reviewed
ruleset, and protect `main`/`prod`. The workflow separation is already implemented;
it does not replace these source/ref and reviewer controls. No repository
ruleset or branch-protection change is silently applied by this environment tool.

`prevent_self_review=false` allows the sole named operator to approve their own
run. A different existing reviewer list is **not** automatically merged: GitHub
requires approval from only one listed reviewer, so adding reviewers can weaken
the gate. A stronger existing self-review prohibition or wait timer is preserved.

The repository was verified public when this policy was introduced. GitHub Free
supports required reviewers and wait timers for public repositories; private
repositories require the applicable paid capabilities. Unsupported API responses
are fatal; the tool never retries with weaker controls.

## Review and apply

Run from the repository root:

```sh
python3 infra/github/reconcile.py --help
python3 infra/github/reconcile.py --plan
```

The plan is JSON on stdout. Review **every operation**, unresolved-variable
warning and `plan_sha256`. After approval, use its exact digest:

```sh
python3 infra/github/reconcile.py --apply --expect-plan REVIEWED_SHA256
python3 infra/github/reconcile.py --plan
```

Replace `REVIEWED_SHA256` with the 64-character digest printed by the reviewed
plan. Applying requires repository administration privileges and access to the
managed Actions/environment variables. `gh` supplies authentication; this program
does not print tokens or request secret values. It reads only named allowlisted
variables, never lists arbitrary variable values, and cannot call secret APIs.
Its process timeout is 45 seconds per request, with at most four concurrent reads.
Writes are sequential, and failures are not retried automatically.

### One-time stable signing main migration

The extension was explicitly authorized on 2026-09-14; the reviewed source base
was `4765db93fc399ed3919866b06f7a4d57c3854ba9`. This records authorization and desired
state, **not proof that the GitHub policy has been applied**. From a checkout of
this reviewed reconciler, use the dedicated bounded mode:

```sh
python3 infra/github/reconcile.py --stable-signing-main --plan
# Review the complete output and its plan_sha256 before the next command.
python3 infra/github/reconcile.py --stable-signing-main --apply --expect-plan REVIEWED_SHA256
python3 infra/github/reconcile.py --stable-signing-main --plan
```

The only permitted mutation is:

```text
POST repos/Yapio-Ltd/mokaid/environments/desktop-signing-stable/deployment-branch-policies
{"type":"branch","name":"main"}
```

The environment must already exist in custom-ref mode, with its exact existing
tag `desktop-v*`, the required reviewer `Tomyshh` / `113070134`, and known bypass
controls. There is no environment PUT, tag replacement/deletion, reviewer
rewrite, variable change, bootstrap or collateral repair. A missing environment,
missing reviewer, any other ref set, or any operation needed elsewhere stops the
entire migration before writes. Existing longer wait timers, self-review bans
and disabled administrator bypass remain untouched. Unresolved (`null`) public
variables remain unmanaged as before, not a claim of release readiness.

The mode is included in the plan digest. Apply recomputes the allowed operation,
checks the exact observed baseline immediately before the POST and reads back
all observed state afterwards. It accepts only the added main rule and a possible
server-owned `updated_at` change on the target environment; existing tag rule
IDs, protections, other environments and observed variables must be unchanged.
Once both refs already exist, this mode is a no-op; it still rejects all other
required mutations. A failed/ambiguous POST, stale digest or unexpected readback
stops without retry or rollback. Inspect a fresh plan after any uncertainty.
The generic mode still refuses to expand an existing custom ref set; the explicit
flag is mandatory for this migration. GitHub has no atomic cross-endpoint
transaction: pause concurrent environment administration until verification ends.

The apply path reconstructs the plan, checks its digest, re-reads all relevant
state immediately before writing, and requires the original fingerprint to match.
It then re-reads state and requires an empty remaining plan. A second run after a
successful apply is a no-op. API diagnostics go to stderr; no workflow is started,
artifact is published, or secret is uploaded by this tool.

GitHub does **not** provide a documented atomic transaction for these endpoints.
Do not edit the same environments concurrently, and do not activate new AWS
publisher-role trust until the full apply and read-back have succeeded. A crash
can leave a partial configuration. In particular, creating an environment and its
separate branch/tag rules takes multiple requests. A subsequent run deliberately
refuses to expand an existing empty or different custom rule set; inspect and
repair that interrupted configuration explicitly, then re-plan. There is no
automatic deletion, rollback, or assumption that an interrupted apply succeeded.

## Preservation and limits

- Existing longer wait timers, stronger self-review requirements, and additional
  reviewer requirements on `prod` are preserved.
- Existing custom ref rules must match exactly, except for the explicitly selected
  stable-only migration above. Other narrower rules, extra rules,
  protected-branch mode, unexpected protection types, custom deployment
  protection rules, and incomplete API pages stop the entire plan before writes.
- A configured public variable with a different existing value stops planning;
  there is no implicit variable replacement. Review that drift and explicitly
  reconcile it before proceeding. This prevents stale desired data from replacing
  an independently rotated role, key or destination.
- A `null` desired variable is **unmanaged**, not empty, absent, or scheduled for
  deletion. Existing values are preserved; add the verified public value to this
  file after its AWS resource or public signing key actually exists.
- `AWS_DEPLOY_ENABLED` is intentionally neither read nor written; its existing
  repository setting remains untouched.
- `MOKAID_DESKTOP_ONLY` is restricted to `"false"`. Signed installers and updates
  on both platforms must be verified before a separate reviewed rollout changes
  that flag. This utility does not implement an activation escape hatch.

### Administrator bypass and branch protection

GitHub reports `can_admins_bypass`, but the documented REST environment update
schema does not expose a writable field for it. This tool **does not claim to
disable administrator bypass** and does not invent unsupported REST or GraphQL
fields. If an existing environment has bypass disabled, an otherwise necessary
environment PUT is refused conservatively; no-op verification and independent
variable additions preserve the setting. Newly created environments can retain
GitHub's administrator-bypass default. Review that setting in GitHub's environment
UI if a non-bypassable approval gate is required.

Branch protection/rulesets on `main` and `prod` are out of scope and were absent
when this policy was introduced. Environment branch restrictions do not protect
the content of those branches from modification. Add repository branch/ruleset
controls through a separately reviewed policy; do not confuse the two features.

## Public variables and private credentials

| Scope | Managed public values |
| --- | --- |
| Repository | Existing AWS deploy role ARN; desktop-only flag kept false |
| `prod` | Desktop-only flag kept false |
| Signing stable/beta | AWS region; signing role ARN; macOS/Windows signing-secret **ARN references**; Ed25519 **public** update key |
| Public stable/beta | AWS region; publishing role ARN; downloads bucket; CloudFront distribution ID; Ed25519 **public** update key |

The AWS account is restricted to `660601648321` and the region to `il-central-1`.
Unknown variable names and malformed values are rejected without echoing their
contents. AWS role and secret ARNs are identifiers, not private credentials.
Leave unresolved values `null` until verified from the infrastructure outputs.
For a new public value, edit `desired.json`, review the plan and apply it again.

The independent [stable signing IAM module](../terraform/modules/desktop-signing/README.md)
can provision only `mokaid-desktop-signing-stable` with read access to the exact
existing stable macOS signing secret. It does not depend on CloudFront readiness,
grant beta/Windows/application access, or create secret material. Its source and
plan are not proof of deployment: verify the applied role and approval gate before
recording its public ARN here. Distribution and desktop-only activation remain
separate, fail-closed steps.

Never place Apple passwords/certificates, Windows signing credentials, AWS access
keys, GitHub tokens or Ed25519 private keys in this JSON. Store signing credentials
in the approved secret store and supply only its ARN references here. A 32-byte
Ed25519 public-key format check cannot distinguish a public key from an
accidentally pasted 32-byte private seed; verify that the value is the **exported
public key** before committing it. The tool does not provision credentials or
replace the release workflow's signature, notarization and readiness checks.

## Offline verification

```sh
python3 -m venv /private/tmp/mokaid-github-policy-tests
/private/tmp/mokaid-github-policy-tests/bin/python -m pip install -r infra/github/requirements-dev.txt
/private/tmp/mokaid-github-policy-tests/bin/python -m pytest -c infra/github/pyproject.toml infra/github/tests --cov=reconcile --cov-branch --cov-report=term-missing --cov-fail-under=90
/private/tmp/mokaid-github-policy-tests/bin/mypy --strict infra/github/reconcile.py
/private/tmp/mokaid-github-policy-tests/bin/ruff check infra/github
/private/tmp/mokaid-github-policy-tests/bin/black --check infra/github
```

Tests use a stateful fake API and fake `gh` subprocesses; they perform no network
requests. They cover first creation, repeatable no-op, stale approvals, concurrent
drift, preservation, ref/tag distinction, incomplete pagination, unknown rules,
private-value rejection, reviewer OR semantics, partial failures, read-back,
timeouts and cancellation including a subprocess which already exited.

Optional interactive completion is provided in `completions/reconcile.zsh` and
`completions/reconcile.bash`. Source the matching file from the repository root
to use the `mokaid-github-policy` wrapper. Normal CI usage needs no completion.

## Official API references

- [Environment permissions, plans, reviewers and supported PUT fields](https://docs.github.com/en/rest/deployments/environments?apiVersion=2022-11-28)
- [Separate branch/tag deployment policies and wildcard matching](https://docs.github.com/en/rest/deployments/branch-policies?apiVersion=2022-11-28)
- [Repository and environment Actions variables](https://docs.github.com/en/rest/actions/variables?apiVersion=2022-11-28)
- [GitHub's REST OpenAPI schema](https://github.com/github/rest-api-description/blob/main/descriptions/api.github.com/api.github.com.json)

The client pins REST version `2022-11-28`. Revalidate the documented schema and
tests before changing that API version or the fixed release/ref contract.
