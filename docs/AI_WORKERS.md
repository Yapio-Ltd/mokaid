# AI Workers

The AI worker (`apps/ai-worker`) executes agent runs isolated from the main API.

## Lifecycle

```txt
queued → running → (waiting_for_approval ⇄ running) → completed | failed | canceled
```

1. Phoenix dispatches a run (`POST /runs` in dev, SQS message in prod).
2. The runner plans steps (deterministic plans today; LangGraph LLM planner behind the same interface).
3. Each tool call is scored (`app/policies/approval.py`). HIGH/CRITICAL risk pauses the run:
   - callback `POST /api/worker/runs/:id/approval` to Phoenix,
   - Phoenix creates a `task_approval_request` and broadcasts to the workspace,
   - a human decision hits `POST /runs/:id/resume` with `approved | rejected | edited`.
4. Completion/failure is reported via callbacks; Phoenix persists the run output and broadcasts.

## Tool risk model

| Risk | Examples | Behavior |
|---|---|---|
| low | `search_knowledge`, `summarize`, `read_file` | run freely |
| medium | `draft_document`, `update_task`, `upload_file` | run, result reviewable |
| high | `send_email`, `post_social`, `call_external_api` | **always require approval** |
| critical | `make_purchase` | approval + audit log |

Unknown tools default to HIGH (fail-closed).

## Ingestion pipeline

`POST /ingest` chunks documents (1200 chars, 150 overlap) and — once provider keys are configured — embeds them (OpenAI `text-embedding-3-small`, 1536 dims) and posts vectors back to Phoenix for pgvector storage.

## Endpoints

| Method | Path | Description |
|---|---|---|
| GET | `/health` | Liveness + registered tools |
| POST | `/runs` | Start a run (202) |
| GET | `/runs/:id` | Run state |
| POST | `/runs/:id/resume` | Human decision |
| POST | `/ingest` | Document ingestion |

All endpoints require `Authorization: Bearer <WORKER_AUTH_TOKEN>` (shared with Phoenix).

## Development

```bash
cd apps/ai-worker
pip install -e ".[dev]"
uvicorn app.main:app --reload --port 8000
pytest
```

Runs are held in memory per instance; production hardening externalizes state to a LangGraph checkpointer (Postgres/Redis) so runs survive restarts.
