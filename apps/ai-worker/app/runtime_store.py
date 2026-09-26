"""Durable runtime ownership, execution metadata and exactly-once journals.

The PostgreSQL store is mandatory for enabled managed agents. MemoryStore is
an explicit test/development implementation, never a database-outage fallback.
JSON execution patches are merged under a row lock. External effects already
marked executing are ambiguous after a crash and must be reconciled, not rerun.
"""

from __future__ import annotations

import asyncio
import hashlib
import json
import time
from collections.abc import Callable
from copy import deepcopy
from typing import Any

from app import persistence
from app.config import get_settings

TERMINAL = frozenset({"completed", "failed", "canceled"})


class StoreUnavailable(RuntimeError):
    pass


class OwnershipConflict(ValueError):
    pass


class UnknownSession(LookupError):
    pass


def _hash(value: Any) -> str:
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False, allow_nan=False).encode()).hexdigest()


def _new_run(payload: dict[str, Any]) -> dict[str, Any]:
    payload = deepcopy(payload)
    payload.setdefault("input", {}).pop("_worker_recovery_stop", None)
    return {
        "run_id": payload["run_id"], "workspace_id": payload["workspace_id"],
        "task_id": payload["task_id"], "payload": payload,
        "status": "accepted", "owner": None, "lease_until": 0,
        "attempt": 0, "cancel_requested": False, "commands": {},
        "executions": {}, "operations": {}, "updated_at": time.time(),
        "completed_at": None,
    }


