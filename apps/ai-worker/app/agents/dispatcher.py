"""Request triage: routes an instruction (+ dropped files) to the best agent.

Given the workspace roster, connected MCP servers and the wider MCP catalog,
the LLM decides whether an existing agent should take the task, whether a
purpose-built agent is warranted, and which MCP connections would speed the
work up. Phoenix falls back to its own deterministic heuristic when this
module is unavailable (no API key, worker down), so this only implements the
LLM path.
"""

from typing import Any, Literal

import structlog
from pydantic import BaseModel, Field

from app import llm

log = structlog.get_logger()


class DispatchTask(BaseModel):
    title: str = Field(description="Max 80 chars, same language as the instruction.")
    description: str = Field(description="Actionable brief for the agent.")
    priority: Literal["low", "medium", "high", "urgent"] = "medium"


class SkillSpec(BaseModel):
    name: str
    level: int = Field(default=50, ge=0, le=100)


class CustomAgentSpec(BaseModel):
    display_name: str
    role_title: str
    department: str = ""
    skills: list[SkillSpec] = Field(default_factory=list)


class AgentAlternative(BaseModel):
    agent_id: str
    confidence: int = Field(default=0, ge=0, le=100)
    reason: str = ""


class DispatchRecommendation(BaseModel):
    mode: Literal["existing_agent", "custom_agent", "user_choice"]
    agent_id: str | None = None
    confidence: int = Field(default=50, ge=0, le=100)
    reason: str = Field(
        default="", description="1-2 sentences, user-facing, mention the agent by name."
    )
    alternatives: list[AgentAlternative] = Field(default_factory=list)
    custom_agent: CustomAgentSpec | None = None


class McpSuggestion(BaseModel):
    server_key: str
    reason: str = Field(default="", description="User-facing, explain the speedup.")


class DispatchAnalysis(BaseModel):
    """Full triage decision: task framing, agent routing, MCP suggestions."""

    task: DispatchTask
    recommendation: DispatchRecommendation
    mcp_suggestions: list[McpSuggestion] = Field(default_factory=list)


_DISPATCH_SYSTEM = """You are the dispatch coordinator of a team of AI agents inside a
work workspace. A user dropped files and/or typed an instruction. Decide who should
handle it.

Decision rules:
- Match by DOMAIN first, then skills. Building a website / ecommerce / app /
  software is always Engineering/code work — never Legal, Finance, or Sales
  alone, even if the product being sold is furniture, insurance, etc.
- Role titles are decisive: "Software Engineer" beats "Legal Specialist" for
  any site/app/code request; prefer the agent whose role matches the work.
- "existing_agent": one agent clearly has the right skills AND domain for this
  request. Do NOT pick an agent just because they are free or the only option.
  Do NOT propose a custom agent in that case (custom_agent must be null) — do
  not bother the user with a choice they don't need.
- "user_choice": the best agent is a partial fit AND a purpose-built agent
  would genuinely do better. Provide BOTH agent_id and custom_agent.
- "custom_agent": nobody on the roster can do this well — OR the request is too
  vague / off-topic for any specialist (greetings, one-line chat, no clear
  work domain). agent_id must be null, alternatives must be [], and
  custom_agent must be filled with a sensible specialist profile for the
  implied work (use a generalist profile if the domain is unknown).
- Prefer agents with fewer open tasks when skills are comparable.
- confidence reflects skill/domain match AND availability. Vague requests with
  no real specialty match must stay below 45 and use custom_agent.
- mcp_suggestions: at most 3, only when a connection would clearly make the
  work faster or better (e.g. Figma for .fig files, GitHub for code review).
  Suggest servers from the connected list first, then from the catalog.
  An empty list is the right answer for most simple requests.
- Priority: infer from wording (deadlines, "urgent", business impact); default "medium".
"""


def is_available() -> bool:
    return llm.is_configured()


async def analyze(payload: dict[str, Any]) -> dict[str, Any]:
    """Runs the triage prompt. Raises on LLM failure (caller returns 5xx)."""
    usage = llm.UsageTracker()

    files = payload.get("files") or []
    files_block = (
        "\n".join(
            f"- {f.get('name')} ({f.get('mime_type') or 'unknown type'}, "
            f"{f.get('size_bytes') or '?'} bytes)"
            for f in files
        )
        or "(none)"
    )

    agents = payload.get("agents") or []
    agents_block = (
        "\n".join(
            f"- id={a.get('id')} | {a.get('name')} | role: {a.get('role_title') or '-'} | "
            f"dept: {a.get('department') or '-'} | status: {a.get('status')} | "
            f"open tasks: {a.get('open_tasks', 0)} | "
            f"skills: {', '.join(s.get('name', '') for s in (a.get('skills') or [])) or '-'}"
            for a in agents
        )
        or "(no agents yet)"
    )

    connected = payload.get("mcp_connected") or []
    connected_block = (
        "\n".join(f"- {c.get('server_key')}: {c.get('name')} ({c.get('category')})" for c in connected)
        or "(none)"
    )

    available = (payload.get("mcp_available") or [])[:60]
    available_block = (
        "\n".join(
            f"- {s.get('key')}: {s.get('name')} — {(s.get('description') or '')[:100]}"
            for s in available
        )
        or "(none)"
    )

    user_block = (
        f"Instruction: {payload.get('instruction') or '(none — files only)'}\n\n"
        f"Dropped files:\n{files_block}\n\n"
        f"Agent roster:\n{agents_block}\n\n"
        f"MCP servers already connected to the workspace:\n{connected_block}\n\n"
        f"MCP servers available in the catalog (not connected):\n{available_block}"
    )

    # Provider-enforced structured output (Pydantic). chat_json stays as a
    # fallback so a schema hiccup can't take intelligent dispatch down.
    try:
        analysis: DispatchAnalysis = await llm.chat_structured(
            system=_DISPATCH_SYSTEM,
            user=user_block,
            schema=DispatchAnalysis,
            usage=usage,
            max_tokens=900,
        )
        result = analysis.model_dump()
    except Exception as exc:  # noqa: BLE001
        log.warning("dispatch_structured_failed", error=str(exc))
        result = await llm.chat_json(
            system=_DISPATCH_SYSTEM,
            user=user_block,
            usage=usage,
            max_tokens=900,
        )

    log.info(
        "dispatch_analyzed",
        mode=(result.get("recommendation") or {}).get("mode"),
        tokens=usage.as_dict()["total_tokens"],
    )
    return result
