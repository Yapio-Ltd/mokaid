"""No provider calls: durable acceptance, restart leases and remote commands."""

import asyncio
from types import SimpleNamespace
from unittest.mock import AsyncMock

import pytest

from app import runtime_dispatch
from app.agents import runner
from app.queue import consumer
from app.runtime_dispatch import Dispatcher
from app.runtime_store import MemoryStore
from app.schemas import RunRequest, RunState, RunStatus


def request():
    return RunRequest(run_id="dispatch-r", workspace_id="w", task_id="t")


async def eventually(predicate):
    for _ in range(100):
        if predicate():
            return
        await asyncio.sleep(0.005)
    raise AssertionError("Expected background transition did not occur")


async def test_acceptance_failure_never_starts_execution(monkeypatch):
    store = MemoryStore()
    monkeypatch.setattr(store, "accept_run", AsyncMock(side_effect=RuntimeError("database unavailable")))
    execute = AsyncMock()
    monkeypatch.setattr(runner, "execute_run", execute)
    dispatch = Dispatcher(store)
    with pytest.raises(RuntimeError):
        await dispatch.accept(request())
    assert dispatch.pump is None
    execute.assert_not_called()


async def test_two_replicas_execute_a_durably_accepted_run_once(monkeypatch):
    store = MemoryStore()
    await store.accept_run(request().model_dump(mode="json"))
    execute = AsyncMock(return_value=RunState(run_id=request().run_id, status=RunStatus.COMPLETED))
    monkeypatch.setattr(runner, "execute_run", execute)
    first, second = Dispatcher(store, owner="first"), Dispatcher(store, owner="second")
    await asyncio.gather(first.tick(), second.tick())
    await eventually(lambda: not first.active and not second.active)
    assert execute.await_count == 1
    assert (await store.get_run(request().run_id))["status"] == "completed"


async def test_crashed_lease_recovery_uses_resume(monkeypatch):
    store = MemoryStore()
    await store.accept_run(request().model_dump(mode="json"))
    await store.claim_runs("dead-worker")
    store.rows[request().run_id]["lease_until"] = 0
    execute = AsyncMock(return_value=RunState(run_id=request().run_id, status=RunStatus.COMPLETED))
    monkeypatch.setattr(runner, "execute_run", execute)
    dispatch = Dispatcher(store, owner="new-worker")
    await dispatch.tick()
    await eventually(lambda: not dispatch.active)
    assert execute.call_args.kwargs["resume"] is True


async def test_shutdown_releases_run_for_recovery_without_user_cancel(monkeypatch):
    store = MemoryStore()
    seen = []

    async def execute(req, **kwargs):
        seen.append(req)
        await asyncio.Event().wait()

    monkeypatch.setattr(runner, "execute_run", execute)
    await store.accept_run(request().model_dump(mode="json"))
    dispatch = Dispatcher(store)
    await dispatch.tick()
    await eventually(lambda: bool(seen))
    await dispatch.stop()
    assert seen[0].input["_worker_recovery_stop"] is True
    row = await store.get_run(request().run_id)
    assert row["status"] == "accepted"
    assert not row["cancel_requested"]


async def test_command_persisted_by_other_replica_cancels_owner(monkeypatch):
    store = MemoryStore()
    started = asyncio.Event()

    async def execute(req, **kwargs):
        started.set()
        await asyncio.Event().wait()

    monkeypatch.setattr(runner, "execute_run", execute)
    await store.accept_run(request().model_dump(mode="json"))
    owner = Dispatcher(store, owner="one", poll_seconds=0.005)
    await owner.tick()
    await started.wait()
    # The receiving replica only writes a command; it never needs the owner's
    # asyncio task or in-memory run registry.
    await store.enqueue_command(request().run_id, "cancel", command_id="cancel-request")
    await eventually(lambda: not owner.active)
    row = await store.get_run(request().run_id)
    assert row["status"] == "canceled"
    assert row["cancel_requested"]


