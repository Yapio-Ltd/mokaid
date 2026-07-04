import asyncio

from app.agents import runner
from app.schemas import ResumeRequest, RunRequest, RunStatus


def make_request(run_id: str, action: str = "summarize") -> RunRequest:
    return RunRequest(
        run_id=run_id,
        workspace_id="ws-1",
        agent_id="agent-1",
        task_id="task-1",
        task_title="Test task",
        task_description="Do the thing",
        input={"action": action},
    )


async def test_low_risk_run_completes_without_approval(phoenix):
    state = await runner.execute_run(make_request("run-low"), phoenix=phoenix)

    assert state.status == RunStatus.COMPLETED
    assert len(state.tool_calls) == 2
    assert not any(kind == "approval" for kind, _ in phoenix.calls)
    assert phoenix.calls[-1][0] == "complete"


async def test_high_risk_tool_waits_for_approval_then_runs(phoenix):
    task = asyncio.create_task(runner.execute_run(make_request("run-hi", "send_campaign"), phoenix=phoenix))

    # Wait until the run pauses on the send_email approval
    for _ in range(100):
        await asyncio.sleep(0.01)
        state = runner.get_run("run-hi")
        if state and state.status == RunStatus.WAITING_FOR_APPROVAL:
            break
    else:
        raise AssertionError("run never paused for approval")

    assert state.pending_tool is not None
    assert state.pending_tool.tool == "send_email"

    assert runner.resume_run(ResumeRequest(run_id="run-hi", decision="approved"))
    state = await task

    assert state.status == RunStatus.COMPLETED
    email_call = next(c for c in state.tool_calls if c.tool == "send_email")
    assert email_call.approved is True
    assert email_call.output["sent"] is True


async def test_rejected_tool_is_skipped(phoenix):
    task = asyncio.create_task(runner.execute_run(make_request("run-rej", "send_campaign"), phoenix=phoenix))

    for _ in range(100):
        await asyncio.sleep(0.01)
        state = runner.get_run("run-rej")
        if state and state.status == RunStatus.WAITING_FOR_APPROVAL:
            break

    assert runner.resume_run(ResumeRequest(run_id="run-rej", decision="rejected"))
    state = await task

    assert state.status == RunStatus.COMPLETED
    email_call = next(c for c in state.tool_calls if c.tool == "send_email")
    assert email_call.approved is False
    assert email_call.output is None


async def test_resume_unknown_run_returns_false():
    assert runner.resume_run(ResumeRequest(run_id="missing", decision="approved")) is False
