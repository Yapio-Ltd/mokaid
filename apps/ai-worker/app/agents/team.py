"""Bounded parallel contributions to one mission, with a shared team notebook.

The assigned agent owns delivery. Colleagues have independent conversations,
their own knowledge scope, and internal tools only; they cannot recursively
delegate, change the task, or borrow the lead's external integrations.
"""

from __future__ import annotations

import asyncio
import math
from collections.abc import Awaitable, Callable
from copy import deepcopy
from dataclasses import dataclass, field
from typing import Any

from pydantic import BaseModel, Field

from app.agents.colleagues import find_colleague
from app.schemas import Colleague, RunRequest, ToolCall

MAX_PARTICIPANTS = 3
MAX_MESSAGES_PER_AGENT = 5


class TeamAssignment(BaseModel):
    """One concrete, independently executable contribution."""

    colleague: str = Field(min_length=1, max_length=160)
    brief: str = Field(min_length=10, max_length=5000)


@dataclass
class Contribution:
    """A participant's outcome; failures never masquerade as completed work."""

    agent_id: str
    name: str
    brief: str
    status: str = "running"
    summary: str = ""
    artifacts: list[str] = field(default_factory=list)
    error: str | None = None
    tool_calls: list[dict[str, Any]] = field(default_factory=list)
    usage: dict[str, Any] = field(default_factory=dict)

    def as_dict(self, *, include_evidence: bool = False) -> dict[str, Any]:
        result = {
            "agent_id": self.agent_id,
            "name": self.name,
            "brief": self.brief,
            "status": self.status,
            "summary": self.summary,
            "artifacts": list(self.artifacts),
            "error": self.error,
        }
        if include_evidence:
            # Tool outputs can contain large file bodies. They belong in the
            # private resume checkpoint, never every model/UI notebook read.
            result["tool_calls"] = deepcopy(self.tool_calls)
            result["usage"] = dict(self.usage)
        return result


