"""Recover published files and accounting before expiring managed sessions.

Retention never starts a model turn or invokes an agent-selected function.
Only already-published outputs are imported, under their recorded principal.
Unknown provider usage keeps the billing reservation pending in Phoenix.
"""

from __future__ import annotations

import asyncio
import math
import time
import uuid
from copy import deepcopy
from types import SimpleNamespace
from typing import Any

import structlog
from openai import NotFoundError

from app.agents.managed_runner import ManagedEngine
from app.agents.openai_runtime import OpenAIAgentsAdapter
from app.agents.runtime import RuntimeResult
from app.agents.runtime_cancellation import cancel_and_confirm
from app.agents.runtime_cost import PRICING_VERSION, MissionBudget, estimate_cents
from app.clients.phoenix import PhoenixClient
from app.runtime_store import TERMINAL, RuntimeStore
from app.schemas import RunRequest, ToolCall

log = structlog.get_logger()


class _RetentionEngine(ManagedEngine):
    """Use the normal artifact validation/import path without replacing IDs."""

    async def checkpoint(self, **patch: Any) -> None:
        patch.update(model=self.model, result=self.result.to_dict(),
                     active_seconds=self.active_seconds,
                     tool_cost_cents=self.record.get("tool_cost_cents", 0),
                     tool_calls=[call.model_dump(mode="json") for call in self.tool_calls])
        self.record = await self.mission.store.save_session_snapshot(
            self.request.run_id, self.session_id, **patch
        )
        current = await self.mission.store.get_execution(self.request.run_id, self.participant) or {}
        if current.get("session_id") == self.session_id:
            await self.mission.store.save_execution(self.request.run_id, self.participant, **patch)


def _engine(mission: Any, request: RunRequest, binding: dict[str, Any], row: dict[str, Any]) -> _RetentionEngine:
    participant = binding["participant_id"]
    if participant:
        colleague = next((colleague for colleague in request.colleagues if colleague.id == participant), None)
        if colleague is None:
            raise ValueError("Stored participant identity is unavailable")
        request = request.model_copy(update={"agent_id": colleague.id, "agent": colleague.agent})
    engine = _RetentionEngine(mission, request, participant)
    engine.session_id = binding["session_id"]
    current = row["executions"].get(participant, {})
    saved = row.get("retention_sessions", {}).get(engine.session_id)
    if saved is None:
        saved = current if current.get("session_id") == engine.session_id else next(
            (old for old in current.get("archived_sessions", []) if old["session_id"] == engine.session_id), {}
        )
    engine.record = deepcopy(saved)
    engine.model = saved.get("model", "")
    engine.active_seconds = saved.get("active_seconds", 0)
    engine.result = RuntimeResult(**saved.get("result", {}))
    engine.tool_calls = [ToolCall.model_validate(call) for call in saved.get("tool_calls", [])]
    return engine


def _cost(row: dict[str, Any], bindings: list[dict[str, Any]]) -> int | None:
    snapshots = {record["session_id"]: record for record in row["executions"].values() if record.get("session_id")}
    for record in row["executions"].values():
        snapshots.update({old["session_id"]: old for old in record.get("archived_sessions", [])})
    snapshots.update(row.get("retention_sessions", {}))
    usage = [estimate_cents(snapshots.get(binding["session_id"], {}).get("model", ""),
                            snapshots.get(binding["session_id"], {}).get("usage")) for binding in bindings]
    if not usage or any(value is None for value in usage):
        return None
    tools = [record.get("tool_cost_cents", 0) for record in row["executions"].values()]
    if any(not isinstance(value, (int, float)) or isinstance(value, bool) or
           not math.isfinite(value) or value < 0 for value in tools):
        return None
    sandbox = sum(3 * (len(record.get("archived_sessions", [])) + max(1, math.ceil(record.get("active_seconds", 0) / 1200)))
                  for record in row["executions"].values() if (record.get("requirements") or {}).get("sandbox"))
    return math.ceil(sum(usage) + sum(tools) + sandbox)


