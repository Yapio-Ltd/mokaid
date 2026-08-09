"""Approval policy — decides which tool calls require a human in the loop.

Mirrors the risk model from the product spec:
- read-only tools run freely,
- content-producing tools run freely but results are reviewable,
- external side effects (email, posting, purchases) always require approval.

On top of the static risk table, `ApprovalPolicy` applies the agent's
per-agent supervision settings (Claude Code style):
- an autonomy mode shifts the risk threshold that pauses the run,
- persisted allow/deny rules short-circuit the gate for specific tools
  ("always allow send_email for this agent", "never let it post socials").
"""

from fnmatch import fnmatchcase

from app.schemas import RiskLevel

# tool name -> risk level
TOOL_RISK: dict[str, RiskLevel] = {
    # Read-only / internal
    "search_knowledge": RiskLevel.LOW,
    "load_domain_skill": RiskLevel.LOW,
    "traverse_knowledge": RiskLevel.LOW,
    "knowledge_path": RiskLevel.LOW,
    "explain_concept": RiskLevel.LOW,
    "save_knowledge_outcome": RiskLevel.LOW,
    "web_search": RiskLevel.LOW,
    "read_file": RiskLevel.LOW,
    "list_tasks": RiskLevel.LOW,
    # Content generation (internal artifacts)
    "draft_document": RiskLevel.MEDIUM,
    "generate_report": RiskLevel.MEDIUM,
    "summarize": RiskLevel.LOW,
    # File processing (internal artifacts, results are reviewable in-task)
    "analyze_file": RiskLevel.LOW,
    "extract_document_text": RiskLevel.LOW,
    "transform_image": RiskLevel.MEDIUM,
    "transcribe_audio": RiskLevel.MEDIUM,
    "generate_website": RiskLevel.MEDIUM,
    "generate_webapp": RiskLevel.MEDIUM,
    # Always pause — user must pick HTML vitrine vs Next codebase.
    "choose_site_delivery": RiskLevel.HIGH,
    # Internal mutations
    "update_task": RiskLevel.MEDIUM,
    "create_subtasks": RiskLevel.MEDIUM,
    "upload_file": RiskLevel.MEDIUM,
    # External side effects — always gated
    "send_email": RiskLevel.HIGH,
    "post_social": RiskLevel.HIGH,
    "call_external_api": RiskLevel.HIGH,
    "make_purchase": RiskLevel.CRITICAL,
}

APPROVAL_THRESHOLD = {RiskLevel.HIGH, RiskLevel.CRITICAL}


def risk_for_tool(tool_name: str) -> RiskLevel:
    if tool_name.startswith("mcp:"):
        return _risk_for_mcp_tool(tool_name)
    return TOOL_RISK.get(tool_name, RiskLevel.HIGH)


def requires_approval(tool_name: str) -> bool:
    return risk_for_tool(tool_name) in APPROVAL_THRESHOLD


def _risk_for_mcp_tool(tool_name: str) -> RiskLevel:
    """MCP tools default to MEDIUM; sensitive writes are gated behind approval."""
    from app.mcp.client import is_write_tool

    return RiskLevel.HIGH if is_write_tool(tool_name) else RiskLevel.MEDIUM


# Risk levels that pause the run per supervision mode. "supervised" reviews
# even content generation; "autonomous" only stops for critical actions.
_MODE_GATED: dict[str, set[RiskLevel]] = {
    "supervised": {RiskLevel.MEDIUM, RiskLevel.HIGH, RiskLevel.CRITICAL},
    "balanced": APPROVAL_THRESHOLD,
    "autonomous": {RiskLevel.CRITICAL},
}

# Tools that are genuine questions to the human (not risk gates) — they pause
# regardless of autonomy mode or allow rules.
ALWAYS_ASK: set[str] = {"choose_site_delivery"}


class ApprovalPolicy:
    """Per-run approval decisions from the agent's autonomy settings.

    decision(tool) returns:
    - "auto"  — run freely (below the mode's risk threshold)
    - "allow" — gated tool auto-approved by a persisted allow rule
    - "deny"  — auto-rejected by a persisted deny rule (agent adapts)
    - "ask"   — pause the run for a human decision
    """

    def __init__(self, autonomy: dict | None = None) -> None:
        autonomy = autonomy if isinstance(autonomy, dict) else {}
        mode = autonomy.get("mode") or "balanced"
        self.mode = mode if mode in _MODE_GATED else "balanced"
        self.rules = [
            rule
            for rule in (autonomy.get("rules") or [])
            if isinstance(rule, dict) and rule.get("tool_pattern")
        ]

    def _matches(self, behavior: str, tool_name: str) -> bool:
        return any(
            rule.get("behavior") == behavior
            and fnmatchcase(tool_name, str(rule["tool_pattern"]))
            for rule in self.rules
        )

    def decision(self, tool_name: str) -> str:
        if tool_name in ALWAYS_ASK:
            return "ask"
        if self._matches("deny", tool_name):
            return "deny"
        if risk_for_tool(tool_name) not in _MODE_GATED[self.mode]:
            return "auto"
        if self._matches("allow", tool_name):
            return "allow"
        return "ask"

    def requires_approval(self, tool_name: str) -> bool:
        return self.decision(tool_name) == "ask"
