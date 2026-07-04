"""Tool registry for agent runs.

Each tool is an async callable taking a dict input and returning a JSON-safe
result. Real integrations (email provider, social APIs, ...) are stubbed for
now; the registry shape, risk levels and approval gating are final.
"""

from collections.abc import Awaitable, Callable
from typing import Any

ToolFn = Callable[[dict[str, Any]], Awaitable[Any]]

_REGISTRY: dict[str, ToolFn] = {}


def tool(name: str) -> Callable[[ToolFn], ToolFn]:
    def decorator(fn: ToolFn) -> ToolFn:
        _REGISTRY[name] = fn
        return fn

    return decorator


def get_tool(name: str) -> ToolFn | None:
    return _REGISTRY.get(name)


def list_tools() -> list[str]:
    return sorted(_REGISTRY)


@tool("search_knowledge")
async def search_knowledge(params: dict[str, Any]) -> Any:
    query = params.get("query", "")
    return {"results": [], "query": query, "note": "knowledge search stub — wired to pgvector via API"}


@tool("summarize")
async def summarize(params: dict[str, Any]) -> Any:
    text = params.get("text", "")
    return {"summary": text[:280], "truncated": len(text) > 280}


@tool("draft_document")
async def draft_document(params: dict[str, Any]) -> Any:
    return {
        "title": params.get("title", "Untitled draft"),
        "content": f"# {params.get('title', 'Draft')}\n\n(Generated draft placeholder)",
    }


@tool("generate_report")
async def generate_report(params: dict[str, Any]) -> Any:
    return {"report": {"period": params.get("period", "last_30_days"), "sections": []}}


@tool("update_task")
async def update_task(params: dict[str, Any]) -> Any:
    return {"updated": True, "task_id": params.get("task_id")}


@tool("create_subtasks")
async def create_subtasks(params: dict[str, Any]) -> Any:
    return {"created": params.get("subtasks", [])}


@tool("send_email")
async def send_email(params: dict[str, Any]) -> Any:
    # Only reached after human approval (HIGH risk).
    return {"sent": True, "to": params.get("to"), "subject": params.get("subject")}


@tool("post_social")
async def post_social(params: dict[str, Any]) -> Any:
    return {"posted": True, "network": params.get("network"), "preview": params.get("content", "")[:100]}
