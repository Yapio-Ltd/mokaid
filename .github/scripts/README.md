# ECS deployment contract

These scripts require Python 3.10+, AWS CLI v2 and an already healthy service using
the ECS rolling deployment controller. They do not provision infrastructure or
bootstrap services with zero desired tasks. The workflow must serialize production
releases; ECS UpdateService has no compare-and-swap primitive, so the baseline
checks cannot prevent an independent operator racing an update.

## Order and inputs

1. Build, push and scan immutable images, retaining each registry digest.
2. Test the exact API/web/CRM images in isolated ephemeral staging.
3. Renew the short-lived AWS session, then prepare the API task definition without changing the live service.
4. Run the migration from that exact prepared revision, before rolling the API.
5. Deploy the API revision; prepare/deploy the remaining services after success.

| Script | Required environment | Result |
| --- | --- | --- |
| `prepare-ecs-task.sh` | `CLUSTER`, `SERVICE`, `CONTAINER`, `IMAGE`, `GITHUB_OUTPUT` | Register a new task revision based on the revision actually used by the active service. |
| `run-ecs-migration.sh` | `CLUSTER`, `SERVICE`, `CONTAINER`, `TASK_DEFINITION` | Run the fixed migration command from the exact prepared revision, using the service network. |
| `deploy-ecs-service.sh` | `CLUSTER`, `SERVICE`, `TASK_DEFINITION`, `PREVIOUS_TASK_DEFINITION` | Roll out the prepared revision and verify it; restore the previous revision on failure where safe. |
| `rollback-ecs-batch.sh` | `ROLLBACK_BATCH_JSON` | Restore prepared services in reverse order after a later service or smoke-test failure. |

`IMAGE` must be `repository@sha256:<64 lowercase hexadecimal characters>`; tags
are rejected. Task definitions must be full revisioned ARNs, not family names or
`latest`. `CONTAINER` is matched by name exactly once, never by array position.

`GITHUB_OUTPUT` must already exist and be a regular non-symlink file. Preparation
appends these lowercase output keys:

```text
task_definition=arn:aws:ecs:REGION:ACCOUNT:task-definition/FAMILY:NEW_REVISION
previous_task_definition=arn:aws:ecs:REGION:ACCOUNT:task-definition/FAMILY:OLD_REVISION
container=EXACT_CONTAINER_NAME
image=REPOSITORY@sha256:DIGEST
```

Pass both task-definition outputs unchanged into subsequent steps. Also pass
`PREVIOUS_TASK_DEFINITION` to migration: it is optional for that script but rejects
a migration whose live service changed since preparation. No task-family lookup
occurs after preparation. Existing resources, runtime platform, sidecars, secrets,
environment and task tags are retained; only the named container's image and the
following explicitly permitted API settings may change.

## Desktop rollout settings

Preparation optionally accepts `MOKAID_DESKTOP_ONLY_BUSINESS`, exactly `true` or
`false`, and `DESKTOP_AUTH_WEB_BASE_URL`, exactly `https://mokaid.com`. These settings
may only target container `mokaid-prod-api`; conflicting secret references fail.
Absent variables retain the existing environment. Other environment variables are
not forwarded into the task definition.

**Before passing `true`, the workflow must independently verify that the public
signed desktop installers, release manifest and downloads are ready.** These ECS
scripts validate the configuration literals, not installer readiness. The backend
default remains off; preparing a task does not activate it.

## Success, failure and cancellation

Deployment succeeds only when the live service references the exact requested ARN,
has one primary deployment marked `COMPLETED`, zero pending tasks, and its running
counts equal its positive desired count. A service that stabilizes on the previous
revision after an automatic rollback is a failed deployment, not success.

On rollout failure or a handled interruption, restore and verify the captured
previous ARN. The step remains failed even if rollback succeeds. If a third
revision has taken control, do not overwrite it. Failure to verify rollback reports
that operator attention is required. A forced runner termination cannot execute
cleanup; configure an ECS circuit breaker and operational monitoring independently.

The workflow renews its one-hour AWS OIDC session after builds, scans and staging,
before any production task preparation. Recovery gets a separate fresh one-hour
session before restoring the batch; it must not rely on credentials issued before
potentially lengthy builds. Both failure and cancellation request batch recovery.
Cancellation remains best-effort: GitHub's forced shutdown deadline may interrupt
that recovery, and a terminated runner cannot renew credentials or restore services.
Inspect the exact live ECS revisions before retrying after an interrupted run.

Migration only overrides the named container's command:

```text
bin/mokaid eval Mokaid.Release.migrate()
```

There are no caller-provided command, environment, subnet or security-group
overrides. Migration requires Fargate/awsvpc, a healthy baseline, the active
service's network and the exact prepared definition. It checks `run-task` failures,
task identity and the named container's integer exit code. Sidecar array position
does not affect this check. Initial matching `MISSING` task lookups are retried
with bounded backoff for ECS eventual consistency; other lookup failures fail.

Timeout, interruption or lookup failure requests `StopTask` for the known migration
task. Denied cleanup remains an error requiring operator action. Each submission
has one generated idempotency key and a public `startedBy` correlation ID. A lost
`RunTask` response is **not** blindly resubmitted: inspect tasks with the logged
`startedBy` ID before retrying, because a task may have been accepted without its
ARN being returned. Cleanup is not claimed when that ARN is unknown.

Database migrations must be backward-compatible with the still-running previous
API and workers. A service rollback does not undo schema/data migrations; automatic
database rollback is intentionally absent. Review expand/contract compatibility
before publishing a release.

### Whole-release rollback after a later failure

