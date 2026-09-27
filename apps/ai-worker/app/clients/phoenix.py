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

    async def mail_tool(
        self, access_token: str, action: str, arguments: dict[str, Any],
        *, acting_agent_id: str | None = None, allow_refresh: bool = False,
    ) -> dict[str, Any]:
        """Private Mail bridge. Credentials and raw transport errors never become tool output."""
        if not access_token or action not in {"list", "search", "read", "save_attachment"}:
            return {"error": "mail_access_unavailable"}
        operation = {"access_token": access_token, "action": action,
                     "arguments": _sanitize(arguments), "acting_agent_id": acting_agent_id}
        active_token = access_token
        try:
            async with httpx.AsyncClient(timeout=60, follow_redirects=False) as client:
                response = await client.post(
                    f"{self.base_url}/api/worker/mail/tools",
                    json=operation,
                    headers=self.headers,
                )
                if response.status_code == 403 and allow_refresh:
                    # Only persisted execution contexts opt in. The API verifies
                    # the original signed scope and all current rights; no actor
                    # or operation can be broadened by this single renewal.
                    refreshed = await client.post(
                        f"{self.base_url}/api/worker/mail/refresh",
                        json={"access_token": access_token, "action": action,
                              "acting_agent_id": acting_agent_id},
                        headers=self.headers,
                    )
                    if refreshed.status_code in {401, 403}:
                        return {"error": "mail_access_denied"}
                    if refreshed.status_code != 200 or len(refreshed.content) > 20000:
                        return {"error": "mail_service_unavailable"}
                    renewal = refreshed.json()
                    data = renewal.get("data") if isinstance(renewal, dict) else None
                    token = data.get("token") if isinstance(data, dict) else None
                    if not isinstance(token, str) or not token.strip() or len(token) > 16384:
                        return {"error": "mail_service_unavailable"}
                    active_token = token
                    response = await client.post(
                        f"{self.base_url}/api/worker/mail/tools",
                        json={**operation, "access_token": active_token}, headers=self.headers,
                    )
            if response.status_code in {401, 403}:
                return {"error": "mail_access_denied"}
            if response.status_code == 404:
                return {"error": "mail_item_unavailable"}
            if response.status_code == 422:
                return {"error": "invalid_mail_arguments"}
            if response.status_code == 409:
                return {"error": "mail_reconnect_required"}
            if response.status_code == 413:
                return {"error": "mail_attachment_too_large"}
            if response.status_code == 429:
                return {"error": "mail_rate_limited"}
            if not 200 <= response.status_code < 300 or len(response.content) > 2 * 1024 * 1024:
                return {"error": "mail_service_unavailable"}
            result = response.json()
            if not isinstance(result, dict) or not isinstance(result.get("data"), dict):
                return {"error": "mail_service_unavailable"}
            def private(value: Any) -> Any:
                if isinstance(value, str):
                    return value.replace(access_token, "[redacted]").replace(active_token, "[redacted]")
                if isinstance(value, list):
                    return [private(item) for item in value]
                if isinstance(value, dict):
                    return {private(key): private(item) for key, item in value.items()}
                return value

            return private(result["data"])
        except (httpx.HTTPError, ValueError, TypeError):
            return {"error": "mail_service_unavailable"}

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

    async def post_tool_activity(self, run_id: str, event: dict[str, Any]) -> None:
        """Streams one tool-activity event (start/end of a tool call with a
        human description) so the UI can render a live run timeline."""
        await self._post(f"/api/worker/runs/{run_id}/tool-activity", {"event": event})

    async def request_approval(
        self,
        run_id: str,
        tool: str,
        tool_input: dict[str, Any],
        risk: str,
        proposed_action: str | None = None,
        operation_key: str | None = None,
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
                "operation_key": operation_key,
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

    async def runtime_call(
        self, run_id: str, workspace_id: str, action: str, **payload: Any
    ) -> dict[str, Any]:
        """Fail closed for managed-runtime authority and accounting callbacks."""
        async with httpx.AsyncClient(timeout=20) as client:
            response = await client.post(
                f"{self.base_url}/api/worker/runs/{run_id}/runtime/{action}",
                json=_sanitize({**payload, "workspace_id": workspace_id}), headers=self.headers,
            )
            result = response.json()
            if response.status_code >= 500:
                raise RuntimeError("Mokaid runtime authority is unavailable.")
        if not isinstance(result, dict) or not isinstance(result.get("data"), dict):
            raise RuntimeError("Mokaid runtime authority is unavailable.")
        return result["data"]

    async def finalize_runtime(
        self, run_id: str, status: str, output: dict[str, Any], cost_cents: int = 0
    ) -> None:
        """Terminal delivery must be acknowledged before remote state is deleted."""
        suffix = "complete" if status == "completed" else "status"
        payload = {"status": status, "output": output, "cost_cents": cost_cents}
        async with httpx.AsyncClient(timeout=30) as client:
            response = await client.post(
                f"{self.base_url}/api/worker/runs/{run_id}/{suffix}",
                json=_sanitize(payload), headers=self.headers,
            )
            response.raise_for_status()

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

    # ---------- Mail sync ----------

    async def ingest_mail_messages(self, account_id: str, messages: list[dict[str, Any]]) -> bool:
        """Posts a batch of normalized + analyzed messages for one account."""
        result = await self._post(
            f"/api/worker/mail/accounts/{account_id}/messages",
            {"messages": messages},
            timeout=60,
        )
        return result is not None

    async def update_mail_sync_state(self, account_id: str, attrs: dict[str, Any]) -> bool:
        """Reports sync cursors, push-channel expiry and error status."""
        result = await self._post(f"/api/worker/mail/accounts/{account_id}/sync-state", attrs)
        return result is not None

    async def fetch_mail_credentials(self, account_id: str) -> dict[str, Any] | None:
        """Fetches a fresh account payload (Phoenix refreshes OAuth tokens)."""
        result = await self._post(f"/api/worker/mail/accounts/{account_id}/credentials", {})
        return (result or {}).get("data")

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

    async def apply_task_followup(
        self,
        workspace_id: str,
        task_id: str,
        comment_id: str,
        *,
        agent_id: str | None,
        kind: str,
        reply: str = "",
        language: str = "en",
    ) -> dict[str, Any] | None:
        """Apply an anchored task-thread decision; Phoenix authorizes/deduplicates."""
        result = await self._post(
            f"/api/worker/tasks/{task_id}/followup",
            {
                "workspace_id": workspace_id,
                "comment_id": comment_id,
                "agent_id": agent_id,
                "kind": kind,
                "reply": reply,
                "language": language,
            },
        )
        return (result or {}).get("data")

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
        conversation_id: str | None = None,
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
        if conversation_id:
            payload["conversation_id"] = conversation_id
        result = await self._post(f"/api/worker/agents/{agent_id}/chat-message", payload)
        return result is not None

    async def stream_agent_chat_chunk(
        self,
        workspace_id: str,
        agent_id: str,
        stream_id: str,
        chunk: str,
        done: bool = False,
        conversation_id: str | None = None,
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
                **({"conversation_id": conversation_id} if conversation_id else {}),
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
        artifact_key: str | None = None,
        agent_id: str | None = None,
        run_id: str | None = None,
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
        if artifact_key:
            payload["artifact_key"] = artifact_key
        if run_id:
            payload["run_id"] = run_id
        if agent_id:
            payload["agent_id"] = agent_id
        # HTML landings are large — give the upload more than the default 15s.
        result = await self._post(f"/api/worker/tasks/{task_id}/output", payload, timeout=60)
        return (result or {}).get("data")
