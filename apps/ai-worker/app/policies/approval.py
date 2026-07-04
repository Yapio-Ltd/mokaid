"""Approval policy — decides which tool calls require a human in the loop.

Mirrors the risk model from the product spec:
- read-only tools run freely,
- content-producing tools run freely but results are reviewable,
- external side effects (email, posting, purchases) always require approval.
"""

from app.schemas import RiskLevel

# tool name -> risk level
TOOL_RISK: dict[str, RiskLevel] = {
    # Read-only / internal
    "search_knowledge": RiskLevel.LOW,
    "read_file": RiskLevel.LOW,
    "list_tasks": RiskLevel.LOW,
    # Content generation (internal artifacts)
    "draft_document": RiskLevel.MEDIUM,
    "generate_report": RiskLevel.MEDIUM,
    "summarize": RiskLevel.LOW,
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
    return TOOL_RISK.get(tool_name, RiskLevel.HIGH)


def requires_approval(tool_name: str) -> bool:
    return risk_for_tool(tool_name) in APPROVAL_THRESHOLD
