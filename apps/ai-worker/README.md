# AI worker: managed runtime pilot

The optional managed runtime executes complex missions in OpenAI's Agents harness while Phoenix retains workspace authority, employee permissions, approvals, credit reservations and saved files. Both `OPENAI_AGENTS_ENABLED` and the workspace's approved runtime policy must permit it. The feature is disabled by default.

## Preflight without execution

From this directory, install the pinned dependencies and run:

```sh
.venv/bin/python -m app.agents.preflight
.venv/bin/python -m app.agents.preflight --json
```

These commands make **no network requests**. They inspect the installed SDK (`openai==3.19.2`), required Agents methods, priced model configuration, database DSN, signing secret, worker credential and positive runtime limits. Exit code `0` means those configuration checks passed; `1` means a check failed. Offline checks do not test database connectivity or account permissions.

An operator can explicitly request read-only provider checks:

```sh
.venv/bin/python -m app.agents.preflight --remote --json
```

This lists one session page and retrieves the two configured model records, with bounded timeouts. It does not create a session, run a turn, delete data or print session contents. It does not prove that a model can execute in the Agents environment. Neither mode changes policy, sets `MANAGED_RUNTIME_VERIFIED_MODELS`, nor enables a workspace. There is deliberately no automatic paid probe in the CLI.

## Pilot prerequisites

1. Apply the Phoenix runtime policy/accounting migrations and provide the worker with a PostgreSQL role allowed to initialize its persistence tables. All replicas must share this database. HTTP admission returns `202` only after the accepted request is committed; SQS deletion likewise follows durable admission. A configured database outage must fail closed.
2. Configure a dedicated `WORKER_AUTH_TOKEN`, the API key, and the webhook signing secret through the deployment secret manager. Register the public Phoenix relay at `POST /api/webhooks/openai/agents` with the provider; it must preserve the signed body and headers when forwarding to the private worker's `POST /webhooks/openai/agents`. The worker verifies the raw body with the SDK, checks the replay timestamp, deduplicates event IDs and resolves session ownership from PostgreSQL. Provider metadata cannot select a workspace or run. Unknown sessions receive `503` so a create/checkpoint race can retry.
3. Keep `OPENAI_AGENTS_ENABLED=false` while checking readiness. Confirm the selected models support the required Agents features with the actual account. Any live pilot that starts a turn can incur cost and needs explicit operator authorization and a bounded test budget. After those checks, the operator may list approved models in the Phoenix variable `MANAGED_RUNTIME_VERIFIED_MODELS`; preflight never writes that variable.
4. Workspace activation uses the authorized `/api/ai/runtime-policy` endpoint. Consent records the member and policy version. Current policy exposes US data processing and no zero-data-retention guarantee. Withdrawal disables future managed work. Do not bypass workspace membership or permission checks to activate a pilot.
5. Keep the sandbox network disabled unless particular domains are required and approved. `OPENAI_AGENTS_ALLOWED_DOMAINS` accepts a JSON array; it is not general network access. Business integrations stay behind Mokaid function tools and their current permissions. Colleagues use their recorded employee identity and the mission's common budget.

The pilot budgets are currently 50 cents for standard and 200 cents for complex missions, with at most four active sessions per workspace. Phoenix owns these caps and credit reservations. Provider usage is a conservative versioned estimate using published upper context rates, not a final invoice; unsupported models and unavailable usage must not be priced at zero. Unknown usage leaves a reservation pending reconciliation. The budget panel displays credits, not provider implementation details.

If Tavily is configured, each attempted basic search also reserves an estimated `$0.01` in the tool usage tracker (including a failed attempt that falls back to DuckDuckGo). Set `TAVILY_SEARCH_COST_USD` to the appropriate conservative rate for your supplier contract. DuckDuckGo has no per-call supplier fee in this tracker. Sandbox estimates use the published base container rate; compare them with the actual account invoice during the pilot before enabling additional compute configurations.

## Recovery and retention

Worker replicas claim accepted requests through a lease in PostgreSQL. A crashed owner can be replaced after lease expiry. Cancellation and approval decisions are durable commands; an approval is consumed only after its decision has been recorded. A tool operation's business key survives session changes. An externally visible operation with an ambiguous outcome is paused for reconciliation rather than blindly repeated.

Only published provider artifacts can be recovered from an expired environment. The worker validates and imports them into Mokaid with an immutable artifact key. It preserves per-session usage, actual command evidence and a manifest of the saved Drive files. Unpublished scratch work may be unavailable; a replacement environment cannot restore files the provider never published.

Completed or paused sessions become eligible for retention after seven days. An hourly sweep claims each affected mission independently of the admission loop, explicitly cancels provider activity, reads final usage and evidence, imports published files, records accounting, confirms the final delivery callback, and then deletes provider sessions. A paused mission that reaches this limit is canceled with its saved files available. Failed imports, callbacks or provider deletions remain retryable and do not falsely mark the remote session deleted. An explicit unknown-usage accounting receipt permits remote deletion while the local accounting snapshot and Phoenix reservation remain pending reconciliation. No local execution journal is purged while delivery or accounting remains pending.

Successful, delivered sessions with known usage may be deleted earlier. Deleting a provider session does not delete imported Mokaid files.

## Required pilot validation

Automated fake-provider tests cover the following matrix. Before a production pilot, exercise equivalent end-to-end scenarios in an isolated workspace with an operator-approved budget and check the actual provider/credit receipts.

| Scenario | Required outcome |
| --- | --- |
| HTTP or SQS database outage | No accepted response or SQS deletion before persistence; no model execution. |
| Two replicas receive the same run | One lease owner, one business execution, original workspace identity retained. |
| Crash after a provider session is created | Recover the stored session or reconcile the creation token; do not create a duplicate blindly. |
| Crash after a tool starts but before its receipt | Pause the ambiguous operation for reconciliation. |
| Approval reaches another replica | Owner consumes the durable decision exactly once. |
| Workspace permission or tool access is revoked | The next effect is denied under current Phoenix authority. |
| Stop, budget exhaustion or missing usage | Cancel remote activity, preserve outputs, keep unknown accounting pending. |
| Report, code or calculation claims success | Verify actual files, sources or command results before completing the mission. |
| Phoenix delivery fails after model completion | Retry the durable delivery receipt without running the model again. |
| A published file is imported twice | Same immutable artifact key resolves to the existing saved file. |
| Environment expires or worker restarts | Preserve known artifacts and usage across sessions; do not replay external actions. |
| Seven-day retention runs on two replicas | One retention owner; evidence, files and accounting precede provider deletion. |

Local tests do not call the provider:

```sh
.venv/bin/python -m pytest tests/test_runtime_store.py tests/test_runtime_dispatch.py tests/test_runtime_webhooks.py tests/test_runtime_cleanup.py tests/test_runtime_preflight.py tests/test_managed_runtime.py tests/test_openai_runtime_adapter.py -q
```

To validate real PostgreSQL locking, supply `RUNTIME_TEST_DATABASE_URL` for a local test database and run `tests/test_runtime_store_postgres.py`. Tests create and drop their own random schema; never point this variable at production. No deployment or remote model test is performed by these commands.

Provider contract: [Agents API overview](https://developers.openai.com/api/docs/guides/agents-api/overview).
