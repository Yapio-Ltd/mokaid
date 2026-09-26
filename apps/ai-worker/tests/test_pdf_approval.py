"""PDF creation is an internal deliverable, including on supervised runs."""

import asyncio
from unittest.mock import AsyncMock, Mock

from app.agents import deep_runner, runner
from app.schemas import ResumeRequest, RunRequest, RunState, RunStatus, ToolCall
from app.tools.registry import RunContext


def pdf_request(run_id: str) -> RunRequest:
    return RunRequest(
        run_id=run_id,
        workspace_id="ws",
        task_id="task",
        task_title="Research report",
        autonomy={"mode": "supervised"},
        input={"instruction": "Export the completed report as a PDF"},
    )


async def test_legacy_runner_exports_pdf_without_a_permission_request(phoenix, monkeypatch):
    async def plan(*_args):
        return [{"tool": "export_pdf", "input": {"title": "Report", "content": "# Findings\n\nDone."}}]

    monkeypatch.setattr(runner, "plan_steps", plan)
    state = await asyncio.wait_for(
        runner.execute_run(pdf_request("pdf-legacy"), phoenix=phoenix), timeout=2
    )

    assert state.status == RunStatus.COMPLETED
    assert any(kind == "output" for kind, _ in phoenix.calls)
    assert not any(kind == "approval" for kind, _ in phoenix.calls)


async def test_deep_runner_exports_pdf_without_a_permission_request(phoenix):
    request = pdf_request("pdf-deep")
    state = RunState(run_id=request.run_id, status=RunStatus.RUNNING)
    wait = AsyncMock(side_effect=AssertionError("PDF export must not ask for permission"))
    toolbox = Mock()
    toolbox.has.return_value = False
    engine = deep_runner._Engine(
        request,
        RunContext(run_id=request.run_id, workspace_id="ws", task_id="task", phoenix=phoenix),
        state,
        phoenix,
        toolbox,
        [],
        wait,
    )
    engine._emit_activity = Mock()

    output = await engine._run_tool("export_pdf", {"title": "Report", "content": "# Findings\n\nDone."})

    assert output["filename"].endswith(".pdf")
    assert not any(kind == "approval" for kind, _ in phoenix.calls)
    wait.assert_not_awaited()


def test_recovered_pdf_permission_never_authorizes_the_next_external_action():
    runner.seed_decision(ResumeRequest(run_id="pdf-recovery", decision="approved", tool_name="export_pdf"))

    assert runner.take_seeded_decision("pdf-recovery", "send_email") is None
    assert runner.take_seeded_decision("pdf-recovery", "export_pdf") is None


def test_recovered_permission_applies_only_to_its_original_tool():
    decision = ResumeRequest(run_id="pdf-recovery-match", decision="approved", tool_name="export_pdf")
    runner.seed_decision(decision)

    assert runner.take_seeded_decision("pdf-recovery-match", "export_pdf") == decision


async def test_delayed_pdf_resume_never_approves_a_live_external_action():
    run_id = "pdf-delayed-live"
    event = asyncio.Event()
    runner._RUNS[run_id] = RunState(
        run_id=run_id,
        status=RunStatus.WAITING_FOR_APPROVAL,
        pending_tool=ToolCall(tool="send_email", input={"to": "test@example.com"}),
    )
    runner._RESUME_EVENTS[run_id] = event
    try:
        assert await runner.resume_run(
            ResumeRequest(run_id=run_id, decision="approved", tool_name="export_pdf")
        )
        assert not event.is_set()
        assert run_id not in runner._RESUME_DECISIONS
    finally:
        runner._RUNS.pop(run_id, None)
        runner._RESUME_EVENTS.pop(run_id, None)


async def test_delayed_pdf_resume_does_not_restart_a_canceled_run(monkeypatch):
    run_id = "pdf-delayed-canceled"
    runner._RUNS[run_id] = RunState(run_id=run_id, status=RunStatus.CANCELED)
    load = AsyncMock(side_effect=AssertionError("Canceled runs must not restart"))
    monkeypatch.setattr(runner.persistence, "load_run_request", load)
    try:
        assert await runner.resume_run(
            ResumeRequest(run_id=run_id, decision="approved", tool_name="export_pdf")
        )
        load.assert_not_awaited()
    finally:
        runner._RUNS.pop(run_id, None)