class RuntimeStore:
    durable = False

    async def _mutate(self, run_id: str, mutate: Callable[[dict[str, Any]], Any]) -> Any:
        raise NotImplementedError

    async def accept_run(self, payload: dict[str, Any]) -> bool:
        raise NotImplementedError

    async def get_run(self, run_id: str) -> dict[str, Any] | None:
        raise NotImplementedError

    async def _candidates(self, limit: int) -> list[str]:
        raise NotImplementedError

    async def claim_runs(self, owner: str, limit: int = 4, lease_seconds: int = 60) -> list[dict[str, Any]]:
        if limit <= 0:
            return []
        claimed = []
        for run_id in await self._candidates(max(limit * 4, 20)):
            def claim(row: dict[str, Any]) -> dict[str, Any] | None:
                pending_resume = any(c["kind"] == "resume" and not c.get("consumed_at") for c in row["commands"].values())
                eligible = row["status"] in {"accepted", "running"} or (
                    row["status"] in {"waiting_for_approval", "waiting_for_user_input"}
                    and (pending_resume or row["cancel_requested"])
                )
                if not eligible or row["lease_until"] > time.time() or row.get("cleanup_until", 0) > time.time():
                    return None
                row.update(owner=owner, lease_until=time.time() + lease_seconds,
                           status="running", attempt=row["attempt"] + 1)
                return deepcopy(row)

            record = await self._mutate(run_id, claim)
            if record:
                claimed.append(record)
            if len(claimed) >= limit:
                break
        return claimed

    async def renew_lease(self, run_id: str, owner: str, lease_seconds: int = 60) -> bool:
        def renew(row: dict[str, Any]) -> bool:
            if row["owner"] != owner or row["lease_until"] <= time.time() or row["status"] in TERMINAL:
                return False
            row["lease_until"] = time.time() + lease_seconds
            return True
        return await self._mutate(run_id, renew)

    async def finish_run(self, run_id: str, owner: str, status: str, *, error: str | None = None, output: Any = None) -> bool:
        if status not in TERMINAL | {"waiting_for_approval", "waiting_for_user_input"}:
            raise ValueError("Invalid final worker status")
        def finish(row: dict[str, Any]) -> bool:
            if row["owner"] != owner or row["lease_until"] <= time.time():
                return False
            row.update(status=status, owner=None, lease_until=0, error=error, output=output)
            if status in TERMINAL:
                row["completed_at"] = time.time()
            else:
                row["paused_at"] = time.time()
            return True
        return await self._mutate(run_id, finish)

    async def release_run(self, run_id: str, owner: str) -> bool:
        def release(row: dict[str, Any]) -> bool:
            if row["owner"] != owner or row["status"] in TERMINAL:
                return False
            row.update(owner=None, lease_until=0, status="accepted")
            return True
        return await self._mutate(run_id, release)

    async def enqueue_command(self, run_id: str, kind: str, payload: dict[str, Any] | None = None, command_id: str | None = None) -> bool:
        if kind not in {"cancel", "resume"}:
            raise ValueError("Unknown worker command")
        payload = deepcopy(payload or {})
        # Callers should supply the approval-request ID for repeated approvals
        # of the same tool. Without an ID, identical deliveries fail closed.
        command_id = command_id or _hash([run_id, kind, payload])
        def enqueue(row: dict[str, Any]) -> bool:
            if row["status"] in TERMINAL:
                return False
            if kind == "resume" and row.get("cleanup_until", 0) > time.time():
                raise OwnershipConflict("Execution retention is already in progress")
            existing = row["commands"].get(command_id)
            if existing:
                if existing["kind"] != kind or existing["payload"] != payload:
                    raise OwnershipConflict("Command ID already has different content")
                return False
            row["commands"][command_id] = {"id": command_id, "kind": kind, "payload": payload, "created_at": time.time()}
            if kind == "cancel":
                row["cancel_requested"] = True
            return True
        return await self._mutate(run_id, enqueue)

    async def pending_commands(self, run_id: str, owner: str) -> list[dict[str, Any]]:
        row = await self.get_run(run_id)
        if not row or row["owner"] != owner or row["lease_until"] <= time.time():
            return []
        return [command for command in row["commands"].values() if not command.get("consumed_at")]

    async def ack_command(self, run_id: str, command_id: str, owner: str) -> bool:
        def ack(row: dict[str, Any]) -> bool:
            if row["owner"] != owner or row["lease_until"] <= time.time():
                return False
            command = row["commands"].get(command_id)
            if not command:
                return False
            command["consumed_at"] = time.time()
            return True
        return await self._mutate(run_id, ack)

    async def is_cancelled(self, run_id: str) -> bool:
        row = await self.get_run(run_id)
        return bool(row and row["cancel_requested"])

    async def save_execution(self, run_id: str, participant_id: str = "", **patch: Any) -> dict[str, Any]:
        """Atomic shallow patch; independent fields cannot overwrite each other."""
        session_id = patch.get("session_id")
        if session_id:
            # Establish immutable ownership before callbacks may use the session.
            await self._bind_session(str(session_id), run_id, participant_id)
        def save(row: dict[str, Any]) -> dict[str, Any]:
            execution = row["executions"].setdefault(participant_id, {})
            execution.update(deepcopy(patch))
            return deepcopy(execution)
        return await self._mutate(run_id, save)

    async def get_execution(self, run_id: str, participant_id: str = "") -> dict[str, Any] | None:
        row = await self.get_run(run_id)
        return deepcopy(row["executions"].get(participant_id)) if row else None

    async def _bind_session(self, session_id: str, run_id: str, participant_id: str) -> None:
        raise NotImplementedError

    async def find_session(self, session_id: str) -> dict[str, Any] | None:
        raise NotImplementedError

    async def list_sessions(self, run_id: str) -> list[dict[str, Any]]:
        raise NotImplementedError

    async def begin_operation(self, run_id: str, tool: str, tool_input: Any, participant_id: str = "") -> dict[str, Any]:
        # Participants and rotated provider sessions share the mission's journal.
        key = _hash([run_id, tool, tool_input])
        def begin(row: dict[str, Any]) -> dict[str, Any]:
            operations = row["operations"]
            if key in operations:
                return {**deepcopy(operations[key]), "execute": False}
            item = {"key": key, "status": "executing", "tool": tool,
                    "participant_id": participant_id, "created_at": time.time(), "result": None}
            operations[key] = item
            return {**deepcopy(item), "execute": True}
        return await self._mutate(run_id, begin)

    async def finish_operation(self, run_id: str, key: str, status: str, result: Any) -> None:
        if status not in {"pending", "approved", "executing", "succeeded", "failed", "uncertain", "ambiguous"}:
            raise ValueError("Invalid operation status")
        def finish(row: dict[str, Any]) -> None:
            operation = row["operations"].get(key)
            if operation is None:
                raise LookupError("Unknown operation")
            if operation["status"] == "succeeded":
                if status != "succeeded" or operation["result"] != result:
                    raise OwnershipConflict("Completed operation is immutable")
                return
            operation.update(status=status, result=deepcopy(result), completed_at=time.time())
        await self._mutate(run_id, finish)

    async def record_event(self, event_id: str, session_id: str, event_type: str, payload: dict[str, Any]) -> bool:
        raise NotImplementedError

    async def list_events(self, run_id: str, after_sequence: int = 0, *, participant_id: str | None = None, limit: int = 100) -> list[dict[str, Any]]:
        raise NotImplementedError

    async def expired_sessions(self, retention_days: int = 7) -> list[dict[str, Any]]:
        raise NotImplementedError

    async def claim_cleanup(self, run_id: str, owner: str, lease_seconds: int = 300) -> bool:
        """Serialize retention across replicas and fence resumed executions."""
        def claim(row: dict[str, Any]) -> bool:
            if (row["status"] not in TERMINAL | {"waiting_for_approval", "waiting_for_user_input"}
                    or row["lease_until"] > time.time() or row.get("cleanup_until", 0) > time.time()):
                return False
            if row["status"] not in TERMINAL and any(
                command["kind"] == "resume" and not command.get("consumed_at") for command in row["commands"].values()
            ):
                return False
            row.update(cleanup_owner=owner, cleanup_until=time.time() + lease_seconds)
            return True
        return await self._mutate(run_id, claim)

    async def release_cleanup(self, run_id: str, owner: str) -> None:
        def release(row: dict[str, Any]) -> None:
            if row.get("cleanup_owner") == owner:
                row.update(cleanup_owner=None, cleanup_until=0)
        await self._mutate(run_id, release)

    async def finish_cleanup(self, run_id: str, owner: str, status: str, output: Any) -> None:
        if status not in TERMINAL:
            raise ValueError("Retention can only finalize terminal executions")
        def finish(row: dict[str, Any]) -> None:
            if row.get("cleanup_owner") != owner or row.get("cleanup_until", 0) <= time.time():
                raise OwnershipConflict("Retention lease lost")
            row.update(status=status, output=deepcopy(output), owner=None, lease_until=0,
                       completed_at=row.get("completed_at") or row.get("paused_at") or time.time())
        await self._mutate(run_id, finish)

    async def save_session_snapshot(self, run_id: str, session_id: str, **patch: Any) -> dict[str, Any]:
        """Keep usage/evidence for rotated sessions without replacing the active ID."""
        binding = await self.find_session(session_id)
        if not binding or binding["run_id"] != run_id:
            raise OwnershipConflict("Session snapshot belongs to another execution")
        def save(row: dict[str, Any]) -> dict[str, Any]:
            snapshot = row.setdefault("retention_sessions", {}).setdefault(session_id, {})
            snapshot.update(deepcopy(patch))
            return deepcopy(snapshot)
        return await self._mutate(run_id, save)

    async def mark_session_deleted(self, session_id: str) -> None:
        raise NotImplementedError

    async def cleanup(self, retention_days: int = 7) -> int:
        raise NotImplementedError


