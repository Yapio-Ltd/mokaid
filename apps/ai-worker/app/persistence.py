"""Run persistence: LangGraph Postgres checkpointer + saved run requests.

When `DATABASE_URL` is configured, every deep-agent run checkpoints its graph
state in Postgres (thread_id = run_id) and the original RunRequest payload is
saved alongside. If the worker restarts while a run waits for a human
approval, the resume endpoint reloads the request, re-attaches to the
checkpointed thread and continues the mission instead of losing it.

Without a DATABASE_URL everything degrades to the previous in-memory
behavior (dev/tests still work with zero infrastructure).
"""

import asyncio
import json
from typing import Any

import structlog

from app.config import get_settings

log = structlog.get_logger()

_pool: Any = None
_checkpointer: Any = None
_init_lock = asyncio.Lock()

_RUN_REQUESTS_TABLE = """
CREATE TABLE IF NOT EXISTS worker_run_requests (
    run_id TEXT PRIMARY KEY,
    payload JSONB NOT NULL,
    inserted_at TIMESTAMPTZ NOT NULL DEFAULT now()
)
"""


def is_configured() -> bool:
    return bool(get_settings().database_url)


def _dsn() -> str:
    url = get_settings().database_url
    # Ecto-style DSNs ("ecto://user:pass@host/db") are close enough to
    # libpq's postgresql:// scheme to translate directly.
    if url.startswith("ecto://"):
        url = "postgresql://" + url[len("ecto://") :]
    return url


async def _ensure_initialized() -> bool:
    """Opens the pool, sets up checkpointer tables + our run-request table.
    Returns False (and logs) when persistence is unavailable."""
    global _pool, _checkpointer

    if not is_configured():
        return False
    if _checkpointer is not None:
        return True

    async with _init_lock:
        if _checkpointer is not None:
            return True
        pool = None
        try:
            from langgraph.checkpoint.postgres.aio import AsyncPostgresSaver
            from psycopg.rows import dict_row
            from psycopg_pool import AsyncConnectionPool

            pool = AsyncConnectionPool(
                _dsn(),
                min_size=1,
                max_size=4,
                open=False,
                kwargs={"autocommit": True, "row_factory": dict_row},
            )
            await pool.open()

            saver = AsyncPostgresSaver(pool)
            await saver.setup()

            async with pool.connection() as conn:
                await conn.execute(_RUN_REQUESTS_TABLE)

            _pool = pool
            _checkpointer = saver
            log.info("run_persistence_ready")
            return True
        except asyncio.CancelledError:
            if pool is not None:
                await pool.close()
            raise
        except Exception as exc:  # noqa: BLE001 — degrade to in-memory
            if pool is not None:
                await pool.close()
            log.warning("run_persistence_unavailable", error=type(exc).__name__)
            return False


async def get_checkpointer() -> Any | None:
    """The shared AsyncPostgresSaver, or None when persistence is off."""
    if not await _ensure_initialized():
        return None
    return _checkpointer


async def get_pool(*, required: bool = False) -> Any | None:
    """Share the worker pool; durable dispatch must fail closed on outages."""
    if not await _ensure_initialized():
        if required:
            raise RuntimeError("Durable worker persistence is unavailable")
        return None
    return _pool


async def save_run_request(run_id: str, payload: dict[str, Any]) -> None:
    if not await _ensure_initialized():
        return
    try:
        async with _pool.connection() as conn:
            await conn.execute(
                """
                INSERT INTO worker_run_requests (run_id, payload)
                VALUES (%s, %s::jsonb)
                ON CONFLICT (run_id) DO UPDATE SET payload = EXCLUDED.payload
                """,
                (run_id, json.dumps(payload)),
            )
    except Exception as exc:  # noqa: BLE001 — persistence is best-effort
        log.warning("run_request_save_failed", run_id=run_id, error=str(exc))


async def load_run_request(run_id: str) -> dict[str, Any] | None:
    if not await _ensure_initialized():
        return None
    try:
        async with _pool.connection() as conn:
            cursor = await conn.execute(
                "SELECT payload FROM worker_run_requests WHERE run_id = %s", (run_id,)
            )
            row = await cursor.fetchone()
            return row["payload"] if row else None
    except Exception as exc:  # noqa: BLE001
        log.warning("run_request_load_failed", run_id=run_id, error=str(exc))
        return None


async def save_team_state(run_id: str, snapshot: dict[str, Any]) -> None:
    """Update only the team's private resume state, preserving the run input.

    The original RunRequest is already saved before execution. A partial JSON
    update prevents concurrent notebook writes from reverting other input data.
    """
    if not await _ensure_initialized():
        return
    try:
        async with _pool.connection() as conn:
            await conn.execute(
                """
                UPDATE worker_run_requests
                SET payload = jsonb_set(
                    payload, '{input}',
                    COALESCE(payload->'input', '{}'::jsonb)
                        || jsonb_build_object('_team_state', %s::jsonb)
                )
                WHERE run_id = %s
                """,
                (json.dumps(snapshot), run_id),
            )
    except Exception as exc:  # noqa: BLE001 — persistence is best-effort
        log.warning("team_state_save_failed", run_id=run_id, error=type(exc).__name__)


async def delete_run_request(run_id: str) -> None:
    if _checkpointer is None:
        return
    try:
        async with _pool.connection() as conn:
            await conn.execute("DELETE FROM worker_run_requests WHERE run_id = %s", (run_id,))
    except Exception as exc:  # noqa: BLE001
        log.warning("run_request_delete_failed", run_id=run_id, error=str(exc))
