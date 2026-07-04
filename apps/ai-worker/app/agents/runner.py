"""Agent run orchestration.

Executes a task as a sequence of planned steps. Each step may invoke a tool;
HIGH/CRITICAL-risk tools pause the run in `waiting_for_approval` until the
resume endpoint is called with a human decision. Run state is kept in-memory
per worker instance (production: externalize to Redis/DB checkpointer via
LangGraph's persistence layer).
"""

import asyncio
from typing import Any

import structlog

from app.clients.phoenix import PhoenixClient
from app.policies.approval import requires_approval, risk_for_tool
from app.schemas import ResumeRequest, RunRequest, RunState, RunStatus, ToolCall
from app.tools.registry import get_tool

log = structlog.get_logger()

_RUNS: dict[str, RunState] = {}
_RESUME_EVENTS: dict[str, asyncio.Event] = {}
_RESUME_DECISIONS: dict[str, ResumeRequest] = {}


def get_run(run_id: str) -> RunState | None:
    return _RUNS.get(run_id)


def _plan_steps(request: RunRequest) -> list[dict[str, Any]]:
    """Very small deterministic planner (placeholder for the LangGraph LLM planner).

    Produces a plan based on requested action so the full run/approve/resume
    lifecycle is exercisable end-to-end without an LLM key.
    """
    action = request.input.get("action", "summarize")

    if action == "send_campaign":
        return [
            {"tool": "search_knowledge", "input": {"query": request.task_title or ""}},
            {"tool": "draft_document", "input": {"title": f"Campaign: {request.task_title}"}},
            {
                "tool": "send_email",
                "input": {"to": request.input.get("to", "list:subscribers"), "subject": request.task_title},
            },
        ]
    if action == "report":
        return [
            {"tool": "generate_report", "input": {"period": request.input.get("period", "last_30_days")}},
        ]
    return [
        {"tool": "search_knowledge", "input": {"query": request.task_title or ""}},
        {"tool": "summarize", "input": {"text": request.task_description or request.task_title or ""}},
    ]


async def execute_run(request: RunRequest, phoenix: PhoenixClient | None = None) -> RunState:
    phoenix = phoenix or PhoenixClient()
    state = RunState(run_id=request.run_id, status=RunStatus.RUNNING)
    _RUNS[request.run_id] = state

    await phoenix.update_run_status(request.run_id, RunStatus.RUNNING.value)
    log.info("run_started", run_id=request.run_id, task_id=request.task_id)

    try:
        for step in _plan_steps(request):
            tool_name: str = step["tool"]
            tool_input: dict[str, Any] = step["input"]
            risk = risk_for_tool(tool_name)
            call = ToolCall(tool=tool_name, input=tool_input, risk=risk)

            if requires_approval(tool_name):
                state.status = RunStatus.WAITING_FOR_APPROVAL
                state.pending_tool = call
                await phoenix.update_run_status(request.run_id, state.status.value)
                await phoenix.request_approval(request.run_id, tool_name, tool_input, risk.value)
                log.info("run_waiting_approval", run_id=request.run_id, tool=tool_name)

                decision = await _wait_for_decision(request.run_id)
                state.pending_tool = None

                if decision.decision == "rejected":
                    call.approved = False
                    state.tool_calls.append(call)
                    log.info("tool_rejected", run_id=request.run_id, tool=tool_name)
                    continue

                call.approved = True
                if decision.decision == "edited" and decision.payload:
                    call.input = decision.payload
                state.status = RunStatus.RUNNING
                await phoenix.update_run_status(request.run_id, state.status.value)

            fn = get_tool(tool_name)
            if fn is None:
                raise ValueError(f"unknown tool: {tool_name}")

            call.output = await fn(call.input)
            state.tool_calls.append(call)
            state.steps.append({"tool": tool_name, "ok": True})
            log.info("tool_executed", run_id=request.run_id, tool=tool_name)

        state.status = RunStatus.COMPLETED
        state.output = {
            "steps": len(state.steps),
            "tool_calls": [c.model_dump(mode="json") for c in state.tool_calls],
        }
        await phoenix.complete_run(request.run_id, state.output)
        log.info("run_completed", run_id=request.run_id)

    except asyncio.CancelledError:
        state.status = RunStatus.CANCELED
        await phoenix.update_run_status(request.run_id, state.status.value)
        raise
    except Exception as exc:  # noqa: BLE001 — report any failure to the API
        state.status = RunStatus.FAILED
        state.error = str(exc)
        await phoenix.fail_run(request.run_id, state.error)
        log.error("run_failed", run_id=request.run_id, error=state.error)

    return state


async def _wait_for_decision(run_id: str) -> ResumeRequest:
    event = asyncio.Event()
    _RESUME_EVENTS[run_id] = event
    await event.wait()
    _RESUME_EVENTS.pop(run_id, None)
    return _RESUME_DECISIONS.pop(run_id)


def resume_run(request: ResumeRequest) -> bool:
    event = _RESUME_EVENTS.get(request.run_id)
    if event is None:
        return False
    _RESUME_DECISIONS[request.run_id] = request
    event.set()
    return True
