import asyncio
import json
import os
from contextlib import asynccontextmanager

import structlog
from fastapi import FastAPI, Header, HTTPException, Request

import app.tools.files  # noqa: F401 — registers file-processing tools
import app.tools.mail  # noqa: F401 — workspace-scoped mailbox tools
import app.tools.site_delivery  # noqa: F401 — HTML vs codebase choice gate
import app.tools.web  # noqa: F401 — registers web_search
import app.tools.webapp  # noqa: F401 — registers Next/React webapp scaffold tool
import app.tools.website  # noqa: F401 — registers the website generator tool
from app import runtime_dispatch
from app.agents import converse as converse_agent
from app.agents import direct_chat, dispatcher, orchestrator_chat, runner, schedule_parser
from app.config import get_settings
from app.memory.ingestion import ingest_document
from app.queue.consumer import consume_forever
from app.runtime_store import OwnershipConflict, UnknownSession, get_store
from app.schemas import ResumeRequest, RunRequest
from app.tools.registry import list_tools

log = structlog.get_logger()


def _configure_langsmith() -> None:
    """Env-gated LangSmith tracing: with a key set, every deep-agent run,
    LLM call and tool call is traced (LangChain picks the env vars up
    natively). Fully off otherwise — zero overhead."""
    settings = get_settings()
    if not settings.langsmith_api_key:
        return
    os.environ.setdefault("LANGSMITH_TRACING", "true")
    os.environ.setdefault("LANGSMITH_API_KEY", settings.langsmith_api_key)
    os.environ.setdefault("LANGSMITH_PROJECT", settings.langsmith_project)
    log.info("langsmith_tracing_enabled", project=settings.langsmith_project)


@asynccontextmanager
async def lifespan(_app: FastAPI):
    _configure_langsmith()
    from app.agents.runtime_cleanup import cleanup_sessions
    runtime_dispatch.register_session_cleanup(cleanup_sessions)
    recovery = asyncio.create_task(runtime_dispatch.startup())
    consumer: asyncio.Task | None = None
    if get_settings().ai_runs_queue_url:
        consumer = asyncio.create_task(consume_forever())
    yield
    if consumer:
        consumer.cancel()
        await asyncio.gather(consumer, return_exceptions=True)
    recovery.cancel()
    await asyncio.gather(recovery, return_exceptions=True)
    await runtime_dispatch.shutdown()


app = FastAPI(title="mokaid AI worker", version="0.1.0", lifespan=lifespan)

# Strong references to in-flight runs so the event loop never GCs them
# (the per-run cancel registry lives in runner.register_run_task).
_background_runs: set[asyncio.Task] = set()


def _check_auth(authorization: str | None) -> None:
    expected = f"Bearer {get_settings().worker_auth_token}"
    if authorization != expected:
        raise HTTPException(status_code=401, detail="invalid worker token")


@app.get("/health")
async def health() -> dict:
    return {"status": "ok", "tools": list_tools()}


@app.post("/runs", status_code=202)
async def start_run(
    request: RunRequest,
    authorization: str | None = Header(default=None),
) -> dict:
    _check_auth(authorization)

    try:
        created = await runtime_dispatch.accept_run(request)
    except OwnershipConflict as exc:
        raise HTTPException(status_code=409, detail="run identity conflict") from exc
    except Exception as exc:
        log.warning("run_acceptance_failed", error=type(exc).__name__)
        raise HTTPException(status_code=503, detail="run was not durably accepted") from exc

    log.info("run_accepted", run_id=request.run_id)
    return {"accepted": True, "run_id": request.run_id, "duplicate": not created}


@app.post("/runs/{run_id}/cancel")
async def cancel_run(
    run_id: str,
    authorization: str | None = Header(default=None),
) -> dict:
    """Aborts an in-flight run (including one paused for approval)."""
    _check_auth(authorization)

    try:
        await runtime_dispatch.submit_command(run_id, "cancel", command_id=f"cancel:{run_id}")
    except LookupError:
        return {"canceled": False, "reason": "run not found"}
    except Exception as exc:
        raise HTTPException(status_code=503, detail="cancel command was not persisted") from exc

    log.info("run_cancel_requested", run_id=run_id)
    return {"canceled": True, "queued": True}


@app.post("/converse")
async def converse(
    payload: dict,
    authorization: str | None = Header(default=None),
) -> dict:
    """Apply an idle-thread decision before acknowledging delivery to Oban."""
    _check_auth(authorization)

    # Unlike long missions this is one short classification + callback. An
    # asynchronous 202 used to lose instructions when the worker/callback
    # failed after acceptance. The anchored callback is safe to retry.
    if not await converse_agent.converse(payload):
        raise HTTPException(status_code=503, detail="task follow-up was not applied")
    return {"accepted": True}


