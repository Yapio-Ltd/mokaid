"""Run planning: LLM planner with a deterministic fallback.

With an OpenAI key configured, the plan is produced by the model constrained
to the registered tools. Without a key (offline dev, tests) the deterministic
plans keep the full run/approve/resume lifecycle exercisable.
"""

from typing import Any

import structlog

from app import llm
from app.schemas import RunRequest
from app.tools.registry import list_tools

log = structlog.get_logger()

MAX_PLAN_STEPS = 8

_PLANNER_SYSTEM = """You are the planner for an AI agent working inside a team workspace.
Given a task, produce a short plan of tool calls that accomplishes it.

Respond with a JSON object: {"steps": [{"tool": string, "input": object}]}

Available tools:
- search_knowledge {query}: semantic search in the workspace knowledge base
- summarize {text}: summarize text
- draft_document {title, brief, context}: write a Markdown document
- generate_report {period}: produce a structured work report
- update_task {status, progress_percent, description}: update the current task
- create_subtasks {subtasks: [string]}: break the task into subtasks
- send_email {to, subject, body}: send an email (requires human approval)
- post_social {network, content}: publish a social post (requires human approval)
%(mcp_tools)s
Rules:
- 1 to %(max_steps)d steps, ordered.
- Only use listed tools. Prefer the minimal plan that completes the task.
- Start with search_knowledge when workspace context would help.
- Only include send_email/post_social if the task explicitly asks for it.
- Connected tools (mcp:*) are real external integrations: use one only when the
  task genuinely needs that external system, and pass arguments matching its schema.
"""


def _mcp_tools_block(mcp_tools: list[dict[str, Any]]) -> str:
    if not mcp_tools:
        return ""

    lines = ["", "Connected external tools (via MCP, use the exact name):"]
    for tool in mcp_tools:
        description = (tool.get("description") or "").strip().split("\n")[0][:160]
        lines.append(f"- {tool['name']}: {description} [server: {tool.get('server', '?')}]")
    lines.append("")
    return "\n".join(lines)


def deterministic_plan(request: RunRequest) -> list[dict[str, Any]]:
    """Fixed plans keyed on the requested action (offline fallback)."""
    action = request.input.get("action", "summarize")

    if action == "send_campaign":
        return [
            {"tool": "search_knowledge", "input": {"query": request.task_title or ""}},
            {"tool": "draft_document", "input": {"title": f"Campaign: {request.task_title}"}},
            {
                "tool": "send_email",
                "input": {
                    "to": request.input.get("to", "list:subscribers"),
                    "subject": request.task_title,
                },
            },
        ]
    if action == "report":
        return [
            {
                "tool": "generate_report",
                "input": {"period": request.input.get("period", "last_30_days")},
            },
        ]
    return [
        {"tool": "search_knowledge", "input": {"query": request.task_title or ""}},
        {
            "tool": "summarize",
            "input": {"text": request.task_description or request.task_title or ""},
        },
    ]


async def plan_steps(
    request: RunRequest,
    usage: llm.UsageTracker,
    mcp_tools: list[dict[str, Any]] | None = None,
) -> list[dict[str, Any]]:
    """Returns the ordered tool steps for a run (native + granted MCP tools)."""
    mcp_tools = mcp_tools or []

    if not llm.is_configured():
        return deterministic_plan(request)

    try:
        result = await llm.chat_json(
            system=_PLANNER_SYSTEM
            % {"max_steps": MAX_PLAN_STEPS, "mcp_tools": _mcp_tools_block(mcp_tools)},
            user=(
                f"Task title: {request.task_title or 'Untitled'}\n"
                f"Task description: {request.task_description or '(none)'}\n"
                f"Extra input: {request.input}"
            ),
            usage=usage,
            max_tokens=800,
        )
    except Exception as exc:  # noqa: BLE001 — planner errors fall back, run continues
        log.warning("llm_planner_failed", error=str(exc))
        return deterministic_plan(request)

    known = set(list_tools()) | {tool["name"] for tool in mcp_tools}
    steps = [
        {"tool": step["tool"], "input": step.get("input") or {}}
        for step in result.get("steps", [])
        if isinstance(step, dict) and step.get("tool") in known
    ][:MAX_PLAN_STEPS]

    if not steps:
        log.warning("llm_planner_empty_plan", result=result)
        return deterministic_plan(request)

    log.info("llm_plan_created", steps=[s["tool"] for s in steps])
    return steps