def _delivery(row: dict[str, Any], engines: list[_RetentionEngine], cost: int | None) -> dict[str, Any]:
    root = row["executions"].get("", {})
    pending = root.get("delivery_pending")
    pending = pending if isinstance(pending, dict) else {}
    output = deepcopy(pending.get("output") or row.get("output") or {})
    if not output.get("summary"):
        output["summary"] = root.get("result", {}).get("summary", "")
    runtime = output.setdefault("runtime", {})
    runtime["engine"] = "openai_agents"
    manifest = {item["id"]: item for item in runtime.get("manifest", [])}
    for record in row["executions"].values():
        manifest.update({item["id"]: item for item in record.get("result", {}).get("artifacts", [])})
    for engine in engines:
        manifest.update({item["id"]: item for item in engine.result.artifacts})
    runtime["manifest"] = list(manifest.values())
    runtime["retention"] = {"expired": True, "usage_status": "estimated" if cost is not None else "unknown"}
    status = pending.get("status") or row["status"]
    if status not in TERMINAL:
        status = "canceled"
        runtime.setdefault("limitations", []).append("The execution expired after seven days. Published files were preserved.")
    runtime["status"] = status
    output["artifacts"] = list(dict.fromkeys(item["filename"] for item in manifest.values()))
    return {"status": status, "output": output, "cost_cents": cost or 0}


async def _cleanup_run(store: RuntimeStore, owner: str, row: dict[str, Any],
                       bindings: list[dict[str, Any]], adapter: Any, phoenix: Any) -> None:
    requested = {binding["session_id"] for binding in bindings}
    bindings = [binding for binding in await store.list_sessions(row["run_id"])
                if binding["session_id"] in requested and not binding.get("deleted_at")]
    if not bindings:
        return
    request = RunRequest.model_validate(row["payload"])
    mission = SimpleNamespace(store=store, adapter=adapter, phoenix=phoenix, budget=MissionBudget(0, 0))
    engines = [_engine(mission, request, binding, row) for binding in bindings]
    for engine in engines:
        try:
            if engine.record.get("retention_imported"):
                # Recognize a deletion whose ACK was lost without treating an
                # unobserved missing session as proof of successful delivery.
                await adapter.retrieve(engine.session_id)
            await cancel_and_confirm(adapter, engine.session_id, observe=engine.observe)
            await engine.import_artifacts()
            await engine.checkpoint(retention_imported=True, retained_at=time.time())
        except NotFoundError:
            # A delete response may be lost after all evidence was committed.
            # Missing sessions without that checkpoint are never called delivered.
            if not engine.record.get("retention_imported"):
                raise

    current = await store.get_run(request.run_id)
    if current is None:
        raise LookupError("Runtime disappeared during retention")
    cost = _cost(current, await store.list_sessions(request.run_id))
    receipt = await phoenix.runtime_call(request.run_id, request.workspace_id, "settle",
                                         cost_cents=cost, usage_status="estimated" if cost is not None else "unknown",
                                         terminal_status=current["status"] if current["status"] in TERMINAL else "canceled")
    if receipt.get("status") not in {"settled", "pending_usage"}:
        raise RuntimeError("Retention accounting was not acknowledged")
    await store.save_execution(request.run_id, settlement=receipt, pricing_version=PRICING_VERSION,
                               settlement_pending=receipt["status"] != "settled")
    delivery = _delivery(current, engines, cost)
    await store.save_execution(request.run_id, delivery_pending=delivery)
    await phoenix.finalize_runtime(request.run_id, **delivery)
    await store.save_execution(request.run_id, delivery_pending=False, retention_delivered=True)
    await store.finish_cleanup(request.run_id, owner, delivery["status"], delivery["output"])
    for engine in engines:
        try:
            await adapter.delete(engine.session_id)
        except NotFoundError:
            pass
        await store.mark_session_deleted(engine.session_id)


async def cleanup_sessions(store: RuntimeStore, *, adapter: Any = None, phoenix: Any = None) -> None:
    """Periodic callback; no client or provider call when nothing has expired."""
    expired = await store.expired_sessions(7)
    if not expired:
        return
    own_adapter = adapter is None
    adapter = adapter or OpenAIAgentsAdapter()
    phoenix = phoenix or PhoenixClient()
    groups: dict[str, list[dict[str, Any]]] = {}
    for binding in expired:
        groups.setdefault(binding["run_id"], []).append(binding)
    try:
        for run_id, bindings in groups.items():
            owner = "retention:" + uuid.uuid4().hex
            try:
                claimed = await store.claim_cleanup(run_id, owner, lease_seconds=300)
            except LookupError:
                continue
            if not claimed:
                continue
            try:
                row = await store.get_run(run_id)
                if row is None:
                    continue
                # Timeout precedes lease expiry, so another replica never imports
                # or deletes the same execution while this cleanup still runs.
                await asyncio.wait_for(_cleanup_run(store, owner, row, bindings, adapter, phoenix), timeout=240)
            except asyncio.CancelledError:
                raise
            except Exception as exc:
                log.warning("runtime_retention_pending", run_id=run_id, error=type(exc).__name__)
            finally:
                await store.release_cleanup(run_id, owner)
    finally:
        if own_adapter:
            await adapter.close()
