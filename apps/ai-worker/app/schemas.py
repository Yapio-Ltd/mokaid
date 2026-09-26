from enum import StrEnum
from typing import Any

from pydantic import BaseModel, Field


class RunStatus(StrEnum):
    QUEUED = "queued"
    RUNNING = "running"
    WAITING_FOR_APPROVAL = "waiting_for_approval"
    WAITING_FOR_USER_INPUT = "waiting_for_user_input"
    COMPLETED = "completed"
    FAILED = "failed"
    CANCELED = "canceled"


class RiskLevel(StrEnum):
    LOW = "low"
    MEDIUM = "medium"
    HIGH = "high"
    CRITICAL = "critical"


class McpServerGrant(BaseModel):
    """An MCP server the agent is authorized to use (from agent_mcp_grants)."""

    key: str
    name: str
    url: str
    transport: str = "http"
    auth_kind: str = "api_key"
    credentials: dict[str, Any] = Field(default_factory=dict)


class AttachedFile(BaseModel):
    """A workspace file linked to the task (dropped on the 3D office)."""

    id: str | None = None
    name: str
    mime_type: str | None = None
    size_bytes: int | None = None
    download_url: str | None = None
    # "input" (user-provided) or "agent_output" (result of a previous run).
    source: str | None = None


class Colleague(BaseModel):
    """Workspace colleague available for consultation or bounded team work.

    Availability is a dispatch-time snapshot, not a reservation of the agent's
    queue. Older payloads remain valid and inherit the lead's tool restrictions.
    """

    id: str
    name: str
    role_title: str | None = None
    department: str | None = None
    skills: list[str] = Field(default_factory=list)
    status: str = "idle"
    agent: dict[str, Any] = Field(default_factory=dict)
    autonomy: dict[str, Any] = Field(default_factory=dict)


class RunRequest(BaseModel):
    run_id: str
    workspace_id: str
    agent_id: str | None = None
    task_id: str
    project_id: str | None = None
    task_title: str | None = None
    task_description: str | None = None
    task_priority: str | None = None
    task_due_at: str | None = None
    input: dict[str, Any] = Field(default_factory=dict)
    attached_files: list[AttachedFile] = Field(default_factory=list)
    mcp_servers: list[McpServerGrant] = Field(default_factory=list)
    # Persona of the assigned agent (display_name, role_title, department,
    # skills) — lets the deep agent speak and work in character.
    agent: dict[str, Any] = Field(default_factory=dict)
    # Team mates available for consultation or parallel contributions.
    colleagues: list[Colleague] = Field(default_factory=list)
    # Supervision: {"mode": "supervised|balanced|autonomous",
    #               "rules": [{"tool_pattern": "...", "behavior": "allow|deny"}]}
    autonomy: dict[str, Any] = Field(default_factory=dict)
    # Server-issued policy. Never forward this or MCP credentials to a model.
    runtime_policy: dict[str, Any] = Field(default_factory=dict)


class ResumeRequest(BaseModel):
    run_id: str
    decision: str  # approved | rejected | edited
    payload: dict[str, Any] | None = None
    tool_name: str | None = None
    command_id: str | None = None


class ToolCall(BaseModel):
    tool: str
    input: dict[str, Any]
    # Optional for old runs; team contributions keep their author's identity.
    agent_id: str | None = None
    output: Any = None
    risk: RiskLevel = RiskLevel.LOW
    approved: bool | None = None


class RunState(BaseModel):
    run_id: str
    status: RunStatus = RunStatus.QUEUED
    steps: list[dict[str, Any]] = Field(default_factory=list)
    tool_calls: list[ToolCall] = Field(default_factory=list)
    output: dict[str, Any] | None = None
    error: str | None = None
    pending_tool: ToolCall | None = None
