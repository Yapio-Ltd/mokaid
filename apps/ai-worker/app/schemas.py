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


class RunRequest(BaseModel):
    run_id: str
    workspace_id: str
    agent_id: str | None = None
    task_id: str
    task_title: str | None = None
    task_description: str | None = None
    input: dict[str, Any] = Field(default_factory=dict)
    mcp_servers: list[McpServerGrant] = Field(default_factory=list)


class ResumeRequest(BaseModel):
    run_id: str
    decision: str  # approved | rejected | edited
    payload: dict[str, Any] | None = None


class ToolCall(BaseModel):
    tool: str
    input: dict[str, Any]
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