class MemoryStore(RuntimeStore):
    """Explicit local implementation with the same atomicity contract as SQL."""
    def __init__(self) -> None:
        self.rows: dict[str, dict[str, Any]] = {}
        self.sessions: dict[str, dict[str, Any]] = {}
        self.events: dict[str, dict[str, Any]] = {}
        self.sequence = 0
        self.lock = asyncio.Lock()

    async def accept_run(self, payload: dict[str, Any]) -> bool:
        async with self.lock:
            row = self.rows.get(payload["run_id"])
            if row:
                _check_owner(row, payload)
                return False
            self.rows[payload["run_id"]] = _new_run(payload)
            return True

    async def get_run(self, run_id: str) -> dict[str, Any] | None:
        async with self.lock:
            return deepcopy(self.rows.get(run_id))

    async def _mutate(self, run_id: str, mutate: Callable[[dict[str, Any]], Any]) -> Any:
        async with self.lock:
            if run_id not in self.rows:
                raise LookupError("Unknown worker run")
            row = deepcopy(self.rows[run_id])
            result = mutate(row)
            row["updated_at"] = time.time()
            self.rows[run_id] = row
            return result

    async def _candidates(self, limit: int) -> list[str]:
        async with self.lock:
            ordered = sorted(self.rows.values(), key=lambda row: row["updated_at"])
            return [row["run_id"] for row in ordered if row["status"] not in TERMINAL and row["lease_until"] <= time.time()][:limit]

    async def _bind_session(self, session_id: str, run_id: str, participant_id: str) -> None:
        async with self.lock:
            row = self.rows.get(run_id)
            if not row:
                raise LookupError("Unknown worker run")
            existing = self.sessions.get(session_id)
            if existing and (existing["run_id"], existing["participant_id"]) != (run_id, participant_id):
                raise OwnershipConflict("Provider session belongs to another execution")
            self.sessions.setdefault(session_id, {"session_id": session_id, "run_id": run_id,
                                    "workspace_id": row["workspace_id"], "participant_id": participant_id, "deleted_at": None})

    async def find_session(self, session_id: str) -> dict[str, Any] | None:
        async with self.lock:
            return deepcopy(self.sessions.get(session_id))

    async def list_sessions(self, run_id: str) -> list[dict[str, Any]]:
        async with self.lock:
            return deepcopy([item for item in self.sessions.values() if item["run_id"] == run_id])

    async def record_event(self, event_id: str, session_id: str, event_type: str, payload: dict[str, Any]) -> bool:
        async with self.lock:
            session = self.sessions.get(session_id)
            if not session:
                raise UnknownSession("Unrecognized provider session")
            if event_id in self.events:
                if self.events[event_id]["session_id"] != session_id:
                    raise OwnershipConflict("Event ID belongs to another session")
                return False
            self.sequence += 1
            self.events[event_id] = {**deepcopy(session), "id": event_id, "sequence": self.sequence,
                                     "type": event_type, "payload": deepcopy(payload)}
            return True

    async def list_events(self, run_id: str, after_sequence: int = 0, *, participant_id: str | None = None, limit: int = 100) -> list[dict[str, Any]]:
        async with self.lock:
            return deepcopy([event for event in self.events.values() if event["run_id"] == run_id
                             and event["sequence"] > after_sequence
                             and (participant_id is None or event["participant_id"] == participant_id)][:max(1, min(limit, 1000))])

    async def expired_sessions(self, retention_days: int = 7) -> list[dict[str, Any]]:
        cutoff = time.time() - max(7, retention_days) * 86400
        async with self.lock:
            return deepcopy([s for s in self.sessions.values() if not s["deleted_at"]
                             and _retention_time(self.rows[s["run_id"]]) < cutoff
                             and self.rows[s["run_id"]]["lease_until"] <= time.time()])

    async def mark_session_deleted(self, session_id: str) -> None:
        async with self.lock:
            self.sessions[session_id]["deleted_at"] = time.time()

    async def cleanup(self, retention_days: int = 7) -> int:
        cutoff = time.time() - max(7, retention_days) * 86400
        async with self.lock:
            expired = {key for key, row in self.rows.items() if (row.get("completed_at") or float("inf")) < cutoff
                       and not _pending_delivery(row) and row.get("cleanup_until", 0) <= time.time()
                       and not any(s["run_id"] == key and not s["deleted_at"] for s in self.sessions.values())}
            for key in expired:
                del self.rows[key]
            self.sessions = {key: s for key, s in self.sessions.items() if s["run_id"] not in expired}
            self.events = {key: e for key, e in self.events.items() if e["run_id"] not in expired}
            return len(expired)


