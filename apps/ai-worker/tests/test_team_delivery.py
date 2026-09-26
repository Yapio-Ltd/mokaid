"""A partial team's failure cannot become a completed parent mission."""

from unittest.mock import AsyncMock

import pytest

from app.agents import runner
from app.mcp.client import McpToolbox
from app.schemas import RunRequest, RunState, RunStatus
from app.tools.registry import RunContext


def team_output(status, *, artifacts):
    return {
        "summary": "Here is the joint answer.",
        "artifacts": artifacts,
        "verification": {"status": "self_check"},
        "team": {
            "participants": [
                {
                    "agent_id": "peer",
                    "brief": "Prepare the required calculations",
                    "status": status,
                    "summary": "Verified calculations" if status == "completed" else "",
                    "artifacts": [],
                    "error": "Provider timeout" if status == "failed" else None,
                }
            ],
            "messages": [],
        },
    }


async def run_fake_team(monkeypatch, phoenix, output):
    request = RunRequest(
        run_id="team-delivery",
        workspace_id="workspace",
        task_id="task",
        task_title="Prepare a joint answer",
        agent_id="lead",
    )
    state = RunState(run_id=request.run_id, status=RunStatus.RUNNING)
    ctx = RunContext(
        run_id=request.run_id,
        workspace_id=request.workspace_id,
        task_id=request.task_id,
        agent_id=request.agent_id,
        phoenix=phoenix,
    )
    monkeypatch.setattr(runner.deep_runner, "execute", AsyncMock(return_value=output))
    return await runner._execute_deep(request, state, ctx, phoenix, McpToolbox([]), [])


@pytest.mark.parametrize("status", ["failed", "canceled"])
@pytest.mark.parametrize("artifacts", [[], ["lead-contribution.md"]])
async def test_incomplete_contribution_fails_parent_and_preserves_partial_artifacts(
    monkeypatch,
    phoenix,
    status,
    artifacts,
):
    output = team_output(status, artifacts=artifacts)
    state = await run_fake_team(monkeypatch, phoenix, output)

    assert state.status == RunStatus.FAILED
    assert state.output["artifacts"] == artifacts
    assert state.output["team"]["participants"][0]["status"] == status
    assert not any(kind == "complete" for kind, _ in phoenix.calls)
    assert any(kind == "fail" for kind, _ in phoenix.calls)


async def test_successful_contributions_can_complete_one_parent_response(monkeypatch, phoenix):
    state = await run_fake_team(monkeypatch, phoenix, team_output("completed", artifacts=[]))
    assert state.status == RunStatus.COMPLETED
    assert len([kind for kind, _ in phoenix.calls if kind == "complete"]) == 1
    assert not any(kind == "fail" for kind, _ in phoenix.calls)
