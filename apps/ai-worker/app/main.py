import asyncio
from contextlib import asynccontextmanager

import structlog
from fastapi import FastAPI, Header, HTTPException

from app.agents import runner
from app.config import get_settings
from app.memory.ingestion import ingest_document
from app.queue.consumer import consume_forever
from app.schemas import ResumeRequest, RunRequest
from app.tools.registry import list_tools

log = structlog.get_logger()


@asynccontextmanager
async def lifespan(_app: FastAPI):
    consumer: asyncio.Task | None = None
    if get_settings().ai_runs_queue_url:
        consumer = asyncio.create_task(consume_forever())
    yield
    if consumer:
        consumer.cancel()


app = FastAPI(title="mokaid AI worker", version="0.1.0", lifespan=lifespan)

# Strong references to in-flight runs so the event loop never GCs them.
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

    log.info("run_accepted", run_id=request.run_id)
    return {"accepted": True, "run_id": request.run_id}


@app.post("/runs/{run_id}/resume")
async def resume(
    run_id: str,
    request: ResumeRequest,
    authorization: str | None = Header(default=None),
) -> dict:
    _check_auth(authorization)

    if request.run_id != run_id:
        raise HTTPException(status_code=400, detail="run_id mismatch")
    if not runner.resume_run(request):
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