def _check_owner(row: dict[str, Any], payload: dict[str, Any]) -> None:
    if any(row.get(key) != payload.get(key) for key in ("workspace_id", "task_id")) or row["payload"].get("agent_id") != payload.get("agent_id"):
        raise OwnershipConflict("Run ID belongs to another task or principal")


def _retention_time(row: dict[str, Any]) -> float:
    if row["status"] in TERMINAL:
        return row.get("completed_at") or float("inf")
    if row["status"] in {"waiting_for_approval", "waiting_for_user_input"}:
        return row.get("paused_at") or float("inf")
    return float("inf")


def _pending_delivery(row: dict[str, Any]) -> bool:
    root = row.get("executions", {}).get("", {})
    return bool(root.get("delivery_pending") or root.get("settlement_pending"))


_DDL = [
    """CREATE TABLE IF NOT EXISTS worker_runtime_runs (
        run_id TEXT PRIMARY KEY, workspace_id TEXT NOT NULL, task_id TEXT NOT NULL,
        data JSONB NOT NULL, status TEXT NOT NULL, lease_until DOUBLE PRECISION NOT NULL DEFAULT 0,
        completed_at DOUBLE PRECISION, updated_at DOUBLE PRECISION NOT NULL)""",
    "CREATE INDEX IF NOT EXISTS worker_runtime_runs_poll ON worker_runtime_runs(status, lease_until)",
    """CREATE TABLE IF NOT EXISTS worker_runtime_sessions (
        session_id TEXT PRIMARY KEY, run_id TEXT NOT NULL REFERENCES worker_runtime_runs(run_id) ON DELETE CASCADE,
        participant_id TEXT NOT NULL DEFAULT '', deleted_at DOUBLE PRECISION)""",
    """CREATE TABLE IF NOT EXISTS worker_runtime_events (
        sequence BIGSERIAL UNIQUE, event_id TEXT PRIMARY KEY,
        session_id TEXT NOT NULL REFERENCES worker_runtime_sessions(session_id) ON DELETE CASCADE,
        event_type TEXT NOT NULL, payload JSONB NOT NULL)""",
]


