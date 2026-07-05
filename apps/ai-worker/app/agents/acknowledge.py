"""Conversational acknowledgement posted when an agent picks up a task.

Before planning, the agent assesses whether the task is feasible with the
tools it currently has (native tools + granted MCP tools) and posts a short,
human-sounding comment on the task: either "on it, starting right away" or
"I can't do this kind of task yet, here's why". Failures here never block
the run itself.
"""

from typing import Any

import structlog

from app import llm
from app.clients.phoenix import PhoenixClient
from app.schemas import RunRequest
from app.tools.registry import list_tools

log = structlog.get_logger()

_ACK_SYSTEM = """You are an AI agent teammate inside a team workspace. You were just \
assigned a task. Assess whether you can meaningfully help with it using ONLY the \
capabilities listed below, then write a short reply to your teammate (1-3 sentences, \
warm and professional, first person, no markdown).

Your capabilities:
%(capabilities)s

Respond with a JSON object:
{"feasible": true|false, "reply": string}

Rules:
- If you can help: confirm enthusiastically that you're starting right away and say \
in one clause how you'll approach it.
- If the task clearly requires abilities you don't have (e.g. physical actions, \
phone calls, accessing tools not listed): set feasible to false and explain kindly \
what's missing and what you *can* do instead.
- Reply in the same language as the task.
"""

_NATIVE_CAPABILITIES = [
    "search the workspace knowledge base",
    "summarize and analyze text",
    "draft documents (Markdown)",
    "generate structured work reports",
    "update the task status and progress",
    "break the task into subtasks",
    "send emails (with human approval)",
    "publish social posts (with human approval)",
]


def _fallback_reply(request: RunRequest) -> str:
    title = request.task_title or "this task"
    return f"No problem — I'm starting on \"{title}\" right away. I'll keep you posted here."


async def build_acknowledgement(
    request: RunRequest,
    usage: llm.UsageTracker,
    mcp_tools: list[dict[str, Any]] | None = None,
) -> str:
    """Returns the agent's conversational reply for the assigned task."""
    if not llm.is_configured():
        return _fallback_reply(request)

    capabilities = list(_NATIVE_CAPABILITIES)
    for tool in mcp_tools or []:
        name = tool.get("name", "unknown")
        description = tool.get("description") or ""
        server = tool.get("server") or ""
        suffix = f" (via {server})" if server else ""
        capabilities.append(f"{name}: {description}{suffix}".strip())

    try:
        result = await llm.chat_json(
            system=_ACK_SYSTEM % {"capabilities": "\n".join(f"- {c}" for c in capabilities)},
            user=(
                f"Task title: {request.task_title or 'Untitled'}\n"
                f"Task description: {request.task_description or '(none)'}"
            ),
            usage=usage,
            max_tokens=300,
        )
    except Exception as exc:  # noqa: BLE001 — ack must never break the run
        log.warning("acknowledge_llm_failed", error=str(exc))
        return _fallback_reply(request)

    reply = (result.get("reply") or "").strip()
    if not reply:
        return _fallback_reply(request)
    return reply


async def post_acknowledgement(
    request: RunRequest,
    phoenix: PhoenixClient,
    usage: llm.UsageTracker,
    mcp_tools: list[dict[str, Any]] | None = None,
) -> None:
    """Builds and posts the acknowledgement comment; never raises."""
    try:
        reply = await build_acknowledgement(request, usage, mcp_tools)
        await phoenix.post_task_comment(
            request.workspace_id, request.task_id, reply, agent_id=request.agent_id
        )
        log.info("acknowledgement_posted", run_id=request.run_id, tools=len(list_tools()))
    except Exception as exc:  # noqa: BLE001
        log.warning("acknowledgement_failed", run_id=request.run_id, error=str(exc))
