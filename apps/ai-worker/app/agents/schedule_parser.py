"""Natural-language → cron schedule parsing for agent automations.

"Every Monday 9am, prepare the weekly report" becomes a structured
schedule (name, 5-field cron, prompt) that Phoenix persists in
agent_schedules. Timezones are fixed UTC offsets ("+02:00") because the
API has no IANA tz database.
"""

import re
from datetime import UTC, datetime
from typing import Any

import structlog

from app import llm

log = structlog.get_logger()

_CRON_FIELD = r"[\d\*\/\-,]+"
_CRON_RE = re.compile(rf"^{_CRON_FIELD}\s+{_CRON_FIELD}\s+{_CRON_FIELD}\s+{_CRON_FIELD}\s+{_CRON_FIELD}$")

_SYSTEM = """You convert a natural-language automation request for an AI employee into a recurring schedule.

Respond with a JSON object:
{{
  "name": "short automation name (max 8 words, same language as the request)",
  "cron_expression": "standard 5-field cron (minute hour day-of-month month day-of-week)",
  "timezone": "fixed UTC offset like \\"+02:00\\", or \\"+00:00\\" when unspecified",
  "prompt": "the full mission brief the agent will execute each time, written as a clear instruction, same language as the request",
  "human_readable": "one short sentence describing the recurrence, same language as the request"
}}

Rules:
- The cron uses numeric fields only (day-of-week: 0=Sunday … 6=Saturday).
- "every morning" → 9:00; "every evening" → 18:00; unspecified time of day → 9:00.
- Never use step values finer than every 15 minutes ("*/5 * * * *" is too frequent → use "*/15").
- The prompt must be self-contained: the agent receives ONLY the prompt, with no memory of this conversation.
- Today is {today}."""


def is_available() -> bool:
    return llm.is_configured()


async def parse(payload: dict[str, Any]) -> dict[str, Any]:
    text = str(payload.get("text") or "").strip()
    if not text:
        return {"error": "empty_request"}

    agent = payload.get("agent") or {}
    context = ""
    if agent.get("display_name"):
        context = (
            f"\nThe automation is for {agent['display_name']}"
            f" ({agent.get('role_title') or 'AI employee'})."
        )

    result = await llm.chat_json(
        _SYSTEM.format(today=datetime.now(UTC).strftime("%A %Y-%m-%d")),
        f"Automation request:{context}\n\n{text}",
        max_tokens=700,
    )

    cron = str(result.get("cron_expression") or "").strip()
    if not _CRON_RE.match(cron):
        log.warning("schedule_parse_bad_cron", cron=cron, text=text[:120])
        return {"error": "unparseable"}

    return {
        "name": str(result.get("name") or "Automation")[:200],
        "cron_expression": cron,
        "timezone": str(result.get("timezone") or "+00:00")[:16],
        "prompt": str(result.get("prompt") or text)[:4000],
        "human_readable": str(result.get("human_readable") or "")[:300],
    }
