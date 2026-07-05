"""HTTP client for the Phoenix API worker endpoints (callbacks + resources)."""

from typing import Any

import httpx
import structlog

from app.config import get_settings

log = structlog.get_logger()


class PhoenixClient:
    def __init__(self) -> None:
        settings = get_settings()
        self.base_url = settings.phoenix_api_url.rstrip("/")
        self.headers = {"authorization": f"Bearer {settings.worker_auth_token}"}

    async def _post(self, path: str, payload: dict[str, Any]) -> dict[str, Any] | None:
        try:
            async with httpx.AsyncClient(timeout=15) as client:
                response = await client.post(
                    f"{self.base_url}{path}", json=payload, headers=self.headers
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

    async def request_approval(
        self, run_id: str, tool: str, tool_input: dict[str, Any], risk: str
    ) -> None:
        await self._post(
            f"/api/worker/runs/{run_id}/approval",
            {"tool": tool, "input": tool_input, "risk": risk},
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
        self, workspace_id: str, embedding: list[float], query: str, limit: int = 5
    ) -> list[dict[str, Any]]:
        """Semantic search over knowledge chunks (pgvector on the Phoenix side)."""
        result = await self._post(
            "/api/worker/knowledge/search",
            {
                "workspace_id": workspace_id,
                "embedding": embedding,
                "query": query,
                "limit": limit,
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

    async def create_subtasks(
        self, workspace_id: str, task_id: str, subtasks: list[dict[str, Any]]
    ) -> list[dict[str, Any]]:
        result = await self._post(
            f"/api/worker/tasks/{task_id}/subtasks",
            {"workspace_id": workspace_id, "subtasks": subtasks},
        )
        return (result or {}).get("data", [])