A per-service rollback does not restore an API already deployed successfully if a
later worker, web, CRM or public smoke check fails. The workflow's failure cleanup
must therefore call `rollback-ecs-batch.sh` with `ROLLBACK_BATCH_JSON`, a JSON array
of **one to four** prepared entries, in original deployment order (API, worker,
web, CRM). Omit entries whose preparation did not return both ARNs. Each object
requires exactly these nonempty string keys:

```json
[
  {
    "cluster": "mokaid-prod",
    "service": "mokaid-prod-api",
    "task_definition": "arn:aws:ecs:il-central-1:123456789012:task-definition/mokaid-prod-api:13",
    "previous_task_definition": "arn:aws:ecs:il-central-1:123456789012:task-definition/mokaid-prod-api:12"
  }
]
```

These are schema examples, not live deployment identifiers. Generate actual JSON
with a JSON encoder from the preparation outputs; never interpolate untrusted
shell code. Names must be exact short cluster/service names, services must be
unique, and revision ARNs must be distinct and from the same family for each
entry. Malformed, empty, oversized or duplicate batches are rejected before AWS.

All entries are inspected first. Before each reverse-order restoration the script
rechecks ownership: only the prepared revision or captured previous revision is
eligible. A third-party revision is preserved and reported as failure; other
eligible services are still restored. An already healthy previous revision causes
no update. If ECS has already started a rollback to it, the script waits without
forcing another deployment. Every restoration is checked, then all successful
entries are checked again at the end. Any failure yields a nonzero exit code and
operator attention; the original release must remain failed even if cleanup exits
zero. No database migration is reversed.

This is a guarded, best-effort rollback of a release batch, **not an atomic ECS
transaction**. An independent operator can still race the interval between a read
and UpdateService; serialize releases and coordinate operator actions. A failure
can leave a mixed-version set, which is why backward compatibility and monitoring
are required. `ROLLBACK_TIMEOUT_SECONDS` applies **per service**, so four services
can need 40 minutes at the default, plus bounded AWS requests. Allow enough job
time for cleanup after the primary deployment steps.

Defaults (positive integer seconds; at most 3,600 for timeouts):

| Setting | Default |
| --- | --- |
| `DEPLOY_TIMEOUT_SECONDS` | 1,200 |
| `ROLLBACK_TIMEOUT_SECONDS` | 600 |
| `MIGRATION_TIMEOUT_SECONDS` | 600 |
| `POLL_INTERVAL_SECONDS` | 15 for deploy; 10 for migration; maximum 60 |

Each AWS CLI command also has a 60-second process limit. A polling deadline can
therefore be exceeded by one in-flight bounded command, plus any cleanup/rollback.
Give the workflow sufficient time for both deployment and rollback.

## IAM, confidentiality and validation

Use short-lived GitHub OIDC credentials restricted to the intended environment.
Required ECS operations are `DescribeServices`, `DescribeTaskDefinition`
(`--include TAGS`), `RegisterTaskDefinition`, `UpdateService`, `RunTask`,
`DescribeTasks`, and `StopTask`, with tag read/create permissions as required by the
configured policy. Scope `TagResource` for task-definition registration, and scope
`iam:PassRole` to the existing execution/task roles and ECS tasks service. Image
push, release preflights and monitoring have separate permissions. Validate the
effective role in staging, including tag preservation and cleanup after a denied
or interrupted rollout.

Task-definition request bodies are private temporary JSON files, not command-line
arguments. Their directory is private, file mode is `0600`, and normal cleanup
removes them. AWS response/error bodies are never printed because legacy task
environment values may contain secrets. Logs contain only validated resource IDs,
the public migration correlation ID and generic failure categories. Do not enable
shell tracing or AWS debug logging in the calling workflow.

Run the local tests without credentials or network:

```sh
python3 -m unittest discover -s .github/scripts/tests -p 'test_*.py' -v
bash -n .github/scripts/prepare-ecs-task.sh .github/scripts/deploy-ecs-service.sh .github/scripts/run-ecs-migration.sh .github/scripts/rollback-ecs-batch.sh infra/scripts/deploy-web-ecs.sh
```

All external command execution is mocked. These tests do not validate actual AWS
permissions, account quotas, application startup, migrations against production
data or health-check behavior. A controlled staging rollout remains required.

## Local production request wrapper

`infra/scripts/deploy-web-ecs.sh` is now only a GitHub workflow request wrapper:

```sh
infra/scripts/deploy-web-ecs.sh prod
```

Running this command requests a real production deployment and therefore requires
explicit release authorization. No arguments, other environments, image tags and
extra arguments are rejected before external commands. The wrapper uses GitHub CLI
on github.com with the fixed repository `Yapio-Ltd/mokaid`, workflow `deploy.yml`,
ref `prod` and input `environment=prod`. It checks the current production SHA,
requires completed successful push CI on that exact SHA and checks the head has
not changed before dispatch. An unconfirmed dispatch is not blindly retried:
inspect the workflow runs first.

There is no local Terraform, Docker, AWS, image selection or readiness override.
The authoritative workflow repeats commit/CI validation and owns production
approvals, OIDC credentials, installer readiness, immutable images, deployment and
smoke tests. A successful wrapper exit means only that a workflow was requested,
not that deployment succeeded. The previous `TASK_FAMILY` + tagged `IMAGE` direct
deploy contract remains unsupported, with no automatic compatibility fallback.

AWS references: [RunTask, explicit revisions, idempotency and eventual consistency](https://docs.aws.amazon.com/AmazonECS/latest/APIReference/API_RunTask.html),
[DescribeServices](https://docs.aws.amazon.com/AmazonECS/latest/APIReference/API_DescribeServices.html).
