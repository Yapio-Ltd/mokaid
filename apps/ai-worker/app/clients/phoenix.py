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

    async def _post(
        self, path: str, payload: dict[str, Any], timeout: float = 15
    ) -> dict[str, Any] | None:
        try:
            async with httpx.AsyncClient(timeout=timeout) as client:
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

    async def report_usage(
        self,
        workspace_id: str,
        source: str,
        cost_cents: int,
        token_usage: dict[str, int] | None = None,
        agent_id: str | None = None,
    ) -> None:
        """Meters LLM usage outside of runs (chat replies, ingestion) so
        Phoenix records it and charges the workspace's AI credits.

        source ∈ {"converse", "agent_chat", "knowledge_ingest"} (whitelisted
        server-side)."""
        if cost_cents <= 0 and not token_usage:
            return
        await self._post(
            "/api/worker/usage",
            {
                "workspace_id": workspace_id,
                "source": source,
                "cost_cents": cost_cents,
                "token_usage": token_usage or {},
                "agent_id": agent_id,
            },
        )

    # ---------- Workspace resources ----------


    async def load_domain_skill(
        self,
        workspace_id: str,
        agent_id: str | None,
        name: str,
        archetype: str | None = None,
    ) -> dict[str, Any]:
        """Load a domain-pack skill body for progressive disclosure."""
        result = await self._post(
            "/api/worker/agents/domain-skill",
            {
                "workspace_id": workspace_id,
                "agent_id": agent_id,
                "name": name,
                "archetype": archetype,
            },
        )
        return (result or {}).get("data") or result or {}

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
        self,
        knowledge_item_id: str,
        workspace_id: str,
        chunks: list[dict[str, Any]],
        graph: dict[str, Any] | None = None,
    ) -> bool:
        """Stores embedded chunks (and optional graph) for a knowledge item."""
        payload: dict[str, Any] = {"workspace_id": workspace_id, "chunks": chunks}
        if graph:
            payload["graph"] = graph
        result = await self._post(
            f"/api/worker/knowledge/{knowledge_item_id}/chunks",
            payload,
        )
        return result is not None

    async def traverse_knowledge(
        self,
        workspace_id: str,
        query: str,
        project_id: str | None = None,
        agent_id: str | None = None,
        limit: int = 40,
    ) -> dict[str, Any]:
        result = await self._post(
            "/api/worker/knowledge/traverse",
            {
                "workspace_id": workspace_id,
                "query": query,
                "project_id": project_id,
                "agent_id": agent_id,
                "limit": limit,
            },
        )
        return (result or {}).get("data", {})

    async def knowledge_path(
        self,
        workspace_id: str,
        from_query: str,
        to_query: str,
        project_id: str | None = None,
        agent_id: str | None = None,
    ) -> dict[str, Any]:
        result = await self._post(
            "/api/worker/knowledge/path",
            {
                "workspace_id": workspace_id,
                "from": from_query,
                "to": to_query,
                "project_id": project_id,
                "agent_id": agent_id,
            },
        )
        return (result or {}).get("data", {})

    async def explain_concept(
        self,
        workspace_id: str,
        query: str,
        project_id: str | None = None,
        agent_id: str | None = None,
    ) -> dict[str, Any]:
        result = await self._post(
            "/api/worker/knowledge/explain",
            {
                "workspace_id": workspace_id,
                "query": query,
                "project_id": project_id,
                "agent_id": agent_id,
            },
        )
        return (result or {}).get("data", {})

    async def save_graph_outcome(
        self,
        workspace_id: str,
        *,
        outcome: str,
        question: str | None = None,
        answer_summary: str | None = None,
        node_ids: list[str] | None = None,
        agent_id: str | None = None,
        task_id: str | None = None,
    ) -> dict[str, Any] | None:
        result = await self._post(
            "/api/worker/knowledge/outcomes",
            {
                "workspace_id": workspace_id,
                "outcome": outcome,
                "question": question,
                "answer_summary": answer_summary,
                "node_ids": node_ids or [],
                "agent_id": agent_id,
                "task_id": task_id,
            },
        )
        return (result or {}).get("data")

    async def mark_knowledge_failed(
        self, knowledge_item_id: str, workspace_id: str, error: str
    ) -> bool:
        """Marks a knowledge item's indexing as failed (unreadable file…)."""
        result = await self._post(
            f"/api/worker/knowledge/{knowledge_item_id}/failed",
            {"workspace_id": workspace_id, "error": error},
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
        message_id: str | None = None,
        attachments: list[dict[str, Any]] | None = None,
        skip_ack: bool = False,
        language: str | None = None,
        stream_id: str | None = None,
    ) -> bool:
        """Posts the agent's reply in its direct chat thread (floating dock).

        When ``start_task`` is set, Phoenix also spins up a task assigned to
        this agent from ``instruction`` (member_id = who to attribute it to).
        ``skip_ack`` avoids a second boilerplate "On it" when the worker already
        streamed a personalized acknowledgement.
        """
        payload: dict[str, Any] = {"workspace_id": workspace_id, "body": body}
        if start_task and instruction:
            payload["start_task"] = True
            payload["instruction"] = instruction
            if member_id:
                payload["member_id"] = member_id
            if message_id:
                payload["message_id"] = message_id
            if attachments:
                payload["attachments"] = attachments
            if skip_ack:
                payload["skip_ack"] = True
        if language:
            payload["language"] = language
        if stream_id:
            payload["stream_id"] = stream_id
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
        # HTML landings are large — give the upload more than the default 15s.
        result = await self._post(
            f"/api/worker/tasks/{task_id}/output", payload, timeout=60
        )
        return (result or {}).get("data")
