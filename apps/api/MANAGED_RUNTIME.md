# Managed runtime backend contract

This slice is disabled for every workspace until an administrator enables it and explicitly accepts US processing and retained session data. Apply migrations `20260925140000`, `20260925141000`, and `20260925142000` before starting this API version. No provider requests are made by these endpoints.

`MANAGED_RUNTIME_VERIFIED_MODELS` is a comma-separated deployment-owned list of model IDs verified against the actual Agents API project. It is empty by default. The API does not accept model allowlists or supplier budgets from browser settings.

## Workspace policy

- `GET /api/ai/runtime-policy`: requires workspace membership and `workspace.view`.
- `PATCH /api/ai/runtime-policy`: requires `workspace.update`; accepts only `enabled` and `data_policy_accepted` booleans. Revoking consent disables execution. Enabling without consent fails.
- Aliases: `/api/workspaces/:id/runtime-settings`, with an explicit same-workspace check.
- Public responses expose credits, US region and retention policy, plus `meta.can_update`; they do not expose provider prices. Consent actor, timestamp and version are retained server-side.
- Generic workspace updates cannot mass-assign this policy.

## Worker callbacks

All routes are `POST /api/worker/runs/:run_id/runtime/:action`, require the existing worker bearer token and a matching `workspace_id`. Responses use `{data: ...}`; rejected actions also return `data.allowed: false` and a machine-readable `reason` with a 4xx status.

| Action | Additional request | Effect |
| --- | --- | --- |
| `authorize` | `agent_id`, optional `tool_name` | Validates current run/task/agent/policy, refreshes a valid 300-second participant lease, applies both lead and colleague denials and current MCP grant intersection. Returns current autonomy and grant keys. An authorized `mcp:key:tool` call additionally returns only that server's current descriptor and credentials in `mcp_server` for the private Mokaid worker; these must never enter provider/model context. A tool call needs an existing reservation. |
| `reserve` | `complexity: standard\|complex`, optional `recovery: true` | Once per run, reserves 500/2000 credits (server budget 50/200 cents) and the root slot atomically. Recovery may re-acquire the existing root slot after the worker obtains its durable execution claim. It never adds budget. |
| `participants` | `participant_id`, `agent_id`, optional `recovery: true` | Reserves a colleague slot. Root and colleagues together occupy at most four slots per workspace. A colleague cannot be active in two runs. Recovery re-acquires an existing participant slot under the same worker ownership requirement as root recovery. |
| `release-participant` | `participant_id` | Idempotently releases capacity, including after Stop. |
| `settle` | `cost_cents: integer\|null`, `usage_status: actual\|estimated\|unknown` | Releases capacity and settles at most the reserved credits. Unknown usage retains the reservation as `pending_usage`; later known usage can settle it. A settled reservation cannot be charged again. |
| `file` | `agent_id`, `file_id` | Returns a signed URL only for an active, authorized task input/output in this workspace. |

The worker must acquire its durable ownership claim before any callback, especially `reserve(recovery: true)`. Phoenix participant leases limit workspace capacity; worker claim fencing prevents concurrent executors for a run. A caller must not treat connection/SSE closure as provider cancellation.

## Accounting and outputs

Reservations debit included credits first, then purchased credits, under subscription and workspace locks. Insufficient prepaid credits reject the whole reservation, including its slot. Settlement refunds the unused portion; each funding tranche records its credit period so extensions across monthly renewal cannot revive expired grants. Unlimited subscriptions meter without balance changes. Usage records include whether a settled amount was actual or estimated. Estimates are final for this reservation; unknown values remain pending, not zero.

Completion/failure/cancellation transitions release runtime participants and preserve unknown usage. Legacy completion callbacks never debit a managed run again. Settlement and release remain accepted after cancellation or policy disablement.

Managed `/status` callbacks synchronize failed task/agent state and preserve partial manifests. A delayed callback cannot reopen a completed, failed, or canceled run. A canceled/failed final callback may still add its produced output. Pauses release all participant slots while retaining their reserved credits; resuming requires explicit lease recovery. A reserved managed pause remains an existing run for Run AI and Stop, preventing an accidental second reservation.

Human comments during a managed pause still reach the conversation classifier. A status question receives a reply only. An actionable instruction during a non-budget pause queues a durable continuation of the same run, using the comment ID as `command_id` and `{runtime_user_input: true, instruction: comment.body}` as payload. The comment author must retain execution permission; a pending sensitive approval cannot be accepted through this path. Budget-paused instructions explain the explicit credit-extension action without resuming or charging. The worker must also reject free-text resume commands while an approval is pending.

`POST /api/worker/tasks/:id/output` optionally accepts `run_id`, `agent_id`, and `artifact_key`. The artifact key is idempotent within a run/task, serialized across concurrent imports. A historical participant may import already-produced files after cancellation; this exception only saves files and does not authorize further model/tool work. Persisted files retain their actual author. Existing legacy requests remain supported.

## Explicit budget extensions

`POST /api/tasks/:id/runtime-budget` requires active membership with `agents.run_ai` and accepts `{run_id, request_id: UUID, additional_credits: 500 | 2000}`. The run must be `waiting_for_user_input` with `output.runtime.status` equal to `waiting_for_budget` and an open reservation. Its original task and assignment must still be current. Insufficient credits return 402; an invalid run state returns 409.

The debit, additional funding tranche, budget revision, task/run transition, and durable resume command are committed together. Retrying the same request UUID and amount returns the prior receipt without another debit or command. Reusing the UUID for another run or amount fails. Public receipts contain `run_id`, `reserved_credits`, `budget_revision`, and `status`; supplier budgets remain internal.

`RuntimeResumeWorker` retries delivery of the existing run's resume command. Its `command_id` is the request UUID and its payload includes `runtime_budget_extended: true` and `budget_revision`. A stopped run or superseded revision is not resumed. Delivery never creates a replacement run or buys another reservation.

## Durable callback receipts

The approval-request callback accepts an optional `operation_key` (1–200 bytes). Repeated requests for the same run/key return the existing approval, including its current status; a different tool or payload conflicts. A completed decision is never reset to pending by a retry.

For managed runs, `/api/worker/runs/:id/complete` commits completion effects and the final task comment with a finalization receipt. The full summary is retained. Repeated delivery neither duplicates the comment nor re-awards completion effects; a late completion cannot revive a canceled or failed run. The worker must not separately publish a final comment for this path.

## Public webhook relay

Configure the provider to send Agents events to `POST /api/webhooks/openai/agents` on the public Phoenix origin. Phoenix preserves the original signed body, enforces a 1 MiB limit before JSON parsing, and forwards only the body plus `webhook-id`, `webhook-signature`, and `webhook-timestamp` to `AI_WORKER_URL/webhooks/openai/agents`. This direct HTTP relay operates even when mission dispatch uses SQS. The worker remains responsible for SDK signature verification and durable event ownership.

The relay uses a one-second connection timeout and five-second response timeout without redirects or retries. Verified/persisted worker success returns 202; invalid signatures return 400; unavailable worker or unpersisted events return 503 so the provider retries. Signature values, request payloads and provider keys are not logged by the relay. Missing worker configuration fails closed with 503.

Tests: `MIX_ENV=test mix test test/mokaid/managed_runtime_test.exs test/mokaid_web/runtime_policy_controller_test.exs test/mokaid_web/runtime_webhook_controller_test.exs`.
