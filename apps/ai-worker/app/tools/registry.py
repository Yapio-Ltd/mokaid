"""Tool registry for agent runs.

Each tool is an async callable receiving its input dict plus the RunContext
(workspace/task ids, Phoenix client, LLM usage tracker). LLM-backed tools
fall back to deterministic output when no OpenAI key is configured, so the
full lifecycle stays testable offline.
"""

from collections.abc import Awaitable, Callable
from dataclasses import dataclass, field
from typing import Any

import structlog

from app import llm

log = structlog.get_logger()


@dataclass
class RunContext:
    run_id: str
    workspace_id: str
    task_id: str
    task_title: str | None = None
    task_description: str | None = None
    phoenix: Any = None  # PhoenixClient (Any to allow fakes in tests)
    usage: llm.UsageTracker = field(default_factory=llm.UsageTracker)


ToolFn = Callable[[dict[str, Any], RunContext], Awaitable[Any]]

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


def _task_context_block(ctx: RunContext) -> str:
    return (
        f"Task title: {ctx.task_title or 'Untitled'}\n"
        f"Task description: {ctx.task_description or '(none)'}"
    )


# ---------- Read-only / internal ----------


@tool("search_knowledge")
async def search_knowledge(params: dict[str, Any], ctx: RunContext) -> Any:
    """Semantic search over the workspace knowledge base (pgvector)."""
    query = params.get("query", "") or ctx.task_title or ""
    if not query:
        return {"results": [], "query": query}

    if not llm.is_configured() or ctx.phoenix is None:
        return {"results": [], "query": query, "note": "search unavailable (no LLM key)"}

    [embedding] = await llm.embed([query], usage=ctx.usage)
    results = await ctx.phoenix.search_knowledge(ctx.workspace_id, embedding, query)
    return {"query": query, "results": results}


@tool("summarize")
async def summarize(params: dict[str, Any], ctx: RunContext) -> Any:
    text = params.get("text", "")
    if not text:
        return {"summary": "", "note": "no text provided"}

    if not llm.is_configured():
        return {"summary": text[:280], "truncated": len(text) > 280, "note": "offline fallback"}

    summary = await llm.chat(
        system=(
            "You are an assistant inside a team workspace. Summarize the provided text "
            "clearly and concisely in the language of the source text. Use short bullet "
            "points when it improves readability."
        ),
        user=f"{_task_context_block(ctx)}\n\nText to summarize:\n{text}",
        usage=ctx.usage,
        max_tokens=600,
    )
    return {"summary": summary}


# ---------- Content generation ----------


@tool("draft_document")
async def draft_document(params: dict[str, Any], ctx: RunContext) -> Any:
    title = params.get("title") or ctx.task_title or "Untitled draft"
    brief = params.get("brief") or ctx.task_description or ""
    knowledge = params.get("context", "")

    if not llm.is_configured():
        return {"title": title, "content": f"# {title}\n\n(offline draft placeholder)"}

    content = await llm.chat(
        system=(
            "You are a professional writer on a product team. Write a well-structured "
            "Markdown document. Be concrete and actionable; avoid filler."
        ),
        user=(
            f"{_task_context_block(ctx)}\n\n"
            f"Document title: {title}\n"
            f"Brief: {brief or '(derive from the task)'}\n"
            + (f"Relevant knowledge:\n{knowledge}\n" if knowledge else "")
        ),
        usage=ctx.usage,
        max_tokens=1800,
    )
    return {"title": title, "content": content}


@tool("generate_report")
async def generate_report(params: dict[str, Any], ctx: RunContext) -> Any:
    period = params.get("period", "last_30_days")

    if not llm.is_configured():
        return {"report": {"period": period, "sections": []}, "note": "offline fallback"}

    report = await llm.chat_json(
        system=(
            "You produce structured JSON work reports. Respond with a JSON object: "
            '{"period": string, "headline": string, "sections": '
            '[{"title": string, "content": string}]}. Keep it factual and grounded '
            "in the task context; do not invent metrics."
        ),
        user=f"{_task_context_block(ctx)}\n\nReporting period: {period}",
        usage=ctx.usage,
        max_tokens=1200,
    )
    return {"report": report}


# ---------- Internal mutations (via Phoenix worker API) ----------


@tool("update_task")
async def update_task(params: dict[str, Any], ctx: RunContext) -> Any:
    attrs = {
        key: params[key] for key in ("status", "progress_percent", "description") if key in params
    }
    if not attrs:
        return {"updated": False, "note": "no updatable fields provided"}
    if ctx.phoenix is None:
        return {"updated": False, "note": "phoenix client unavailable"}

    data = await ctx.phoenix.update_task(ctx.workspace_id, ctx.task_id, attrs)
    return {"updated": data is not None, "task_id": ctx.task_id, "attrs": attrs}


@tool("create_subtasks")
async def create_subtasks(params: dict[str, Any], ctx: RunContext) -> Any:
    subtasks = params.get("subtasks", [])
    if not subtasks:
        return {"created": []}
    if ctx.phoenix is None:
        return {"created": [], "note": "phoenix client unavailable"}

    normalized = [
        {"title": s} if isinstance(s, str) else {"title": s.get("title", "Subtask")}
        for s in subtasks
    ]
    created = await ctx.phoenix.create_subtasks(ctx.workspace_id, ctx.task_id, normalized)
    return {"created": created}


# ---------- External side effects (approval-gated) ----------


@tool("send_email")
async def send_email(params: dict[str, Any], ctx: RunContext) -> Any:
    # Only reached after human approval (HIGH risk). No email provider is
    # connected yet: the send is simulated but the body is really generated.
    to = params.get("to", "")
    subject = params.get("subject") or ctx.task_title or ""
    body = params.get("body", "")

    if not body and llm.is_configured():
        body = await llm.chat(
            system=(
                "You write concise, professional emails. Return only the email body, "
                "no subject line."
            ),
            user=f"{_task_context_block(ctx)}\n\nRecipient: {to}\nSubject: {subject}",
            usage=ctx.usage,
            max_tokens=500,
        )

    log.info("email_simulated", to=to, subject=subject)
    return {"sent": True, "simulated": True, "to": to, "subject": subject, "body": body}


@tool("post_social")
async def post_social(params: dict[str, Any], ctx: RunContext) -> Any:
    network = params.get("network", "unknown")
    content = params.get("content", "")

    if not content and llm.is_configured():
        content = await llm.chat(
            system=(
                f"You write engaging social media posts for {network}. Return only the post text."
            ),
            user=_task_context_block(ctx),
            usage=ctx.usage,
            max_tokens=280,
        )

    log.info("social_post_simulated", network=network)
    return {"posted": True, "simulated": True, "network": network, "content": content[:500]}
