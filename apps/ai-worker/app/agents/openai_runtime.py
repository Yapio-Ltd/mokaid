"""Small SDK boundary for the managed Codex harness (no business authority)."""

from __future__ import annotations

import json
from typing import Any

from openai import AsyncOpenAI

from app.config import get_settings


def plain(value: Any) -> dict[str, Any]:
    """Convert SDK resources to the same representation used by fake adapters."""
    if isinstance(value, dict):
        return value
    return value.model_dump(mode="json")


class OpenAIAgentsAdapter:
    """Use canonical saved resources for recovery; SSE is never replayed."""

    def __init__(self, client: Any = None) -> None:
        self.client = client or AsyncOpenAI(
            api_key=get_settings().openai_api_key, max_retries=0, timeout=30.0
        )
        self.sessions = self.client.beta.agents.sessions

    async def start(self, configuration: dict[str, Any]) -> dict[str, Any]:
        """Create an idle session; save its ID before submitting any work."""
        return plain(await self.sessions.create(**configuration))

    async def continue_session(self, session_id: str, text: str) -> None:
        """Continue an existing conversation (or steer a running turn)."""
        await self.sessions.events.create(
            session_id,
            events=[
                {
                    "type": "agent.session.input.message",
                    "input": [{"role": "user", "content": [{"type": "input_text", "text": text}]}],
                }
            ],
        )

    async def retrieve(self, session_id: str) -> dict[str, Any]:
        """Retrieve current pending actions and best-effort usage."""
        return plain(await self.sessions.retrieve(session_id))

    async def find_session(self, creation_id: str) -> dict[str, Any] | None:
        """Reconcile a lost create response using our persisted creation token.

        The API has no metadata filter, so inspect every page. Absence is not
        proof that an ambiguous create failed; the caller must not blindly
        recreate. Multiple matches are unsafe to choose between.
        """
        if not creation_id or len(creation_id) > 512:
            raise ValueError("A valid session creation token is required.")
        match: dict[str, Any] | None = None
        async for resource in self.sessions.list(order="desc", limit=100):
            session = plain(resource)
            if (session.get("metadata") or {}).get("mokaid_creation_id") != creation_id:
                continue
            if match is not None and match["id"] != session["id"]:
                raise ValueError(
                    "Multiple sessions match the creation token; reconciliation is required."
                )
            match = session
        return match

    async def items(self, session_id: str) -> list[dict[str, Any]]:
        """Read every page in chronological order, deduplicated by item ID."""
        return [plain(item) async for item in self.sessions.items.list(session_id, order="asc")]

    async def turns(self, session_id: str) -> list[dict[str, Any]]:
        """Read canonical turn status; idle is not proof of success."""
        return [plain(turn) async for turn in self.sessions.turns.list(session_id, order="asc")]

    async def tool_result(self, session_id: str, action: dict[str, Any], result: Any) -> None:
        """Answer the same pending call; the caller journals execution first."""
        error = result.get("error") if isinstance(result, dict) else None
        event = {
            "type": "agent.session.input.tool_result",
            "turn_id": action["turn_id"],
            "call_id": action["call_id"],
            "success": not bool(error),
        }
        if error:
            event["error"] = str(error)
        else:
            event["output"] = json.dumps(result, ensure_ascii=False, default=str)
        await self.sessions.events.create(session_id, events=[event])

    async def cancel(self, session_id: str) -> None:
        """Closing a stream does not stop a run: send the explicit cancel event."""
        await self.sessions.events.create(
            session_id, events=[{"type": "agent.session.input.cancel"}]
        )

    async def artifacts(self, session_id: str) -> list[dict[str, Any]]:
        """List immutable published outputs, including previous completed turns."""
        return [plain(item) async for item in self.sessions.artifacts.list(session_id)]

    async def artifact_content(self, session_id: str, artifact_id: str, max_bytes: int) -> bytes:
        """Bound streamed downloads before committing memory or uploading to S3."""
        chunks: list[bytes] = []
        size = 0
        async with self.sessions.artifacts.with_streaming_response.content(
            artifact_id, session_id=session_id
        ) as response:
            async for chunk in response.iter_bytes():
                size += len(chunk)
                if size > max_bytes:
                    raise ValueError("Artifact exceeds the configured transfer limit.")
                chunks.append(chunk)
        return b"".join(chunks)

    async def delete(self, session_id: str) -> None:
        """Delete only after the caller confirms durable delivery."""
        await self.sessions.delete(session_id)

    async def close(self) -> None:
        """Release transport resources without canceling remote sessions."""
        await self.client.close()
