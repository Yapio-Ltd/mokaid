"""Retention imports immutable outputs before deletion; no real API calls."""

import asyncio
import time
from unittest.mock import AsyncMock

import pytest

from app.agents import runtime_cleanup
from app.runtime_store import MemoryStore, OwnershipConflict
from app.schemas import RunRequest


class Adapter:
    def __init__(self, calls, usage=None):
        self.calls = calls
        self.usage = usage if usage is not None else {"input_tokens": 1000, "output_tokens": 50}

    async def cancel(self, session):
        self.calls.append(("cancel", session))
        await asyncio.sleep(0)

    async def retrieve(self, session):
        self.calls.append(("retrieve", session))
        return {"id": session, "status": "idle", "usage": self.usage}

    async def items(self, session):
        return [{"type": "message", "status": "completed", "role": "assistant", "phase": "final_answer",
                 "content": [{"type": "output_text", "text": "Saved report."}]}]

    async def turns(self, session):
        return [{"id": "turn", "status": "completed"}]

    async def artifacts(self, session):
        return [{"id": "published-" + session, "path": "/workspace/outputs/report.md", "size_bytes": 17}]

    async def artifact_content(self, session, artifact, limit):
        self.calls.append(("download", session))
        return b"A complete report"

    async def delete(self, session):
        self.calls.append(("delete", session))


class Phoenix:
    def __init__(self, calls):
        self.calls = calls
        self.receipts = []

    async def save_task_output(self, workspace, task, filename, content, **attrs):
        self.calls.append(("save", attrs["agent_id"]))
        assert workspace == "workspace" and task == "task"
        return {"id": "file-" + attrs["artifact_key"]}

    async def runtime_call(self, run, workspace, action, **attrs):
        self.calls.append((action, run))
        self.receipts.append(attrs)
        return {"status": "pending_usage" if attrs["cost_cents"] is None else "settled"}

    async def finalize_runtime(self, run, **delivery):
        self.calls.append(("finalize", run))
        assert delivery["output"]["runtime"]["manifest"]


async def expired_run(status="completed"):
    store = MemoryStore()
    request = RunRequest(run_id="run", workspace_id="workspace", task_id="task", agent_id="lead")
    await store.accept_run(request.model_dump(mode="json"))
    await store.claim_runs("worker")
    await store.save_execution("run", session_id="session", model="gpt-6-luna", tool_cost_cents=2)
    await store.finish_run("run", "worker", status)
    store.rows["run"]["completed_at" if status == "completed" else "paused_at"] = time.time() - 8 * 86400
    return store


async def test_retention_preserves_file_evidence_and_cost_before_provider_deletion():
    store = await expired_run()
    calls = []
    phoenix = Phoenix(calls)
    await runtime_cleanup.cleanup_sessions(store, adapter=Adapter(calls), phoenix=phoenix)
    names = [call[0] for call in calls]
    assert names.index("cancel") < names.index("retrieve") < names.index("save")
    assert names.index("save") < names.index("settle") < names.index("finalize") < names.index("delete")
    assert phoenix.receipts[0]["cost_cents"] == 3
    row = await store.get_run("run")
    assert row["retention_sessions"]["session"]["retention_imported"]
    assert row["executions"][""]["result"]["summary"] == "Saved report."
    assert row["executions"][""]["result"]["artifacts"][0]["provider_artifact_id"] == "published-session"
    assert (await store.find_session("session"))["deleted_at"]
    assert await store.cleanup() == 1


async def test_unknown_usage_is_exported_to_pending_reservation_not_zero_settlement():
    store = await expired_run()
    calls = []
    phoenix = Phoenix(calls)
    await runtime_cleanup.cleanup_sessions(store, adapter=Adapter(calls, usage={}), phoenix=phoenix)
    assert phoenix.receipts[0]["cost_cents"] is None
    assert phoenix.receipts[0]["usage_status"] == "unknown"
    assert (await store.find_session("session"))["deleted_at"]
    assert await store.cleanup() == 0
    assert (await store.get_execution("run"))["settlement_pending"]


