"""Durable acceptance and lease-owned execution for HTTP and SQS delivery."""

from __future__ import annotations

import asyncio
import time
import uuid
from collections.abc import Awaitable, Callable
from typing import Any

import structlog

from app import persistence
from app.agents import runner
from app.runtime_store import RuntimeStore, StoreUnavailable, get_store
from app.schemas import ResumeRequest, RunRequest, RunStatus

log = structlog.get_logger()
_cleanup_sessions: Callable[[RuntimeStore], Awaitable[Any]] | None = None


def register_session_cleanup(callback: Callable[[RuntimeStore], Awaitable[Any]]) -> None:
    global _cleanup_sessions
    _cleanup_sessions = callback


class Dispatcher:
    def __init__(self, store: RuntimeStore, *, owner: str | None = None, lease_seconds: int = 60,
                 poll_seconds: float = 1, max_concurrent: int = 4) -> None:
        self.store = store
        self.owner = owner or str(uuid.uuid4())
        self.lease_seconds = lease_seconds
        self.poll_seconds = poll_seconds
        self.max_concurrent = max_concurrent
        self.active: dict[str, asyncio.Task] = {}
        self.requests: dict[str, RunRequest] = {}
        self.delivered_commands: dict[str, str] = {}
        self.pump: asyncio.Task | None = None
        self.housekeeping: asyncio.Task | None = None
        self.wake = asyncio.Event()
        self.stopping = False

    def start(self) -> None:
        if self.pump is None or self.pump.done():
            self.stopping = False
            self.pump = asyncio.create_task(self.run_forever())
            self.housekeeping = asyncio.create_task(self.cleanup_forever())
        self.wake.set()

    async def accept(self, request: RunRequest) -> bool:
        # No task is launched and no message is acknowledged until this commit.
        inserted = await self.store.accept_run(request.model_dump(mode="json"))
        self.start()
        return inserted

    async def command(self, run_id: str, kind: str, payload: dict[str, Any] | None = None,
                      command_id: str | None = None) -> bool:
        if not await self.store.get_run(run_id):
            raise LookupError("Unknown worker run")
        inserted = await self.store.enqueue_command(run_id, kind, payload, command_id)
        self.start()
        return inserted

    async def tick(self) -> None:
        available = self.max_concurrent - len(self.active)
        if available <= 0:
            return
        for row in await self.store.claim_runs(self.owner, available, self.lease_seconds):
            run_id = row["run_id"]
            task = asyncio.create_task(self._run_claimed(row))
            self.active[run_id] = task
            task.add_done_callback(lambda task, key=run_id: self._finished(key, task))

    def _finished(self, run_id: str, task: asyncio.Task) -> None:
        self.active.pop(run_id, None)
        self.requests.pop(run_id, None)
        self.delivered_commands.pop(run_id, None)
        if not task.cancelled() and task.exception():
            log.error("durable_run_supervisor_failed", run_id=run_id, error=type(task.exception()).__name__)
        self.wake.set()

    async def _run_claimed(self, row: dict[str, Any]) -> None:
        run_id = row["run_id"]
        request = RunRequest.model_validate(row["payload"])
        # Preserve graph/team recovery state, but never change run ownership.
        if row["attempt"] > 1 and self.store.durable:
            saved = await persistence.load_run_request(run_id)
            if saved and all(saved.get(key) == row["payload"].get(key) for key in ("run_id", "workspace_id", "task_id", "agent_id")):
                request = RunRequest.model_validate(saved)
        request.input.pop("_worker_recovery_stop", None)
        self.requests[run_id] = request
        # A restored approval must be available before its checkpointed tool
        # re-enters the gate. It remains durable until the runner consumes it.
        if row["attempt"] > 1:
            for command in await self.store.pending_commands(run_id, self.owner):
                if command["kind"] == "resume":
                    runner.seed_decision(ResumeRequest.model_validate({**command["payload"], "run_id": run_id, "command_id": command["id"]}))
                    self.delivered_commands[run_id] = command["id"]
                    break

        execution = asyncio.create_task(runner.execute_run(request, resume=row["attempt"] > 1))
        runner.register_run_task(run_id, execution)
        monitor = asyncio.create_task(self._monitor(run_id, request, execution))
        try:
            state = await execution
            await self.store.finish_run(run_id, self.owner, state.status.value,
                                        error=state.error, output=state.output)
        except asyncio.CancelledError:
            if request.input.get("_worker_recovery_stop") or self.stopping:
                await self.store.release_run(run_id, self.owner)
            else:
                await self.store.finish_run(run_id, self.owner, "canceled")
        except Exception:
            # Unknown execution/transport failures are recoverable. Persisted
            # provider IDs and operation journals prevent repeating effects.
            await self.store.release_run(run_id, self.owner)
            raise
        finally:
            monitor.cancel()
            await asyncio.gather(monitor, return_exceptions=True)

    async def _monitor(self, run_id: str, request: RunRequest, execution: asyncio.Task) -> None:
        next_renewal = time.monotonic() + self.lease_seconds / 3
        try:
            while not execution.done():
                if time.monotonic() >= next_renewal:
                    if not await self.store.renew_lease(run_id, self.owner, self.lease_seconds):
                        raise StoreUnavailable("Execution lease lost")
                    next_renewal = time.monotonic() + self.lease_seconds / 3
                commands = await self.store.pending_commands(run_id, self.owner)
                for command in commands:
                    if command["kind"] == "cancel":
                        execution.cancel()
                        await self.store.ack_command(run_id, command["id"], self.owner)
                        # The managed runner may still need to confirm remote
                        # termination and save files in its finally block. Keep
                        # renewing ownership while that cleanup is in progress.
                        continue
                    if run_id in self.delivered_commands:
                        continue
                    state = runner.get_run(run_id)
                    if state and state.status == RunStatus.WAITING_FOR_APPROVAL:
                        decision = ResumeRequest.model_validate({**command["payload"], "run_id": run_id, "command_id": command["id"]})
                        self.delivered_commands[run_id] = command["id"]
                        if not await runner.resume_run(decision):
                            self.delivered_commands.pop(run_id, None)
                await asyncio.sleep(self.poll_seconds)
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            # Stop local work whenever ownership cannot be established. This is
            # a recoverable interruption, not a user's provider cancellation.
            request.input["_worker_recovery_stop"] = True
            execution.cancel()
            log.warning("durable_run_lease_interrupted", run_id=run_id, error=type(exc).__name__)

    async def decision_consumed(self, run_id: str, command_id: str | None = None) -> None:
        delivered = self.delivered_commands.get(run_id)
        if delivered and (command_id is None or command_id == delivered):
            if await self.store.ack_command(run_id, delivered, self.owner):
                self.delivered_commands.pop(run_id, None)

    async def run_forever(self) -> None:
        while not self.stopping:
            try:
                await self.tick()
            except asyncio.CancelledError:
                raise
            except Exception as exc:
                log.error("durable_dispatch_retry", error=type(exc).__name__)
            self.wake.clear()
            try:
                await asyncio.wait_for(self.wake.wait(), timeout=self.poll_seconds)
            except TimeoutError:
                pass

    async def cleanup_forever(self) -> None:
        """Retention must never block admission or recovery of unrelated runs."""
        while not self.stopping:
            try:
                if _cleanup_sessions is not None:
                    await _cleanup_sessions(self.store)
                await self.store.cleanup(7)
            except asyncio.CancelledError:
                raise
            except Exception as exc:
                log.warning("durable_cleanup_retry", error=type(exc).__name__)
            await asyncio.sleep(3600)

    async def stop(self) -> None:
        self.stopping = True
        background = [task for task in (self.pump, self.housekeeping) if task is not None]
        for task in background:
            task.cancel()
        await asyncio.gather(*background, return_exceptions=True)
        for request in self.requests.values():
            request.input["_worker_recovery_stop"] = True
        for task in list(self.active.values()):
            task.cancel()
        await asyncio.gather(*list(self.active.values()), return_exceptions=True)


