import asyncio

from app.agents import runner
from app.schemas import ResumeRequest, RunRequest, RunStatus, ToolCall


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
    task = asyncio.create_task(
        runner.execute_run(make_request("run-hi", "send_campaign"), phoenix=phoenix)
    )

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
    task = asyncio.create_task(
        runner.execute_run(make_request("run-rej", "send_campaign"), phoenix=phoenix)
    )

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


async def test_run_posts_conversational_acknowledgement(phoenix):
    await runner.execute_run(make_request("run-ack"), phoenix=phoenix)

    comment_calls = [payload for kind, payload in phoenix.calls if kind == "comment"]
    assert len(comment_calls) == 1
    assert comment_calls[0]["task_id"] == "task-1"
    assert comment_calls[0]["agent_id"] == "agent-1"
    assert "Test task" in comment_calls[0]["body"]


async def test_deep_website_forces_generate_and_completes(phoenix, monkeypatch):
    async def fake_deep(request, ctx, state, phoenix_client, toolbox, mcp_tools, wait_fn):
        return {"summary": "Besoin de précisions ?", "artifacts": []}

    async def fake_force(request, ctx, state, tool_name):
        assert tool_name == "generate_website"
        state.tool_calls.append(
            ToolCall(
                tool="generate_website",
                input={"brief": request.input.get("instruction")},
                output={
                    "filename": "landing.html",
                    "drive_item_id": "drive-1",
                    "mime_type": "text/html",
                },
            )
        )
        return ["landing.html"]

    monkeypatch.setattr(runner.deep_runner, "is_available", lambda: True)
    monkeypatch.setattr(runner.deep_runner, "execute", fake_deep)
    monkeypatch.setattr(runner, "_force_producer_tool", fake_force)

    req = RunRequest(
        run_id="run-site",
        workspace_id="ws-1",
        agent_id="agent-1",
        task_id="task-1",
        task_title="Site semaine",
        task_description="Créer un site internet",
        input={
            "instruction": "Créer un site internet pour résumer la semaine",
            "mission_kind": "website",
            "language": "fr",
            "chat_task": True,
        },
    )
    state = await runner.execute_run(req, phoenix=phoenix)

    assert state.status == RunStatus.COMPLETED
    assert "landing.html" in (state.output or {}).get("artifacts", [])
    assert any(kind == "complete" for kind, _ in phoenix.calls)
    assert not any(kind == "fail" for kind, _ in phoenix.calls)


async def test_deep_producer_without_artifact_fails(phoenix, monkeypatch):
    async def fake_deep(request, ctx, state, phoenix_client, toolbox, mcp_tools, wait_fn):
        state.tool_calls.append(
            ToolCall(tool="search_knowledge", input={"query": "x"}, output={"chunks": []})
        )
        return {"summary": "What industry?", "artifacts": []}

    async def fake_force(request, ctx, state, tool_name):
        return []

    monkeypatch.setattr(runner.deep_runner, "is_available", lambda: True)
    monkeypatch.setattr(runner.deep_runner, "execute", fake_deep)
    monkeypatch.setattr(runner, "_force_producer_tool", fake_force)

    req = RunRequest(
        run_id="run-fail-site",
        workspace_id="ws-1",
        agent_id="agent-1",
        task_id="task-1",
        task_title="Website",
        input={
            "instruction": "Build a landing page",
            "mission_kind": "website",
            "language": "en",
        },
    )
    state = await runner.execute_run(req, phoenix=phoenix)

    assert state.status == RunStatus.FAILED
    assert any(kind == "fail" for kind, _ in phoenix.calls)
    assert not any(kind == "complete" for kind, _ in phoenix.calls)


async def test_deep_analysis_without_file_waits_for_user(phoenix, monkeypatch):
    async def fake_deep(request, ctx, state, phoenix_client, toolbox, mcp_tools, wait_fn):
        return {"summary": "Need the file", "artifacts": []}

    monkeypatch.setattr(runner.deep_runner, "is_available", lambda: True)
    monkeypatch.setattr(runner.deep_runner, "execute", fake_deep)

    req = RunRequest(
        run_id="run-wait",
        workspace_id="ws-1",
        agent_id="agent-1",
        task_id="task-1",
        task_title="Analyse ce PDF",
        input={
            "instruction": "Analyse ce document",
            "mission_kind": "analysis",
            "language": "fr",
            "chat_task": True,
        },
    )
    state = await runner.execute_run(req, phoenix=phoenix)

    assert state.status == RunStatus.WAITING_FOR_USER_INPUT
    assert any(
        kind == "status" and payload["status"] == "waiting_for_user_input"
        for kind, payload in phoenix.calls
    )
    assert any(kind == "comment" for kind, _ in phoenix.calls)
    assert any(kind == "chat" for kind, _ in phoenix.calls)
    assert not any(kind == "complete" for kind, _ in phoenix.calls)


def test_is_refusal_detects_ethics_and_policy_messages():
    assert runner._is_refusal(
        "I understand the request, but I cannot help with this task because "
        "it involves creating symbols associated with harmful historical regimes."
    )
    assert runner._is_refusal(
        "Je ne peux pas effectuer cette tâche pour des raisons éthiques."
    )
    assert runner._is_refusal("Blocked by the content policy of the provider.")
    assert not runner._is_refusal("Here's the resized avatar — let me know if you want tweaks!")
    assert not runner._is_refusal("")


async def test_deep_refusal_without_tools_fails(phoenix, monkeypatch):
    async def fake_deep(request, ctx, state, phoenix_client, toolbox, mcp_tools, wait_fn):
        return {
            "summary": (
                "I understand the request, but I cannot help with this task "
                "because it involves historically harmful symbols."
            ),
            "artifacts": [],
        }

    monkeypatch.setattr(runner.deep_runner, "is_available", lambda: True)
    monkeypatch.setattr(runner.deep_runner, "execute", fake_deep)

    req = RunRequest(
        run_id="run-refusal",
        workspace_id="ws-1",
        agent_id="agent-1",
        task_id="task-1",
        task_title="Edit avatar",
        task_description="Add a historically harmful symbol to the avatar",
        input={
            "instruction": "Add that symbol to the avatar",
            "mission_kind": "general",
            "language": "en",
            "chat_task": True,
        },
    )
    state = await runner.execute_run(req, phoenix=phoenix)

    assert state.status == RunStatus.FAILED
    assert state.error and state.error.startswith("content_policy:")
    assert any(kind == "fail" for kind, _ in phoenix.calls)
    assert not any(kind == "complete" for kind, _ in phoenix.calls)
