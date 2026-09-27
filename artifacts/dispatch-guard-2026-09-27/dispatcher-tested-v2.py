"""Request triage: routes an instruction (+ dropped files) to the best agent.

Given the workspace roster, connected MCP servers and the wider MCP catalog,
the LLM decides whether an existing agent should take the task, whether a
purpose-built agent is warranted, and which MCP connections would speed the
work up. Phoenix falls back to its own deterministic heuristic when this
module is unavailable (no API key, worker down), so this only implements the
LLM path.
"""

import json
from typing import Annotated, Any, Literal, Self

import structlog
from pydantic import BaseModel, Field, StringConstraints, ValidationInfo, model_validator

from app import llm

log = structlog.get_logger()

NonEmptyString = Annotated[str, StringConstraints(strip_whitespace=True, min_length=1)]
Confidence = Annotated[int, Field(strict=True, ge=0, le=100)]


class InvalidDispatchAnalysis(ValueError):
    """The model returned an unsafe contract; never substitute a heuristic route."""


class DispatchTask(BaseModel):
    title: NonEmptyString = Field(description="Max 80 chars, same language as the instruction.")
    description: NonEmptyString = Field(description="Actionable brief for the agent.")
    priority: Literal["low", "medium", "high", "urgent"] = "medium"


class SkillSpec(BaseModel):
    name: NonEmptyString
    level: int = Field(default=50, ge=0, le=100)


class CustomAgentSpec(BaseModel):
    display_name: NonEmptyString
    role_title: NonEmptyString
    archetype_key: NonEmptyString = Field(
        description="Exact key from the supplied agent archetypes."
    )
    department: str = ""
    skills: list[SkillSpec] = Field(min_length=1, max_length=8)


class AgentAlternative(BaseModel):
    agent_id: NonEmptyString
    confidence: Confidence = 0
    reason: str = ""


class DispatchRecommendation(BaseModel):
    mode: Literal["existing_agent", "custom_agent", "user_choice"]
    agent_id: NonEmptyString | None = None
    confidence: Confidence
    reason: NonEmptyString = Field(
        description="1-2 sentences, user-facing, mention the agent by name."
    )
    alternatives: list[AgentAlternative] = Field(
        default_factory=list,
        max_length=2,
        description=(
            "Other EXISTING roster agents only, excluding agent_id. Usually []. "
            "Never put the proposed new specialist here or use a null/placeholder ID. "
            "For user_choice the two choices are agent_id and custom_agent, not alternatives."
        ),
    )
    custom_agent: CustomAgentSpec | None = None

    @model_validator(mode="after")
    def coherent_route(self) -> Self:
        if self.mode == "existing_agent":
            if not self.agent_id or self.custom_agent is not None or self.confidence < 45:
                raise ValueError("existing_agent requires a confident agent_id and no custom_agent")
        elif self.mode == "user_choice":
            if not self.agent_id or self.custom_agent is None:
                raise ValueError("user_choice requires both agent_id and a complete custom_agent")
        elif self.custom_agent is None or self.agent_id is not None or self.alternatives:
            raise ValueError(
                "custom_agent requires a complete profile, null agent_id and no alternatives"
            )
        alternative_ids = [alternative.agent_id for alternative in self.alternatives]
        if len(alternative_ids) != len(set(alternative_ids)) or self.agent_id in alternative_ids:
            raise ValueError("alternatives must be distinct and exclude the primary agent")
        return self


class McpSuggestion(BaseModel):
    server_key: NonEmptyString
    reason: str = Field(default="", description="User-facing, explain the speedup.")