_dispatcher: Dispatcher | None = None
_dispatcher_lock = asyncio.Lock()


async def get_dispatcher() -> Dispatcher:
    global _dispatcher
    async with _dispatcher_lock:
        if _dispatcher is None:
            _dispatcher = Dispatcher(await get_store())
        return _dispatcher


async def startup() -> None:
    """Non-blocking lifespan initializer; no in-memory fallback on DB failure."""
    while True:
        try:
            (await get_dispatcher()).start()
            return
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            log.error("durable_dispatch_start_retry", error=type(exc).__name__)
            await asyncio.sleep(5)


async def shutdown() -> None:
    if _dispatcher is not None:
        await _dispatcher.stop()


async def accept_run(request: RunRequest) -> bool:
    return await (await get_dispatcher()).accept(request)


async def submit_command(run_id: str, kind: str, payload: dict[str, Any] | None = None,
                         command_id: str | None = None) -> bool:
    return await (await get_dispatcher()).command(run_id, kind, payload, command_id)


async def decision_consumed(run_id: str, command_id: str | None = None) -> None:
    if _dispatcher is not None:
        await _dispatcher.decision_consumed(run_id, command_id)


def locally_owned_state(run_id: str, saved: dict[str, Any]) -> Any:
    """A stale in-process result must not hide a newer replica's state."""
    if (_dispatcher is not None and run_id in _dispatcher.requests
            and saved.get("owner") == _dispatcher.owner and saved.get("lease_until", 0) > time.time()):
        return runner.get_run(run_id)
    return None


async def assert_lease(run_id: str) -> None:
    """Call before effects/completion; direct unit runs have no dispatch owner."""
    if _dispatcher is None or run_id not in _dispatcher.requests:
        return
    row = await _dispatcher.store.get_run(run_id)
    if not row or row["owner"] != _dispatcher.owner or row["lease_until"] <= time.time():
        raise StoreUnavailable("Execution lease lost")