@app.post("/agent-chat")
async def agent_chat(
    payload: dict,
    authorization: str | None = Header(default=None),
) -> dict:
    """Direct-chat reply (agent DM thread). The reply is posted back through
    the Phoenix worker API which broadcasts it to the floating dock."""
    _check_auth(authorization)

    task = asyncio.create_task(direct_chat.reply(payload))
    _background_runs.add(task)
    task.add_done_callback(_background_runs.discard)
    return {"accepted": True}


@app.post("/orchestrator/chat")
async def orchestrator_chat_endpoint(
    payload: dict,
    authorization: str | None = Header(default=None),
) -> dict:
    _check_auth(authorization)
    try:
        return await asyncio.wait_for(orchestrator_chat.respond(payload), timeout=55)
    except Exception as exc:  # noqa: BLE001 — never pretend a model replied
        log.warning("orchestrator_chat_failed", error=type(exc).__name__)
        raise HTTPException(status_code=503, detail="orchestrator model unavailable") from exc


@app.post("/dispatch/analyze")
async def dispatch_analyze(
    payload: dict,
    authorization: str | None = Header(default=None),
) -> dict:
    """Triage an instruction + files to the best agent. 503 without an LLM
    key so Phoenix falls back to its deterministic heuristic."""
    _check_auth(authorization)

    if not dispatcher.is_available():
        raise HTTPException(status_code=503, detail="llm not configured")

    try:
        return await dispatcher.analyze(payload)
    except dispatcher.InvalidDispatchAnalysis as exc:
        log.warning("dispatch_analysis_invalid")
        raise HTTPException(status_code=422, detail="invalid_dispatch_analysis") from exc
    except Exception as exc:  # noqa: BLE001 — infrastructure errors remain distinct
        log.warning("dispatch_analyze_failed", error=type(exc).__name__)
        raise HTTPException(status_code=502, detail="dispatch analysis failed") from exc


@app.post("/schedules/parse")
async def schedules_parse(
    payload: dict,
    authorization: str | None = Header(default=None),
) -> dict:
    """Turns a natural-language automation request ("every Monday 9am, …")
    into a structured cron schedule. 503 without an LLM key so the UI can
    fall back to manual cron entry."""
    _check_auth(authorization)

    if not schedule_parser.is_available():
        raise HTTPException(status_code=503, detail="llm not configured")

    result = await schedule_parser.parse(payload)
    if result.get("error") == "empty_request":
        raise HTTPException(status_code=422, detail="text is required")
    if result.get("error"):
        raise HTTPException(status_code=422, detail="could not parse a schedule")
    return result


@app.post("/runs/{run_id}/resume")
async def resume(
    run_id: str,
    request: ResumeRequest,
    authorization: str | None = Header(default=None),
) -> dict:
    _check_auth(authorization)

    if request.run_id != run_id:
        raise HTTPException(status_code=400, detail="run_id mismatch")
    try:
        await runtime_dispatch.submit_command(run_id, "resume", request.model_dump(mode="json"),
                                               command_id=getattr(request, "command_id", None))
    except LookupError as exc:
        raise HTTPException(status_code=404, detail="run not found") from exc
    except OwnershipConflict as exc:
        raise HTTPException(status_code=409, detail="decision identity conflict") from exc
    except Exception as exc:
        raise HTTPException(status_code=503, detail="resume command was not persisted") from exc
    return {"resumed": True, "queued": True}


@app.get("/runs/{run_id}")
async def run_status(run_id: str, authorization: str | None = Header(default=None)) -> dict:
    _check_auth(authorization)
    try:
        saved = await (await get_store()).get_run(run_id)
    except Exception as exc:
        raise HTTPException(status_code=503, detail="run status unavailable") from exc
    if saved is not None:
        state = runtime_dispatch.locally_owned_state(run_id, saved)
        if state is not None:
            return state.model_dump(mode="json")
        return {key: saved.get(key) for key in ("run_id", "status", "error", "output")}
    # Direct, in-process dev executions may predate durable admission.
    state = runner.get_run(run_id)
    if state is not None:
        return state.model_dump(mode="json")
    raise HTTPException(status_code=404, detail="run not found")