async def test_cancel_keeps_lease_alive_until_remote_cleanup_finishes(monkeypatch):
    store = MemoryStore()
    started = asyncio.Event()
    cleaning = asyncio.Event()
    release_cleanup = asyncio.Event()
    interrupted = []

    async def execute(req, **kwargs):
        started.set()
        try:
            await asyncio.Event().wait()
        except asyncio.CancelledError:
            interrupted.append(True)
            cleaning.set()
            await release_cleanup.wait()
            return RunState(run_id=req.run_id, status=RunStatus.CANCELED)

    monkeypatch.setattr(runner, "execute_run", execute)
    await store.accept_run(request().model_dump(mode="json"))
    owner = Dispatcher(store, owner="one", lease_seconds=0.03, poll_seconds=0.002)
    await owner.tick()
    await started.wait()
    await store.enqueue_command(request().run_id, "cancel", command_id="cancel-request")
    await cleaning.wait()
    await asyncio.sleep(0.05)
    assert not await store.claim_runs("other-replica")
    assert len(interrupted) == 1
    release_cleanup.set()
    await eventually(lambda: not owner.active)
    assert (await store.get_run(request().run_id))["status"] == "canceled"


async def test_resume_command_is_not_consumed_until_runner_applies_decision(monkeypatch):
    store = MemoryStore()
    await store.accept_run(request().model_dump(mode="json"))
    await store.claim_runs("owner")
    dispatch = Dispatcher(store, owner="owner")
    await store.enqueue_command(request().run_id, "resume", {"decision": "approved"}, "approval-id")
    dispatch.delivered_commands[request().run_id] = "approval-id"
    assert await store.pending_commands(request().run_id, "owner")
    await dispatch.decision_consumed(request().run_id, "wrong-id")
    assert await store.pending_commands(request().run_id, "owner")
    await dispatch.decision_consumed(request().run_id, "approval-id")
    assert not await store.pending_commands(request().run_id, "owner")


async def test_only_current_lease_owner_can_supply_live_local_status(monkeypatch):
    store = MemoryStore()
    await store.accept_run(request().model_dump(mode="json"))
    await store.claim_runs("owner")
    dispatch = Dispatcher(store, owner="owner")
    dispatch.requests[request().run_id] = request()
    monkeypatch.setattr(runtime_dispatch, "_dispatcher", dispatch)
    live = RunState(run_id=request().run_id, status=RunStatus.WAITING_FOR_APPROVAL)
    monkeypatch.setattr(runner, "get_run", lambda _run_id: live)
    assert runtime_dispatch.locally_owned_state(request().run_id, await store.get_run(request().run_id)) is live
    await store.release_run(request().run_id, "owner")
    await store.claim_runs("replacement")
    assert runtime_dispatch.locally_owned_state(request().run_id, await store.get_run(request().run_id)) is None


async def test_sqs_failure_is_not_deleted_but_success_is(monkeypatch):
    class Queue:
        def __init__(self):
            self.polled = False
            self.deleted = []

        def receive_message(self, **kwargs):
            if self.polled:
                raise asyncio.CancelledError()
            self.polled = True
            return {"Messages": [{"Body": "not JSON", "ReceiptHandle": "bad"},
                                 {"Body": '{"type":"run"}', "ReceiptHandle": "good"}]}

        def delete_message(self, **kwargs):
            self.deleted.append(kwargs["ReceiptHandle"])

    queue = Queue()
    monkeypatch.setattr(consumer.boto3, "client", lambda *args, **kwargs: queue)
    monkeypatch.setattr(consumer, "get_settings", lambda: SimpleNamespace(ai_runs_queue_url="local", aws_region="test"))
    monkeypatch.setattr(consumer, "_handle_message", AsyncMock())
    with pytest.raises(asyncio.CancelledError):
        await consumer.consume_forever()
    assert queue.deleted == ["good"]


async def test_sqs_run_awaits_acceptance_and_command_persistence(monkeypatch):
    accept = AsyncMock(side_effect=RuntimeError("durable commit failed"))
    monkeypatch.setattr(runtime_dispatch, "accept_run", accept)
    with pytest.raises(RuntimeError):
        await consumer._handle_message({"type": "run", **request().model_dump(mode="json")})
    command = AsyncMock(side_effect=RuntimeError("durable command failed"))
    monkeypatch.setattr(runtime_dispatch, "submit_command", command)
    with pytest.raises(RuntimeError):
        await consumer._handle_message({"type": "cancel", "run_id": request().run_id})
