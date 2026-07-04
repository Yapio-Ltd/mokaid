"""HTTP callbacks to the Phoenix API worker endpoints."""

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

    async def _post(self, path: str, payload: dict[str, Any]) -> None:
        try:
            async with httpx.AsyncClient(timeout=10) as client:
                response = await client.post(
                    f"{self.base_url}{path}", json=payload, headers=self.headers
                )
                response.raise_for_status()
        except httpx.HTTPError as exc:
            log.warning("phoenix_callback_failed", path=path, error=str(exc))

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

    async def complete_run(self, run_id: str, output: dict[str, Any]) -> None:
        await self._post(f"/api/worker/runs/{run_id}/complete", {"output": output})

    async def fail_run(self, run_id: str, error: str) -> None:
        await self._post(f"/api/worker/runs/{run_id}/fail", {"error": error})
