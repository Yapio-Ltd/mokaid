import asyncio
import os
from contextlib import asynccontextmanager

import structlog
from fastapi import FastAPI, Header, HTTPException

import app.tools.files  # noqa: F401 — registers file-processing tools
import app.tools.site_delivery  # noqa: F401 — HTML vs codebase choice gate
import app.tools.web  # noqa: F401 — registers web_search
import app.tools.webapp  # noqa: F401 — registers Next/React webapp scaffold tool
import app.tools.website  # noqa: F401 — registers the website generator tool
from app.agents import converse as converse_agent
from app.agents import direct_chat, dispatcher, runner, schedule_parser
from app.config import get_settings
from app.memory.ingestion import ingest_document
from app.queue.consumer import consume_forever
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
    consumer: asyncio.Task | None = None
    if get_settings().ai_runs_queue_url:
        consumer = asyncio.create_task(consume_forever())
    yield
    if consumer:
        consumer.cancel()


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

    if runner.get_run(request.run_id) is not None:
        raise HTTPException(status_code=409, detail="run already exists")

    # Runs can pause for human approval, so they execute as independent
    # asyncio tasks created on the running loop (BackgroundTasks would run
    # in a threadpool without an event loop).
    task = asyncio.create_task(runner.execute_run(request))
    _background_runs.add(task)
    task.add_done_callback(_background_runs.discard)
    runner.register_run_task(request.run_id, task)

    log.info("run_accepted", run_id=request.run_id)
    return {"accepted": True, "run_id": request.run_id}


@app.post("/runs/{run_id}/cancel")
async def cancel_run(
    run_id: str,
    authorization: str | None = Header(default=None),
) -> dict:
    """Aborts an in-flight run (including one paused for approval)."""
    _check_auth(authorization)

    if not runner.cancel_run_task(run_id):
        # Nothing running here (already finished, or worker restarted) —
        # cancellation is idempotent from the caller's point of view.
        return {"canceled": False, "reason": "run not in flight"}

    log.info("run_cancel_requested", run_id=run_id)
    return {"canceled": True}


@app.post("/converse")
async def converse(
    payload: dict,
    authorization: str | None = Header(default=None),
) -> dict:
    """Chat reply in a task thread while the agent is idle. The reply is
    posted back as a task comment by the worker itself."""
    _check_auth(authorization)

    task = asyncio.create_task(converse_agent.converse(payload))
    _background_runs.add(task)
    task.add_done_callback(_background_runs.discard)
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
    except Exception as exc:  # noqa: BLE001 — Phoenix falls back on any error
        log.warning("dispatch_analyze_failed", error=str(exc))
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
    if not await runner.resume_run(request):
        raise HTTPException(status_code=404, detail="no run waiting for a decision")
    return {"resumed": True}


@app.get("/runs/{run_id}")
async def run_status(run_id: str, authorization: str | None = Header(default=None)) -> dict:
    _check_auth(authorization)

    state = runner.get_run(run_id)
    if state is None:
        raise HTTPException(status_code=404, detail="run not found")
    return state.model_dump(mode="json")


@app.post("/ingest")
async def ingest(
    payload: dict,
    authorization: str | None = Header(default=None),
) -> dict:
    _check_auth(authorization)
    return await ingest_document(payload)
