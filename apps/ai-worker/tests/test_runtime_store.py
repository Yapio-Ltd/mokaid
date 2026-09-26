"""Atomic durable-state contract; no provider/network calls."""

import asyncio
import time
from types import SimpleNamespace
from unittest.mock import AsyncMock

import pytest

from app import runtime_store
from app.runtime_store import MemoryStore, OwnershipConflict, StoreUnavailable, UnknownSession


def payload(run_id="r", workspace_id="ws", **kwargs):
    return {"run_id": run_id, "workspace_id": workspace_id, "task_id": "t", "agent_id": "a", "input": {}, **kwargs}


async def test_accept_is_idempotent_and_preserves_original_principal():
    store = MemoryStore()
    assert await store.accept_run(payload(input={"instruction": "Original", "_worker_recovery_stop": True}))
    assert not await store.accept_run(payload(input={"instruction": "Replacement"}))
    row = await store.get_run("r")
    assert row["payload"]["input"] == {"instruction": "Original"}
    with pytest.raises(OwnershipConflict):
        await store.accept_run(payload(workspace_id="foreign"))


async def test_only_one_replica_can_claim_then_expiry_allows_recovery():
    store = MemoryStore()
    await store.accept_run(payload())
    claims = await asyncio.gather(store.claim_runs("one"), store.claim_runs("two"))
    assert sum(map(len, claims)) == 1
    owner = (await store.get_run("r"))["owner"]
    assert await store.renew_lease("r", owner)
    assert not await store.renew_lease("r", "wrong")
    store.rows["r"]["lease_until"] = time.time() - 1
    recovered = await store.claim_runs("replacement")
    assert recovered[0]["attempt"] == 2
    assert not await store.finish_run("r", owner, "completed")
    assert await store.finish_run("r", "replacement", "completed")
    assert not await store.claim_runs("another")


async def test_execution_patches_and_session_bindings_are_scoped():
    store = MemoryStore()
    await store.accept_run(payload())
    await store.accept_run(payload("foreign", "elsewhere"))
    await asyncio.gather(store.save_execution("r", team={"members": ["a"]}),
                         store.save_execution("r", cursor=2))
    await store.save_execution("r", session_id="session-one")
    await store.save_execution("r", session_id="session-two")
    await store.save_execution("r", "colleague", session_id="session-child", cursor=10)
    record = await store.get_execution("r")
    assert record["team"] == {"members": ["a"]}
    assert record["cursor"] == 2
    assert (await store.find_session("session-one"))["run_id"] == "r"
    assert (await store.get_execution("r", "colleague"))["cursor"] == 10
    with pytest.raises(OwnershipConflict):
        await store.save_execution("foreign", session_id="session-one")


async def test_business_operations_deduplicate_across_sessions_and_participants():
    store = MemoryStore()
    await store.accept_run(payload())
    first, duplicate = await asyncio.gather(
        store.begin_operation("r", "send_email", {"to": "user@example.test", "subject": "Report"}),
        store.begin_operation("r", "send_email", {"subject": "Report", "to": "user@example.test"}, "colleague"),
    )
    assert sum(operation["execute"] for operation in (first, duplicate)) == 1
    assert first["key"] == duplicate["key"]
    key = first["key"]
    await store.finish_operation("r", key, "pending", {"approval_id": "approval"})
    await store.finish_operation("r", key, "approved", {"effective_args": {"to": "user@example.test"}})
    await store.finish_operation("r", key, "executing", None)
    assert not (await store.begin_operation("r", "send_email", {"to": "user@example.test", "subject": "Report"}))["execute"]
    await store.finish_operation("r", key, "succeeded", {"sent": True})
    cached = await store.begin_operation("r", "send_email", {"to": "user@example.test", "subject": "Report"})
    assert cached["result"] == {"sent": True}
    with pytest.raises(OwnershipConflict):
        await store.finish_operation("r", key, "executing", None)


async def test_commands_survive_new_owner_and_only_lease_owner_can_ack():
    store = MemoryStore()
    await store.accept_run(payload())
    await store.claim_runs("one")
    assert await store.enqueue_command("r", "resume", {"decision": "approved"}, "approval-one")
    assert not await store.enqueue_command("r", "resume", {"decision": "approved"}, "approval-one")
    with pytest.raises(OwnershipConflict):
        await store.enqueue_command("r", "resume", {"decision": "rejected"}, "approval-one")
    assert not await store.ack_command("r", "approval-one", "wrong")
    await store.release_run("r", "one")
    await store.claim_runs("two")
    assert (await store.pending_commands("r", "two"))[0]["id"] == "approval-one"
    assert await store.ack_command("r", "approval-one", "two")
    assert not await store.pending_commands("r", "two")
    await store.enqueue_command("r", "cancel", command_id="cancel-one")
    assert await store.is_cancelled("r")


async def test_event_ownership_is_lookup_based_and_idempotent():
    store = MemoryStore()
    await store.accept_run(payload())
    await store.save_execution("r", session_id="session")
    signed_payload = {"metadata": {"workspace_id": "foreign", "run_id": "foreign"}}
    assert await store.record_event("event", "session", "agent.session.completed", signed_payload)
    assert not await store.record_event("event", "session", "agent.session.completed", signed_payload)
    event = (await store.list_events("r"))[0]
    assert event["run_id"] == "r" and event["workspace_id"] == "ws"
    assert not await store.list_events("foreign")
    with pytest.raises(UnknownSession):
        await store.record_event("new", "unknown", "agent.session.completed", signed_payload)


async def test_cleanup_preserves_remote_sessions_until_deletion_confirmed():
    store = MemoryStore()
    await store.accept_run(payload())
    await store.claim_runs("owner")
    await store.save_execution("r", session_id="session")
    await store.finish_run("r", "owner", "completed")
    store.rows["r"]["completed_at"] = time.time() - 8 * 86400
    assert len(await store.expired_sessions()) == 1
    assert await store.cleanup() == 0
    await store.mark_session_deleted("session")
    assert await store.cleanup() == 1
    assert await store.get_run("r") is None
    assert await store.find_session("session") is None


async def test_configured_database_failure_never_falls_back_to_memory(monkeypatch):
    monkeypatch.setattr(runtime_store, "_store", None)
    monkeypatch.setattr(runtime_store, "get_settings", lambda: SimpleNamespace(database_url="postgresql://local", openai_agents_enabled=False))
    monkeypatch.setattr(runtime_store.persistence, "get_pool", AsyncMock(side_effect=RuntimeError("offline")))
    with pytest.raises(StoreUnavailable):
        await runtime_store.get_store()
    assert runtime_store._store is None


async def test_enabled_managed_agents_require_database_even_after_dev_initialization(monkeypatch):
    monkeypatch.setattr(runtime_store, "_store", MemoryStore())
    monkeypatch.setattr(runtime_store, "get_settings", lambda: SimpleNamespace(database_url="", openai_agents_enabled=True))
    with pytest.raises(StoreUnavailable):
        await runtime_store.get_store()