class DispatchAnalysis(BaseModel):
    """Full triage decision: task framing, agent routing, MCP suggestions."""

    task: DispatchTask
    recommendation: DispatchRecommendation
    mcp_suggestions: list[McpSuggestion] = Field(default_factory=list, max_length=3)

    @model_validator(mode="after")
    def known_references(self, info: ValidationInfo) -> Self:
        # Provider parsing has no workspace context. The final local validation
        # always supplies it, including for the plain-JSON repair path.
        if info.context is None:
            return self
        rec = self.recommendation
        ids = [alternative.agent_id for alternative in rec.alternatives]
        if rec.agent_id is not None:
            ids.append(rec.agent_id)
        if any(agent_id not in info.context["agent_ids"] for agent_id in ids):
            raise ValueError("agent_id must belong to the supplied roster")
        if (
            rec.custom_agent
            and rec.custom_agent.archetype_key not in info.context["archetype_keys"]
        ):
            raise ValueError("custom_agent.archetype_key must belong to the supplied catalog")
        keys = [suggestion.server_key for suggestion in self.mcp_suggestions]
        if len(keys) != len(set(keys)) or any(key not in info.context["mcp_keys"] for key in keys):
            raise ValueError("MCP suggestions must be distinct keys from the supplied catalog")
        return self


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
- Every custom_agent must include a nonempty display_name, role_title, 1-8 named
  skills and an exact archetype_key from the supplied catalog. Choose the closest
  domain archetype and describe the requested specialization in the role and skills.
  Use the blank archetype only when the work domain is unknown. Never invent a key.
- Agent IDs and alternatives must come from the supplied roster. At most 2
  alternatives, all distinct and different from the selected agent.
  alternatives means OTHER EXISTING employees, not the newly proposed specialist.
  For user_choice, the choice is already represented by agent_id + custom_agent;
  leave alternatives empty unless another existing employee is also suitable.
  Never use null, a name or an invented ID in alternatives.
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
    """Validate triage, with one repair attempt; invalid decisions return 422."""
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

    archetypes = payload.get("agent_archetypes") or []
    archetypes_block = json.dumps(archetypes, ensure_ascii=False)

    connected = payload.get("mcp_connected") or []
    connected_block = (
        "\n".join(
            f"- {c.get('server_key')}: {c.get('name')} ({c.get('category')})" for c in connected
        )
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
        f"Agent archetypes available for creation:\n{archetypes_block}\n\n"
        f"MCP servers already connected to the workspace:\n{connected_block}\n\n"
        f"MCP servers available in the catalog (not connected):\n{available_block}"
    )

    context = {
        "agent_ids": {agent["id"] for agent in agents if agent.get("id")},
        "archetype_keys": {archetype["key"] for archetype in archetypes if archetype.get("key")},
        "mcp_keys": {server["server_key"] for server in connected if server.get("server_key")}
        | {server["key"] for server in available if server.get("key")},
    }

    def validate(value: Any) -> dict[str, Any]:
        # Re-validate model objects as data too: provider schemas alone do not
        # enforce the roster/catalog constraints or guarantee validated instances.
        if isinstance(value, BaseModel):
            value = value.model_dump(warnings=False)
        return DispatchAnalysis.model_validate(value, context=context).model_dump()

    invalid_response = False
    try:
        analysis = await llm.chat_structured(
            system=_DISPATCH_SYSTEM,
            user=user_block,
            schema=DispatchAnalysis,
            usage=usage,
            max_tokens=900,
        )
        invalid_response = True
        result = validate(analysis)
    except Exception as exc:  # noqa: BLE001
        # llm.chat_structured raises ValueError on a provider parsing failure.
        invalid_response = invalid_response or isinstance(exc, ValueError)
        log.warning("dispatch_structured_failed", error=type(exc).__name__)
        repair_system = (
            _DISPATCH_SYSTEM
            + "\nReturn a complete replacement decision. The previous attempt failed validation "
            "or could not be parsed. Check mode/profile consistency and all IDs against the "
            "supplied roster/catalog. Use alternatives: [] unless there is another suitable "
            "EXISTING roster agent. The new specialist belongs ONLY in custom_agent. "
            "Never emit null IDs in alternatives. Return JSON matching this schema:\n"
            + json.dumps(DispatchAnalysis.model_json_schema(), ensure_ascii=False)
        )
        try:
            repaired = await llm.chat_json(
                system=repair_system,
                user=user_block,
                usage=usage,
                max_tokens=1200,
            )
        except Exception as repair_exc:  # noqa: BLE001
            if invalid_response:
                raise InvalidDispatchAnalysis("dispatch repair unavailable") from repair_exc
            raise
        try:
            result = validate(repaired)
        except ValueError as repair_exc:
            raise InvalidDispatchAnalysis("dispatch repair failed validation") from repair_exc

    log.info(
        "dispatch_analyzed",
        mode=(result.get("recommendation") or {}).get("mode"),
        tokens=usage.as_dict()["total_tokens"],
    )
    return result
