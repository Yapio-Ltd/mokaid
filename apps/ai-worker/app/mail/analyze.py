"""LLM analysis of incoming email.

Each new message gets an importance score, a category, a one-line summary
and a match verdict against the workspace's natural-language rules
("notify me about invoices", "flag anything from my accountant").
"""

from datetime import UTC, datetime
from typing import Any

import structlog

from app import llm
from app.llm import UsageTracker

log = structlog.get_logger()

_CATEGORIES = [
    "urgent",
    "work",
    "finance",
    "invoice",
    "meeting",
    "personal",
    "newsletter",
    "notification",
    "marketing",
    "other",
]

_SYSTEM = """You are an executive email triage assistant. Analyze the email and respond with a JSON object:
{{
  "importance": <integer 0-100 — how much this email deserves the owner's immediate attention. 90+: urgent action needed (deadline, security alert, boss/client escalation). 70-89: important, respond soon (real invoices, meeting changes, direct questions). 40-69: useful but not pressing. <40: newsletters, marketing, automated notifications>,
  "category": one of {categories},
  "summary": "one sentence (max 25 words) capturing what the email is about and any required action, in the email's language",
  "matched_rule_ids": [ids of the user rules below that this email clearly satisfies — empty list when none apply]
}}

User rules (id — description):
{rules}

Only match a rule when the email genuinely satisfies its intent, not on keyword coincidence."""


def is_available() -> bool:
    return llm.is_configured()


async def analyze_messages(
    messages: list[dict[str, Any]],
    rules: list[dict[str, Any]],
    usage: UsageTracker | None = None,
) -> list[dict[str, Any]]:
    """Annotates each message in-place with ai_* fields. Analysis failures
    leave the message unannotated rather than blocking ingestion."""
    if not is_available():
        return messages

    rules_text = "\n".join(f"- {rule['id']} — {rule['prompt']}" for rule in rules) or "- (no rules)"
    system = _SYSTEM.format(categories=_CATEGORIES, rules=rules_text)
    valid_rule_ids = {rule["id"] for rule in rules}

    for message in messages:
        try:
            result = await llm.chat_json(
                system,
                _render_email(message),
                usage=usage,
                max_tokens=400,
                quality="fast",
            )
            _apply(message, result, valid_rule_ids)
        except Exception as exc:
            log.warning(
                "mail_analysis_failed",
                message_id=message.get("provider_message_id"),
                error=str(exc),
            )

    return messages


def _render_email(message: dict[str, Any]) -> str:
    body = (message.get("body_text") or message.get("snippet") or "")[:2000]
    return (
        f"From: {message.get('from_name') or ''} <{message.get('from_email') or ''}>\n"
        f"Subject: {message.get('subject') or '(no subject)'}\n"
        f"Date: {message.get('received_at') or ''}\n\n"
        f"{body}"
    )


def _apply(message: dict[str, Any], result: dict[str, Any], valid_rule_ids: set) -> None:
    importance = result.get("importance")
    if isinstance(importance, (int, float)):
        message["ai_importance"] = max(0, min(100, int(importance)))

    category = str(result.get("category") or "").lower()
    if category in _CATEGORIES:
        message["ai_category"] = category

    summary = str(result.get("summary") or "").strip()
    if summary:
        message["ai_summary"] = summary[:500]

    matched = result.get("matched_rule_ids")
    if isinstance(matched, list):
        message["matched_rule_ids"] = [rule_id for rule_id in matched if rule_id in valid_rule_ids]

    message["analyzed_at"] = datetime.now(UTC).isoformat()