class TeamSession:
    """Own all participant tasks so cancellation cannot leave work behind."""

    def __init__(
        self,
        request: RunRequest,
        execute: Callable[[Colleague, str, TeamSession], Awaitable[dict[str, Any]]],
        post_comment: Callable[..., Awaitable[Any]],
        checkpoint: Callable[[dict[str, Any]], Awaitable[Any]] | None = None,
        strict_checkpoint: bool = False,
    ) -> None:
        self.request = request
        self.execute = execute
        self.post_comment = post_comment
        self.checkpoint = checkpoint
        self.strict_checkpoint = strict_checkpoint
        self.preserve_running_on_cancel = False
        self._checkpoint_lock = asyncio.Lock()
        self._restored_ids: set[str] = set()
        self.contributions: dict[str, Contribution] = {}
        self.tasks: dict[str, asyncio.Task[None]] = {}
        self.messages: list[dict[str, Any]] = []
        self.message_counts: dict[str, int] = {}
        self.collected = False

    async def start(self, assignments: list[TeamAssignment]) -> dict[str, Any]:
        """Validate the whole batch before launching any background work."""
        if self.contributions:
            return {"error": "A team is already working on this mission. Read their updates and collect their results."}
        if not 1 <= len(assignments) <= MAX_PARTICIPANTS:
            return {"error": f"Assign between 1 and {MAX_PARTICIPANTS} colleagues."}
        selected: list[tuple[Colleague, str]] = []
        for assignment in assignments:
            colleague = find_colleague(self.request.colleagues, assignment.colleague)
            if colleague is None or colleague.id == self.request.agent_id:
                return {"error": f"Unknown colleague: {assignment.colleague}"}
            if colleague.status != "idle":
                return {"error": f"{colleague.name} is unavailable for parallel work ({colleague.status})."}
            if any(other.id == colleague.id for other, _ in selected):
                return {"error": f"Give {colleague.name} one coherent assignment, not duplicate assignments."}
            selected.append((colleague, assignment.brief))

        # Populate the notebook before starting: even the fastest participant
        # sees every teammate's scope and can avoid duplicate work.
        for colleague, brief in selected:
            self.contributions[colleague.id] = Contribution(colleague.id, colleague.name, brief)
        await self._checkpoint()
        for colleague, brief in selected:
            self.tasks[colleague.id] = asyncio.create_task(self._work(colleague, brief))
        return {
            "started": self.snapshot()["participants"],
            "next": "Continue your own part while colleagues work. Share findings with send_team_message; collect_team_results before final delivery.",
        }

    async def _checkpoint(self) -> None:
        if self.checkpoint is None:
            return
        # Snapshot inside the lock: a slow earlier write must never overwrite
        # later findings from another participant with an older snapshot.
        async with self._checkpoint_lock:
            snapshot = self.snapshot(include_evidence=True)
            self.request.input["_team_state"] = snapshot
            try:
                await self.checkpoint(snapshot)
            except Exception:
                if self.strict_checkpoint:
                    raise
                # Same best-effort contract as the existing run checkpointer.
                # Live work and its notebook remain available during outages.
                pass

    async def restore(self, snapshot: dict[str, Any]) -> dict[str, Any]:
        """Restore a private checkpoint; only unfinished contributions restart.

        Reject malformed or foreign identities before launching any work.
        Completed evidence is available through restored_tool_calls for the
        lead's resumed delivery checks; public notebook reads omit file bodies.
        """
        if self.contributions:
            raise ValueError("A team session can only be restored before it starts.")
        if not isinstance(snapshot, dict):
            raise ValueError("Invalid team checkpoint.")
        participants = snapshot.get("participants")
        messages = snapshot.get("messages", [])
        if not isinstance(participants, list) or not 1 <= len(participants) <= MAX_PARTICIPANTS:
            raise ValueError("Invalid team checkpoint participants.")
        if not isinstance(messages, list) or len(messages) > (MAX_PARTICIPANTS + 1) * MAX_MESSAGES_PER_AGENT:
            raise ValueError("Invalid team checkpoint messages.")
        roster = {colleague.id: colleague for colleague in self.request.colleagues}
        restored: dict[str, Contribution] = {}
        for raw in participants:
            if not isinstance(raw, dict):
                raise ValueError("Invalid team checkpoint participant.")
            agent_id, brief = raw.get("agent_id"), raw.get("brief")
            if not isinstance(agent_id, str) or agent_id not in roster or agent_id == self.request.agent_id or agent_id in restored:
                raise ValueError("Unknown or duplicate team checkpoint participant.")
            if not isinstance(brief, str) or not 10 <= len(brief) <= 5000:
                raise ValueError("Invalid team checkpoint assignment.")
            status = raw.get("status")
            if not isinstance(status, str) or status not in {"running", "completed", "failed", "canceled"}:
                raise ValueError("Invalid team checkpoint status.")
            if status == "running" and roster[agent_id].status != "idle":
                raise ValueError("An unavailable colleague cannot resume parallel work.")
            summary, artifacts, error = raw.get("summary", ""), raw.get("artifacts", []), raw.get("error")
            if not isinstance(summary, str) or len(summary) > 120_000:
                raise ValueError("Invalid team checkpoint summary.")
            if not isinstance(artifacts, list) or len(artifacts) > 200 or any(not isinstance(path, str) or len(path) > 2048 for path in artifacts):
                raise ValueError("Invalid team checkpoint artifacts.")
            if error is not None and (not isinstance(error, str) or len(error) > 12_000):
                raise ValueError("Invalid team checkpoint error.")
            raw_calls = raw.get("tool_calls", [])
            if not isinstance(raw_calls, list) or len(raw_calls) > 200:
                raise ValueError("Invalid team checkpoint tool evidence.")
            calls = [ToolCall.model_validate(call) for call in raw_calls]
            if any(call.agent_id not in (None, agent_id) for call in calls):
                raise ValueError("Team checkpoint evidence belongs to another agent.")
            usage = raw.get("usage", {})
            if not isinstance(usage, dict) or any(
                key not in {"prompt_tokens", "completion_tokens", "images", "cost_usd"}
                or not isinstance(value, (int, float)) or isinstance(value, bool)
                or not math.isfinite(value) or value < 0
                for key, value in usage.items()
            ):
                raise ValueError("Invalid team checkpoint usage.")
            if status == "completed" and not summary.strip() and not artifacts:
                raise ValueError("Completed team checkpoint has no contribution.")
            restored[agent_id] = Contribution(
                agent_id, roster[agent_id].name, brief, status, summary,
                list(artifacts), error,
                [{**call.model_dump(mode="json"), "agent_id": agent_id} for call in calls],
                dict(usage),
            )
        participant_ids = set(restored) | {self.request.agent_id}
        counts: dict[str, int] = {}
        restored_messages = []
        for raw in messages:
            if not isinstance(raw, dict):
                raise ValueError("Invalid team checkpoint message.")
            sender, recipient, body = raw.get("agent_id"), raw.get("recipient_id"), raw.get("body")
            if not isinstance(sender, str) or sender not in participant_ids or (
                recipient is not None and (not isinstance(recipient, str) or recipient not in participant_ids)
            ) or not isinstance(body, str) or not 1 <= len(body.strip()) <= 2000:
                raise ValueError("Invalid team checkpoint message scope.")
            counts[sender] = counts.get(sender, 0) + 1
            if counts[sender] > MAX_MESSAGES_PER_AGENT:
                raise ValueError("Invalid team checkpoint message count.")
            restored_messages.append({
                "sequence": len(restored_messages) + 1, "agent_id": sender,
                "recipient_id": recipient, "body": body,
            })
        self.contributions = restored
        self.messages = restored_messages
        self.message_counts = counts
        self._restored_ids = {key for key, item in restored.items() if item.status != "running"}
        # Even previously collected results must enter the resumed lead's
        # context before it can close; this does not rerun completed colleagues.
        self.collected = False
        for agent_id, item in restored.items():
            if item.status == "running":
                self.tasks[agent_id] = asyncio.create_task(self._work(roster[agent_id], item.brief))
        return self.snapshot()

    def restored_tool_calls(self) -> list[dict[str, Any]]:
        return [
            deepcopy(call)
            for agent_id, item in self.contributions.items() if agent_id in self._restored_ids
            for call in item.tool_calls
        ]

    def restored_usage(self) -> list[dict[str, Any]]:
        return [
            dict(item.usage)
            for agent_id, item in self.contributions.items() if agent_id in self._restored_ids
        ]

    async def _post(self, agent_id: str | None, body: str) -> None:
        # The notebook remains available to participants even if UI reporting
        # is temporarily unavailable. A failed notification never loses work.
        try:
            await self.post_comment(
                self.request.workspace_id, self.request.task_id, body, agent_id=agent_id
            )
        except Exception:
            pass

    async def _work(self, colleague: Colleague, brief: str) -> None:
        contribution = self.contributions[colleague.id]
        french = self.request.input.get("language") == "fr"
        from app.agents.mission_kind import language_for_request

        french = french or language_for_request(self.request) == "fr"
        try:
            await self._post(
                colleague.id,
                ("Je prends en charge : " if french else "I'm working on: ") + brief,
            )
            result = await self.execute(colleague, brief, self)
            contribution.summary = str(result.get("summary") or "").strip()
            contribution.artifacts = list(result.get("artifacts") or [])
            contribution.error = result.get("error")
            contribution.tool_calls = list(result.get("tool_calls") or [])
            contribution.usage = dict(result.get("usage") or {})
            if not contribution.summary and not contribution.artifacts:
                contribution.error = contribution.error or "No contribution was produced."
            contribution.status = "failed" if contribution.error else "completed"
            await self._checkpoint()
            await self._post(
                colleague.id,
                (("Contribution bloquée : " if french else "Contribution blocked: ") + contribution.error)
                if contribution.error
                else ("Contribution prête : " if french else "Contribution ready: ") + contribution.summary,
            )
        except asyncio.CancelledError:
            if not self.request.input.get("_worker_recovery_stop") and not self.preserve_running_on_cancel:
                contribution.status = "canceled"
            await self._checkpoint()
            raise
        except Exception:
            # Provider exception strings may contain request URLs or credentials.
            contribution.status = "failed"
            contribution.error = "This colleague could not finish its contribution."
            await self._checkpoint()
            await self._post(colleague.id, contribution.error)

    async def send(self, sender_id: str, body: str, recipient: str = "") -> dict[str, Any]:
        """Publish an attributed update visible both to people and teammates."""
        if sender_id not in self.contributions and sender_id != self.request.agent_id:
            return {"error": "Only participants of this mission can send team messages."}
        if not body.strip() or len(body) > 2000:
            return {"error": "Write an update between 1 and 2000 characters."}
        target = None
        if recipient:
            target = next(
                (item for item in self.contributions.values()
                 if recipient.lower() in (item.agent_id.lower(), item.name.lower())), None
            )
            if target is None and recipient != self.request.agent_id:
                return {"error": "The recipient must belong to this mission's team."}
        if self.message_counts.get(sender_id, 0) >= MAX_MESSAGES_PER_AGENT:
            return {"error": "Update limit reached; put the remaining findings in your final contribution."}
        self.message_counts[sender_id] = self.message_counts.get(sender_id, 0) + 1
        message = {
            "sequence": len(self.messages) + 1,
            "agent_id": sender_id,
            "recipient_id": target.agent_id if target else recipient or None,
            "body": body.strip(),
        }
        self.messages.append(message)
        await self._checkpoint()
        await self._post(sender_id, (f"@{target.name} — " if target else "") + body.strip())
        return {"sent": True, "sequence": message["sequence"]}

    def snapshot(self, *, include_evidence: bool = False) -> dict[str, Any]:
        """All participants share the same immutable view of progress and findings."""
        return {
            "participants": [item.as_dict(include_evidence=include_evidence) for item in self.contributions.values()],
            "messages": [dict(message) for message in self.messages],
        }

    async def collect(self) -> dict[str, Any]:
        """Join every participant; one failure does not discard others' work."""
        if self.tasks:
            await asyncio.gather(*self.tasks.values())
        self.collected = True
        return self.snapshot()

    async def close(self) -> None:
        """Cancel and drain outstanding work on every exit, including failures."""
        for task in self.tasks.values():
            if not task.done():
                task.cancel()
        if self.tasks:
            await asyncio.gather(*self.tasks.values(), return_exceptions=True)
