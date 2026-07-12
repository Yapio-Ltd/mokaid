"""HTTP client for the Phoenix API worker endpoints (callbacks + resources)."""

import re
from typing import Any

import httpx
import structlog

from app.config import get_settings

log = structlog.get_logger()

# PostgreSQL text/jsonb columns cannot store NUL bytes (0x00); other C0 control
# characters (except \t \n \r) are also invalid in JSON strings and would
# reject the whole payload. Poorly-decoded binary (e.g. a raw PDF read as
# UTF-8) is the usual source — strip these so one bad tool output can never
# wedge a run in "running".
_INVALID_TEXT = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f]")


def _sanitize(value: Any) -> Any:
    """Recursively strips control characters from all strings in a payload."""
    if isinstance(value, str):
        return _INVALID_TEXT.sub("", value)
    if isinstance(value, dict):
        return {k: _sanitize(v) for k, v in value.items()}
    if isinstance(value, list):
        return [_sanitize(v) for v in value]
    return value


class PhoenixClient:
    def __init__(self) -> None:
        settings = get_settings()
        self.base_url = settings.phoenix_api_url.rstrip("/")
        self.headers = {"authorization": f"Bearer {settings.worker_auth_token}"}

    async def _post(self, path: str, payload: dict[str, Any]) -> dict[str, Any] | None:
        try:
            async with httpx.AsyncClient(timeout=15) as client:
                response = await client.post(
                    f"{self.base_url}{path}", json=_sanitize(payload), headers=self.headers
                )
                response.raise_for_status()
                if response.content:
                    return response.json()
                return None
        except httpx.HTTPError as exc:
            log.warning("phoenix_request_failed", path=path, error=str(exc))
            return None

    # ---------- Run lifecycle callbacks ----------

    async def update_run_status(
        self, run_id: str, status: str, extra: dict[str, Any] | None = None
    ) -> None:
        await self._post(
            f"/api/worker/runs/{run_id}/status",
            {"status": status, **(extra or {})},
        )

    async def update_run_plan(self, run_id: str, todos: list[dict[str, Any]]) -> None:
        """Pushes the deep agent's live todo plan so the UI can render a
        real-time checklist (stored on the run's `steps` field)."""
        await self._post(
            f"/api/worker/runs/{run_id}/status",
            {"status": "running", "steps": todos},
        )

    async def request_approval(
        self,
        run_id: str,
        tool: str,
        tool_input: dict[str, Any],
        risk: str,
        proposed_action: str | None = None,
    ) -> dict[str, Any] | None:
        # Field names match Mokaid.Tasks.TaskApprovalRequest; the legacy
        # tool/input/risk keys are kept for older API builds.
        return await self._post(
            f"/api/worker/runs/{run_id}/approval",
            {
                "tool_name": tool,
                "input_payload": tool_input,
                "risk_level": risk,
                "proposed_action": proposed_action,
                "tool": tool,
                "input": tool_input,
                "risk": risk,
            },
        )

    async def complete_run(
        self,
        run_id: str,
        output: dict[str, Any],
        token_usage: dict[str, int] | None = None,
        cost_cents: int = 0,
    ) -> None:
        await self._post(
            f"/api/worker/runs/{run_id}/complete",
            {"output": output, "token_usage": token_usage or {}, "cost_cents": cost_cents},
        )

    async def fail_run(self, run_id: str, error: str) -> None:
        await self._post(f"/api/worker/runs/{run_id}/fail", {"error": error})

    # ---------- Workspace resources ----------

    async def search_knowledge(
        self,
        workspace_id: str,
        embedding: list[float],
        query: str,
        limit: int = 5,
        project_id: str | None = None,
        agent_id: str | None = None,
    ) -> list[dict[str, Any]]:
        """Semantic search over knowledge chunks (pgvector on the Phoenix
        side). Retrieval spans the general knowledge base plus, when given,
        the current project's and agent's own knowledge."""
        result = await self._post(
            "/api/worker/knowledge/search",
            {
                "workspace_id": workspace_id,
                "embedding": embedding,
                "query": query,
                "limit": limit,
                "project_id": project_id,
                "agent_id": agent_id,
            },
        )
        return (result or {}).get("data", [])

    async def post_knowledge_chunks(
        self, knowledge_item_id: str, workspace_id: str, chunks: list[dict[str, Any]]
    ) -> bool:
        """Stores embedded chunks for a knowledge item and marks it indexed."""
        result = await self._post(
            f"/api/worker/knowledge/{knowledge_item_id}/chunks",
            {"workspace_id": workspace_id, "chunks": chunks},
        )
        return result is not None

    async def update_task(
        self, workspace_id: str, task_id: str, attrs: dict[str, Any]
    ) -> dict[str, Any] | None:
        result = await self._post(
            f"/api/worker/tasks/{task_id}/update",
            {"workspace_id": workspace_id, **attrs},
        )
        return (result or {}).get("data")

    async def post_task_comment(
        self,
        workspace_id: str,
        task_id: str,
        body: str,
        agent_id: str | None = None,
    ) -> bool:
        """Posts a task comment authored by the agent (conversational replies)."""
        payload: dict[str, Any] = {"workspace_id": workspace_id, "body": body}
        if agent_id:
            payload["agent_id"] = agent_id
        result = await self._post(f"/api/worker/tasks/{task_id}/comment", payload)
        return result is not None

    async def post_agent_chat_message(
        self,
        workspace_id: str,
        agent_id: str,
        body: str,
        start_task: bool = False,
        instruction: str | None = None,
        member_id: str | None = None,
    ) -> bool:
        """Posts the agent's reply in its direct chat thread (floating dock).

        When ``start_task`` is set, Phoenix also spins up a task assigned to
        this agent from ``instruction`` (member_id = who to attribute it to)."""
        payload: dict[str, Any] = {"workspace_id": workspace_id, "body": body}
        if start_task and instruction:
            payload["start_task"] = True
            payload["instruction"] = instruction
            if member_id:
                payload["member_id"] = member_id
        result = await self._post(
            f"/api/worker/agents/{agent_id}/chat-message", payload
        )
        return result is not None

    async def stream_agent_chat_chunk(
        self,
        workspace_id: str,
        agent_id: str,
        stream_id: str,
        chunk: str,
        done: bool = False,
    ) -> None:
        """Relays a live delta of the agent's in-progress DM reply. Phoenix
        broadcasts `agent_chat.chunk` so the dock renders a typewriter draft."""
        await self._post(
            f"/api/worker/agents/{agent_id}/chat-stream",
            {
                "workspace_id": workspace_id,
                "stream_id": stream_id,
                "chunk": chunk,
                "done": done,
            },
        )

    async def create_subtasks(
        self, workspace_id: str, task_id: str, subtasks: list[dict[str, Any]]
    ) -> list[dict[str, Any]]:
        result = await self._post(
            f"/api/worker/tasks/{task_id}/subtasks",
            {"workspace_id": workspace_id, "subtasks": subtasks},
        )
        return (result or {}).get("data", [])

    async def save_agent_memory(
        self,
        workspace_id: str,
        agent_id: str,
        title: str,
        content: str,
    ) -> bool:
        """Stores a mission memory as agent-scoped knowledge (vectorized by
        the Phoenix ingestion pipeline) — the agent literally learns."""
        result = await self._post(
            f"/api/worker/agents/{agent_id}/memory",
            {"workspace_id": workspace_id, "title": title, "content": content},
        )
        return result is not None

    async def save_task_output(
        self,
        workspace_id: str,
        task_id: str,
        filename: str,
        content: str,
        mime_type: str | None = None,
        encoding: str | None = None,
    ) -> dict[str, Any] | None:
        """Persists an agent-produced artifact as a Drive file linked to the task."""
        payload: dict[str, Any] = {
            "workspace_id": workspace_id,
            "filename": filename,
            "content": content,
            "mime_type": mime_type,
        }
        if encoding:
            payload["encoding"] = encoding
        result = await self._post(f"/api/worker/tasks/{task_id}/output", payload)
        return (result or {}).get("data")
