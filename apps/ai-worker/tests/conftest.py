from typing import Any

import pytest


class FakePhoenixClient:
    """Records callbacks instead of making HTTP requests."""

    def __init__(self) -> None:
        self.calls: list[tuple[str, dict[str, Any]]] = []

    async def update_run_status(self, run_id: str, status: str, extra: dict | None = None) -> None:
        self.calls.append(("status", {"run_id": run_id, "status": status}))

    async def request_approval(self, run_id: str, tool: str, tool_input: dict, risk: str) -> None:
        self.calls.append(("approval", {"run_id": run_id, "tool": tool, "risk": risk}))

    async def complete_run(self, run_id: str, output: dict) -> None:
        self.calls.append(("complete", {"run_id": run_id, "output": output}))

    async def fail_run(self, run_id: str, error: str) -> None:
        self.calls.append(("fail", {"run_id": run_id, "error": error}))


@pytest.fixture
def phoenix() -> FakePhoenixClient:
    return FakePhoenixClient()
