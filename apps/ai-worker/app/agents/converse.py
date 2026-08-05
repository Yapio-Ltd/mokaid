"""Conversational replies outside of runs.

When a teammate writes in a task thread while the agent is idle, the agent
answers in character: acknowledging instructions, answering questions about
its work, or asking for what it needs. If the human's message contains new
actionable instructions, the reply invites them to relaunch the mission
(the run input carries the whole thread).
"""

from typing import Any

import structlog

from app import llm
from app.clients.phoenix import PhoenixClient

log = structlog.get_logger()

_SYSTEM = """You are an AI agent teammate inside a team workspace, chatting in a
task thread. Your teammate just wrote to you while you are NOT currently
working on the task. Write your next chat message (1-4 sentences, first
person, warm and professional, no markdown, same language as the teammate).

Guidelines:
- Answer their question or acknowledge their instruction concretely.
- If they gave you new work instructions, confirm what you'll do and remind
  them you'll apply it as soon as the mission is (re)launched.
- If you need something (a file, a clarification), ask for it plainly.
- Never invent results you haven't produced. Never repeat your previous
  message.
"""


async def converse(payload: dict[str, Any], phoenix: PhoenixClient | None = None) -> bool:
    """Generates the agent's chat reply and posts it as a task comment."""
    if not llm.is_configured():
        return False

    phoenix = phoenix or PhoenixClient()
    conversation = payload.get("conversation") or []
    usage = llm.UsageTracker()
    thread = "\n".join(
        f"- {entry.get('author', '?')}: {entry.get('body', '')}"
        for entry in conversation[-10:]
        if isinstance(entry, dict)
    )

    try:
        reply = await llm.chat(
            system=_SYSTEM,
            user=(
                f"Task title: {payload.get('task_title') or 'Untitled'}\n"
                f"Task description: {payload.get('task_description') or '(none)'}\n"
                f"Task status: {payload.get('task_status') or 'unknown'}\n"
                f"Thread (most recent last — reply to the last human message):\n{thread}"
            ),
            usage=usage,
            max_tokens=300,
        )
    except Exception as exc:  # noqa: BLE001 — a missing reply is acceptable
        log.warning("converse_llm_failed", error=str(exc))
        return False

    await phoenix.report_usage(
        payload["workspace_id"],
        "converse",
        usage.cost_cents,
        token_usage=usage.as_dict(),
        agent_id=payload.get("agent_id"),
    )

    reply = (reply or "").strip()
    if not reply:
        return False

    posted = await phoenix.post_task_comment(
        payload["workspace_id"],
        payload["task_id"],
        reply,
        agent_id=payload.get("agent_id"),
    )
    if posted:
        log.info("converse_replied", task_id=payload["task_id"])
    return posted