async def test_delivery_failure_keeps_provider_session_and_retry_reuses_published_file():
    store = await expired_run()
    calls = []
    phoenix = Phoenix(calls)
    phoenix.finalize_runtime = AsyncMock(side_effect=RuntimeError("Phoenix unavailable"))
    adapter = Adapter(calls)
    await runtime_cleanup.cleanup_sessions(store, adapter=adapter, phoenix=phoenix)
    assert not (await store.find_session("session"))["deleted_at"]
    assert (await store.get_execution("run"))["delivery_pending"]
    assert not any(call[0] == "delete" for call in calls)
    phoenix.finalize_runtime = AsyncMock()
    await runtime_cleanup.cleanup_sessions(store, adapter=adapter, phoenix=phoenix)
    assert sum(call[0] == "save" for call in calls) == 1
    assert (await store.find_session("session"))["deleted_at"]


async def test_failed_import_never_deletes_or_claims_delivery():
    store = await expired_run()
    calls = []
    phoenix = Phoenix(calls)
    phoenix.save_task_output = AsyncMock(return_value=None)
    await runtime_cleanup.cleanup_sessions(store, adapter=Adapter(calls), phoenix=phoenix)
    assert not (await store.find_session("session"))["deleted_at"]
    assert not any(call[0] in {"delete", "finalize", "settle"} for call in calls)


async def test_abandoned_waiting_session_is_canceled_after_seven_days():
    store = await expired_run("waiting_for_user_input")
    calls = []
    await runtime_cleanup.cleanup_sessions(store, adapter=Adapter(calls), phoenix=Phoenix(calls))
    row = await store.get_run("run")
    assert row["status"] == "canceled"
    assert row["output"]["runtime"]["limitations"]
    assert not await store.claim_runs("future-worker")


async def test_cleanup_replicas_do_not_duplicate_provider_actions():
    store = await expired_run()
    calls = []
    adapter, phoenix = Adapter(calls), Phoenix(calls)
    await asyncio.gather(*(runtime_cleanup.cleanup_sessions(store, adapter=adapter, phoenix=phoenix) for _ in range(2)))
    assert sum(call[0] == "cancel" for call in calls) == 1
    assert sum(call[0] == "delete" for call in calls) == 1


async def test_retention_lease_blocks_resume_and_active_runs_never_expire():
    store = await expired_run("waiting_for_user_input")
    assert await store.claim_cleanup("run", "cleaner")
    with pytest.raises(OwnershipConflict):
        await store.enqueue_command("run", "resume", {"decision": "approved"})
    assert not await store.claim_runs("worker")
    await store.release_cleanup("run", "cleaner")
    await store.enqueue_command("run", "resume", {"decision": "approved"})
    assert not await store.claim_cleanup("run", "cleaner")
    assert await store.claim_runs("worker")
    assert not await store.expired_sessions()


async def test_rotated_session_snapshot_does_not_replace_latest_id_or_assume_usage():
    store = await expired_run()
    await store.save_execution("run", session_id="latest", model="gpt-6-luna")
    calls = []
    phoenix = Phoenix(calls)
    await runtime_cleanup.cleanup_sessions(store, adapter=Adapter(calls), phoenix=phoenix)
    assert (await store.get_execution("run"))["session_id"] == "latest"
    row = await store.get_run("run")
    assert set(row["retention_sessions"]) == {"session", "latest"}
    # The rotated session's pricing model was not saved; never silently omit it.
    assert phoenix.receipts[0]["cost_cents"] is None


async def test_no_expired_session_constructs_no_provider_client(monkeypatch):
    client = AsyncMock()
    monkeypatch.setattr(runtime_cleanup, "OpenAIAgentsAdapter", client)
    await runtime_cleanup.cleanup_sessions(MemoryStore())
    client.assert_not_called()