class PostgresStore(RuntimeStore):
    durable = True

    def __init__(self, pool: Any) -> None:
        self.pool = pool

    async def initialize(self) -> None:
        async with self.pool.connection() as conn:
            async with conn.transaction():
                # Serialize bootstrap across replicas without holding leases.
                await conn.execute("SELECT pg_advisory_xact_lock(787653902)")
                for statement in _DDL:
                    await conn.execute(statement)

    async def accept_run(self, payload: dict[str, Any]) -> bool:
        row = _new_run(payload)
        async with self.pool.connection() as conn:
            cursor = await conn.execute(
                "INSERT INTO worker_runtime_runs(run_id, workspace_id, task_id, data, status, updated_at) VALUES (%s,%s,%s,%s::jsonb,%s,%s) ON CONFLICT (run_id) DO NOTHING RETURNING run_id",
                (row["run_id"], row["workspace_id"], row["task_id"], json.dumps(row), row["status"], row["updated_at"]),
            )
            inserted = await cursor.fetchone()
        if inserted:
            return True
        existing = await self.get_run(row["run_id"])
        if existing is None:
            raise StoreUnavailable("Concurrent run retention; retry acceptance")
        _check_owner(existing, payload)
        return False

    async def get_run(self, run_id: str) -> dict[str, Any] | None:
        async with self.pool.connection() as conn:
            cursor = await conn.execute("SELECT data FROM worker_runtime_runs WHERE run_id=%s", (run_id,))
            row = await cursor.fetchone()
            return row["data"] if row else None

    async def _mutate(self, run_id: str, mutate: Callable[[dict[str, Any]], Any]) -> Any:
        async with self.pool.connection() as conn:
            async with conn.transaction():
                cursor = await conn.execute("SELECT data FROM worker_runtime_runs WHERE run_id=%s FOR UPDATE", (run_id,))
                record = await cursor.fetchone()
                if record is None:
                    raise LookupError("Unknown worker run")
                row = record["data"]
                result = mutate(row)
                row["updated_at"] = time.time()
                await conn.execute("UPDATE worker_runtime_runs SET data=%s::jsonb,status=%s,lease_until=%s,completed_at=%s,updated_at=%s WHERE run_id=%s",
                                   (json.dumps(row), row["status"], row["lease_until"], row.get("completed_at"), row["updated_at"], run_id))
                return result

    async def _candidates(self, limit: int) -> list[str]:
        async with self.pool.connection() as conn:
            cursor = await conn.execute("SELECT run_id FROM worker_runtime_runs WHERE status NOT IN ('completed','failed','canceled') AND lease_until<=%s ORDER BY updated_at LIMIT %s", (time.time(), limit))
            return [row["run_id"] for row in await cursor.fetchall()]

    async def _bind_session(self, session_id: str, run_id: str, participant_id: str) -> None:
        async with self.pool.connection() as conn:
            await conn.execute("INSERT INTO worker_runtime_sessions(session_id,run_id,participant_id) VALUES (%s,%s,%s) ON CONFLICT (session_id) DO NOTHING", (session_id, run_id, participant_id))
        session = await self.find_session(session_id)
        if not session or (session["run_id"], session["participant_id"]) != (run_id, participant_id):
            raise OwnershipConflict("Provider session belongs to another execution")

    async def find_session(self, session_id: str) -> dict[str, Any] | None:
        async with self.pool.connection() as conn:
            cursor = await conn.execute("SELECT s.*,r.workspace_id FROM worker_runtime_sessions s JOIN worker_runtime_runs r USING(run_id) WHERE session_id=%s", (session_id,))
            return await cursor.fetchone()

    async def list_sessions(self, run_id: str) -> list[dict[str, Any]]:
        async with self.pool.connection() as conn:
            cursor = await conn.execute("SELECT s.*,r.workspace_id FROM worker_runtime_sessions s JOIN worker_runtime_runs r USING(run_id) WHERE s.run_id=%s", (run_id,))
            return await cursor.fetchall()

    async def record_event(self, event_id: str, session_id: str, event_type: str, payload: dict[str, Any]) -> bool:
        if not await self.find_session(session_id):
            raise UnknownSession("Unrecognized provider session")
        async with self.pool.connection() as conn:
            cursor = await conn.execute("INSERT INTO worker_runtime_events(event_id,session_id,event_type,payload) VALUES (%s,%s,%s,%s::jsonb) ON CONFLICT(event_id) DO NOTHING RETURNING event_id", (event_id, session_id, event_type, json.dumps(payload)))
            if await cursor.fetchone():
                return True
            cursor = await conn.execute("SELECT session_id FROM worker_runtime_events WHERE event_id=%s", (event_id,))
            existing = await cursor.fetchone()
            if existing and existing["session_id"] != session_id:
                raise OwnershipConflict("Event ID belongs to another session")
            return False

    async def list_events(self, run_id: str, after_sequence: int = 0, *, participant_id: str | None = None, limit: int = 100) -> list[dict[str, Any]]:
        async with self.pool.connection() as conn:
            cursor = await conn.execute("SELECT e.sequence,e.event_id AS id,e.session_id,e.event_type AS type,e.payload,s.run_id,s.participant_id,r.workspace_id FROM worker_runtime_events e JOIN worker_runtime_sessions s USING(session_id) JOIN worker_runtime_runs r USING(run_id) WHERE s.run_id=%s AND e.sequence>%s AND (%s::text IS NULL OR s.participant_id=%s) ORDER BY e.sequence LIMIT %s",
                                        (run_id, after_sequence, participant_id, participant_id, max(1, min(limit, 1000))))
            return await cursor.fetchall()

    async def expired_sessions(self, retention_days: int = 7) -> list[dict[str, Any]]:
        async with self.pool.connection() as conn:
            cursor = await conn.execute("""SELECT s.*,r.workspace_id FROM worker_runtime_sessions s
                JOIN worker_runtime_runs r USING(run_id) WHERE s.deleted_at IS NULL AND r.lease_until<=%s
                AND CASE WHEN r.status IN ('completed','failed','canceled') THEN r.completed_at
                    WHEN r.status IN ('waiting_for_approval','waiting_for_user_input')
                    THEN (r.data->>'paused_at')::double precision END < %s""",
                (time.time(), time.time() - max(7, retention_days) * 86400))
            return await cursor.fetchall()

    async def mark_session_deleted(self, session_id: str) -> None:
        async with self.pool.connection() as conn:
            await conn.execute("UPDATE worker_runtime_sessions SET deleted_at=%s WHERE session_id=%s", (time.time(), session_id))

    async def cleanup(self, retention_days: int = 7) -> int:
        async with self.pool.connection() as conn:
            cursor = await conn.execute("""DELETE FROM worker_runtime_runs r WHERE completed_at<%s
                AND COALESCE((data->>'cleanup_until')::double precision,0)<=%s
                AND COALESCE(data->'executions'->''->'delivery_pending', 'false'::jsonb) IN ('false'::jsonb,'null'::jsonb)
                AND COALESCE(data->'executions'->''->'settlement_pending', 'false'::jsonb) IN ('false'::jsonb,'null'::jsonb)
                AND NOT EXISTS(SELECT 1 FROM worker_runtime_sessions s WHERE s.run_id=r.run_id AND s.deleted_at IS NULL)
                RETURNING run_id""", (time.time() - max(7, retention_days) * 86400, time.time()))
            return len(await cursor.fetchall())


_store: RuntimeStore | None = None
_store_lock = asyncio.Lock()


async def get_store(*, require_durable: bool = False) -> RuntimeStore:
    global _store
    require_durable = require_durable or getattr(get_settings(), "openai_agents_enabled", False)
    async with _store_lock:
        if _store is None:
            if get_settings().database_url:
                try:
                    candidate = PostgresStore(await persistence.get_pool(required=True))
                    await candidate.initialize()
                except Exception as exc:
                    raise StoreUnavailable("Durable worker persistence is unavailable") from exc
                _store = candidate
            elif require_durable or getattr(get_settings(), "openai_agents_enabled", False):
                raise StoreUnavailable("Managed agents require DATABASE_URL")
            else:
                _store = MemoryStore()
        if require_durable and not _store.durable:
            raise StoreUnavailable("Managed agents require durable storage")
        return _store
