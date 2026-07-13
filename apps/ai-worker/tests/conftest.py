from typing import Any

import pytest

from app.config import get_settings


@pytest.fixture(autouse=True)
def offline_llm(monkeypatch):
    """Tests never call an LLM provider: force the no-key fallback paths."""
    monkeypatch.setenv("OPENAI_API_KEY", "")
    monkeypatch.setenv("ANTHROPIC_API_KEY", "")
    monkeypatch.setenv("DEEPSEEK_API_KEY", "")
    get_settings.cache_clear()
    yield
    get_settings.cache_clear()


class FakePhoenixClient:
    """Records callbacks instead of making HTTP requests."""

    def __init__(self) -> None:
        self.calls: list[tuple[str, dict[str, Any]]] = []

    async def update_run_status(self, run_id: str, status: str, extra: dict | None = None) -> None:
        self.calls.append(("status", {"run_id": run_id, "status": status}))

    async def request_approval(
        self,
        run_id: str,
        tool: str,
        tool_input: dict,
        risk: str,
        proposed_action: str | None = None,
    ) -> dict[str, Any] | None:
        self.calls.append(
            ("approval", {"run_id": run_id, "tool": tool, "risk": risk, "proposed_action": proposed_action})
        )
        return {"data": {"approval_request_id": "fake-approval", "status": "pending"}}

    async def complete_run(
        self,
        run_id: str,
        output: dict,
        token_usage: dict | None = None,
        cost_cents: int = 0,
    ) -> None:
        self.calls.append(("complete", {"run_id": run_id, "output": output}))

    async def fail_run(self, run_id: str, error: str) -> None:
        self.calls.append(("fail", {"run_id": run_id, "error": error}))

    async def search_knowledge(
        self, workspace_id: str, embedding: list, query: str, limit: int = 5
    ) -> list:
        self.calls.append(("search", {"workspace_id": workspace_id, "query": query}))
        return []

    async def update_task(self, workspace_id: str, task_id: str, attrs: dict) -> dict:
        self.calls.append(("update_task", {"task_id": task_id, "attrs": attrs}))
        return {"id": task_id}

    async def create_subtasks(self, workspace_id: str, task_id: str, subtasks: list) -> list:
        self.calls.append(("subtasks", {"task_id": task_id, "subtasks": subtasks}))
        return subtasks

    async def post_task_comment(
        self, workspace_id: str, task_id: str, body: str, agent_id: str | None = None
    ) -> bool:
        self.calls.append(("comment", {"task_id": task_id, "body": body, "agent_id": agent_id}))
        return True

    async def save_task_output(
        self,
        workspace_id: str,
        task_id: str,
        filename: str,
        content: str,
        mime_type: str | None = None,
        encoding: str | None = None,
    ) -> dict:
        self.calls.append(("output", {"task_id": task_id, "filename": filename}))
        return {
            "id": "fake-drive-item",
            "name": filename,
            "task_id": task_id,
            "mime_type": mime_type or "text/plain",
        }

    async def post_agent_chat_message(
        self, workspace_id: str, agent_id: str, body: str, **kwargs
    ) -> dict:
        self.calls.append(
            ("chat", {"workspace_id": workspace_id, "agent_id": agent_id, "body": body, **kwargs})
        )
        return {"id": "fake-chat-msg"}

    async def stream_agent_chat_chunk(
        self,
        workspace_id: str,
        agent_id: str,
        stream_id: str,
        chunk: str,
        done: bool = False,
    ) -> None:
        self.calls.append(
            (
                "stream",
                {
                    "agent_id": agent_id,
                    "stream_id": stream_id,
                    "chunk": chunk,
                    "done": done,
                },
            )
        )


@pytest.fixture
def phoenix() -> FakePhoenixClient:
    return FakePhoenixClient()