@app.post("/webhooks/openai/agents", status_code=202)
async def openai_agents_webhook(request: Request) -> dict:
    """Verify the original signed body before resolving durable ownership."""
    from openai import InvalidWebhookSignatureError, OpenAI

    settings = get_settings()
    secret = getattr(settings, "openai_agents_webhook_secret", "")
    if not getattr(settings, "openai_agents_enabled", False) or not secret:
        raise HTTPException(status_code=503, detail="agents webhook is not configured")
    chunks = bytearray()
    async for chunk in request.stream():
        chunks.extend(chunk)
        if len(chunks) > 1024 * 1024:
            raise HTTPException(status_code=413, detail="webhook payload too large")
    try:
        # Signature verification is local; constructing this SDK client never
        # sends an API request and does not require a billable API operation.
        with OpenAI(api_key=settings.openai_api_key or "webhook-verification") as client:
            client.webhooks.unwrap(bytes(chunks), request.headers, secret=secret)
        payload = json.loads(chunks)
    except InvalidWebhookSignatureError as exc:
        raise HTTPException(status_code=400, detail="invalid webhook signature") from exc
    except (ValueError, TypeError) as exc:
        raise HTTPException(status_code=400, detail="invalid webhook payload") from exc
    if not isinstance(payload, dict):
        raise HTTPException(status_code=400, detail="invalid webhook envelope")
    event_id, event_type = payload.get("id"), payload.get("type")
    data = payload.get("data")
    if not isinstance(event_id, str) or not event_id or not isinstance(event_type, str) or not isinstance(data, dict):
        raise HTTPException(status_code=400, detail="incomplete webhook envelope")
    session_id = data.get("session_id")
    if not session_id and isinstance(data.get("session"), dict):
        session_id = data["session"].get("id")
    if not session_id and event_type.startswith(("agent.session.", "agents.session.")):
        session_id = data.get("id")
    if not isinstance(session_id, str) or not session_id:
        # Non-agent events are unrelated; do not infer ownership from metadata.
        return {"accepted": False, "reason": "no agent session"}
    try:
        store = await get_store(require_durable=True)
        inserted = await store.record_event(event_id, session_id, event_type, payload)
    except UnknownSession as exc:
        # The provider may deliver faster than its create response is persisted.
        # A retry can resolve that race; never bind using untrusted run metadata.
        raise HTTPException(status_code=503, detail="session ownership is not yet registered") from exc
    except OwnershipConflict as exc:
        raise HTTPException(status_code=409, detail="event identity conflict") from exc
    except Exception as exc:
        raise HTTPException(status_code=503, detail="webhook event was not persisted") from exc
    return {"accepted": True, "duplicate": not inserted}


@app.post("/ingest")
async def ingest(
    payload: dict,
    authorization: str | None = Header(default=None),
) -> dict:
    _check_auth(authorization)
    return await ingest_document(payload)


@app.post("/mail/sync", status_code=202)
async def mail_sync_endpoint(
    payload: dict,
    authorization: str | None = Header(default=None),
) -> dict:
    """Sync one mailbox (HTTP dispatch mode). Runs in the background so
    Phoenix's Oban job returns immediately."""
    _check_auth(authorization)

    from app.mail import sync as mail_sync

    task = asyncio.ensure_future(mail_sync.sync_account(payload))
    _background_runs.add(task)
    task.add_done_callback(_background_runs.discard)
    return {"accepted": True}


@app.post("/mail/watch", status_code=202)
async def mail_watch_endpoint(
    payload: dict,
    authorization: str | None = Header(default=None),
) -> dict:
    """Create/renew a mailbox push channel (Gmail watch / Graph subscription)."""
    _check_auth(authorization)

    from app.mail import sync as mail_sync

    task = asyncio.ensure_future(mail_sync.renew_watch(payload))
    _background_runs.add(task)
    task.add_done_callback(_background_runs.discard)
    return {"accepted": True}


@app.post("/mail/send")
async def mail_send_endpoint(
    payload: dict,
    authorization: str | None = Header(default=None),
) -> dict:
    """Return the provider outcome to the API's durable, idempotent outbox."""
    _check_auth(authorization)
    from app.mail import outbound

    return await outbound.send(payload.get("account", {}), payload.get("message", {}))


@app.post("/mail/message/action")
async def mail_message_action_endpoint(
    payload: dict,
    authorization: str | None = Header(default=None),
) -> dict:
    _check_auth(authorization)
    from app.mail import operations

    return await operations.message_action(payload)


@app.post("/mail/attachment")
async def mail_attachment_endpoint(
    payload: dict,
    authorization: str | None = Header(default=None),
) -> dict:
    _check_auth(authorization)
    from app.mail import operations

    return await operations.download_attachment(payload)


@app.post("/mail/message/detail")
async def mail_message_detail_endpoint(
    payload: dict,
    authorization: str | None = Header(default=None),
) -> dict:
    _check_auth(authorization)
    from app.mail import operations

    return await operations.hydrate_message(payload)
