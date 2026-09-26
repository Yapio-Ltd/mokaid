import asyncio
from copy import deepcopy

import pytest

from app.agents.team import MAX_MESSAGES_PER_AGENT, TeamAssignment, TeamSession
from app.schemas import RunRequest


def request():
    return RunRequest(
        run_id="team-run",
        workspace_id="workspace",
        task_id="same-task",
        agent_id="lead",
        task_description="Research and prepare a shared answer",
        colleagues=[
            {"id": "researcher", "name": "Researcher"},
            {"id": "analyst", "name": "Analyst"},
            {"id": "busy", "name": "Busy", "status": "busy"},
        ],
    )


def assignments():
    return [
        TeamAssignment(colleague="researcher", brief="Find reliable public sources"),
        TeamAssignment(colleague="analyst", brief="Compare the technical findings"),
    ]


async def test_contributors_work_concurrently_exchange_findings_and_join_one_result():
    started = set()
    both_started = asyncio.Event()
    release = asyncio.Event()
    comments = []

    async def post(workspace_id, task_id, body, *, agent_id):
        comments.append((workspace_id, task_id, body, agent_id))

    async def execute(colleague, brief, team):
        started.add(colleague.id)
        await team.send(colleague.id, f"Finding from {colleague.name}")
        if len(started) == 2:
            both_started.set()
        await release.wait()
        assert len(team.snapshot()["messages"]) == 3
        return {"summary": f"Completed: {brief}", "artifacts": [f"{colleague.id}.md"]}

    team = TeamSession(request(), execute, post)
    try:
        result = await team.start(assignments())
        assert len(result["started"]) == 2
        await asyncio.wait_for(both_started.wait(), timeout=1)
        assert all(item["status"] == "running" for item in team.snapshot()["participants"])
        assert all(not task.done() for task in team.tasks.values())
        assert await team.send("lead", "Use the verified source dates.") == {
            "sent": True,
            "sequence": 3,
        }
        release.set()
        results = await asyncio.wait_for(team.collect(), timeout=1)

        assert team.collected
        assert [item["status"] for item in results["participants"]] == ["completed", "completed"]
        assert {item["agent_id"] for item in results["participants"]} == {"researcher", "analyst"}
        assert {path for item in results["participants"] for path in item["artifacts"]} == {
            "researcher.md", "analyst.md"
        }
        assert {entry[1] for entry in comments} == {"same-task"}
        assert {entry[3] for entry in comments} == {"lead", "researcher", "analyst"}
    finally:
        await team.close()


@pytest.mark.parametrize("invalid", ["unknown", "busy", "researcher"])
async def test_invalid_assignment_batch_never_starts_partial_work(invalid):
    executed = []

    async def execute(colleague, brief, team):
        executed.append(colleague.id)
        return {"summary": "A result"}

    async def post(*args, **kwargs):
        pass

    team = TeamSession(request(), execute, post)
    result = await team.start([
        assignments()[0],
        TeamAssignment(colleague=invalid, brief="Another independent piece of work"),
    ])

    assert "error" in result
    assert team.tasks == {}
    assert team.snapshot()["participants"] == []
    assert executed == []


async def test_failure_preserves_other_contribution_and_hides_provider_secrets():
    async def post(*args, **kwargs):
        raise ConnectionError("Temporary UI callback failure")

    async def execute(colleague, brief, team):
        if colleague.id == "researcher":
            raise RuntimeError("https://provider.test/?token=private-secret")
        return {"summary": "Verified technical result", "artifacts": ["analysis.md"]}

    team = TeamSession(request(), execute, post)
    await team.start(assignments())
    results = await team.collect()

    assert results["participants"][0]["status"] == "failed"
    assert results["participants"][1]["status"] == "completed"
    assert results["participants"][1]["artifacts"] == ["analysis.md"]
    assert "private-secret" not in str(results)


async def test_closing_cancels_and_drains_every_contributor():
    started = set()
    drained = set()
    all_started = asyncio.Event()

    async def post(*args, **kwargs):
        pass

    async def execute(colleague, brief, team):
        started.add(colleague.id)
        if len(started) == 2:
            all_started.set()
        try:
            await asyncio.Event().wait()
        finally:
            drained.add(colleague.id)

    team = TeamSession(request(), execute, post)
    await team.start(assignments())
    await asyncio.wait_for(all_started.wait(), timeout=1)
    await asyncio.wait_for(team.close(), timeout=1)

    assert drained == {"researcher", "analyst"}
    assert all(task.done() for task in team.tasks.values())
    assert all(item["status"] == "canceled" for item in team.snapshot()["participants"])


async def test_messages_are_attributed_scoped_bounded_and_snapshots_are_copies():
    async def post(*args, **kwargs):
        pass

    async def execute(colleague, brief, team):
        await asyncio.Event().wait()

    team = TeamSession(request(), execute, post)
    await team.start(assignments())
    try:
        assert "error" in await team.send("outsider", "A forged update")
        assert "error" in await team.send("lead", "A private update", recipient="outsider")
        assert "error" in await team.send("lead", " ")
        assert "error" in await team.send("lead", "x" * 2001)
        for _ in range(MAX_MESSAGES_PER_AGENT):
            assert (await team.send("researcher", "Verified finding", recipient="Analyst"))["sent"]
        assert "error" in await team.send("researcher", "One too many")

        snapshot = team.snapshot()
        assert snapshot["messages"][0]["agent_id"] == "researcher"
        assert snapshot["messages"][0]["recipient_id"] == "analyst"
        snapshot["messages"][0]["body"] = "Mutated"
        snapshot["participants"][0]["artifacts"].append("forged.pdf")
        assert team.snapshot()["messages"][0]["body"] == "Verified finding"
        assert team.snapshot()["participants"][0]["artifacts"] == []
    finally:
        await team.close()


async def test_cancellation_during_initial_notification_marks_contribution_canceled():
    posting = asyncio.Event()

    async def post(*args, **kwargs):
        posting.set()
        await asyncio.Event().wait()

    async def execute(colleague, brief, team):
        raise AssertionError("The contribution should be canceled before execution")

    team = TeamSession(request(), execute, post)
    await team.start([assignments()[0]])
    await asyncio.wait_for(posting.wait(), timeout=1)
    await asyncio.wait_for(team.close(), timeout=1)

    assert team.snapshot()["participants"][0]["status"] == "canceled"


async def test_restart_reuses_completed_evidence_and_only_restarts_unfinished_work():
    saved = {}
    first_done = asyncio.Event()

    async def checkpoint(snapshot):
        nonlocal saved
        saved = deepcopy(snapshot)
        if snapshot["participants"][0]["status"] == "completed":
            first_done.set()

    async def post(*args, **kwargs):
        pass

    async def execute(colleague, brief, team):
        if colleague.id == "analyst":
            await asyncio.Event().wait()
        await team.send(colleague.id, "The source was verified.", recipient="analyst")
        return {
            "summary": "Source evidence with citation",
            "artifacts": ["sources.pdf"],
            "tool_calls": [{
                "tool": "web_search", "input": {"query": "original query"},
                "agent_id": colleague.id,
                "output": {"results": [{"url": "https://example.com/source"}]},
            }],
            "usage": {"prompt_tokens": 12, "completion_tokens": 4, "images": 0, "cost_usd": 0.002},
        }

    original = TeamSession(request(), execute, post, checkpoint=checkpoint)
    await original.start(assignments())
    await asyncio.wait_for(first_done.wait(), timeout=1)
    interrupted_snapshot = deepcopy(saved)
    await original.close()

    executed_after_restart = []

    async def resumed_execute(colleague, brief, team):
        executed_after_restart.append(colleague.id)
        assert team.snapshot()["messages"][0]["body"] == "The source was verified."
        assert team.snapshot()["participants"][0]["status"] == "completed"
        return {"summary": "Analysis based on the shared verified source"}

    resumed = TeamSession(request(), resumed_execute, post)
    await resumed.restore(interrupted_snapshot)
    assert not resumed.collected
    calls = resumed.restored_tool_calls()
    assert calls[0]["output"]["results"][0]["url"] == "https://example.com/source"
    assert resumed.restored_usage()[0]["cost_usd"] == 0.002
    assert "tool_calls" not in resumed.snapshot()["participants"][0]
    assert "usage" not in resumed.snapshot()["participants"][0]
    assert resumed.snapshot(include_evidence=True)["participants"][0]["tool_calls"] == calls
    assert "error" in await resumed.start(assignments())

    result = await asyncio.wait_for(resumed.collect(), timeout=1)
    assert executed_after_restart == ["analyst"]
    assert all(item["status"] == "completed" for item in result["participants"])
    assert len(resumed.restored_tool_calls()) == 1


async def test_restart_of_completed_team_only_collects_existing_results():
    async def execute(*args):
        raise AssertionError("Completed contributors must not run twice")

    async def post(*args, **kwargs):
        pass

    team = TeamSession(request(), execute, post)
    await team.restore({"participants": [{
        "agent_id": "researcher", "name": "Untrusted display name", "brief": "Find reliable public sources",
        "status": "completed", "summary": "Verified source citation", "artifacts": [],
    }], "messages": []})
    assert team.tasks == {}
    assert not team.collected
    result = await team.collect()
    assert result["participants"][0]["name"] == "Researcher"
    assert result["participants"][0]["summary"] == "Verified source citation"
    assert team.collected


@pytest.mark.parametrize("invalid", [
    {"agent_id": "another-workspace-agent"},
    {"status": "invented"},
    {"status": "completed", "summary": "", "artifacts": []},
    {"tool_calls": [{"tool": "web_search", "input": {}, "agent_id": "lead"}]},
    {"usage": {"cost_usd": -1}},
    {"usage": {"cost_usd": float("nan")}},
])
async def test_corrupt_resume_checkpoint_never_starts_partial_team(invalid):
    async def execute(*args):
        raise AssertionError("Invalid checkpoint must not start work")

    async def post(*args, **kwargs):
        pass

    participant = {
        "agent_id": "researcher", "brief": "Find reliable public sources",
        "status": "running", "summary": "", "artifacts": [],
    }
    team = TeamSession(request(), execute, post)
    with pytest.raises(ValueError):
        await team.restore({"participants": [{**participant, **invalid}], "messages": []})
    assert not team.tasks
    assert not team.contributions


async def test_checkpoints_precede_execution_and_preserve_concurrent_messages_in_order():
    writes = []
    writing = 0
    first_message_write = asyncio.Event()
    release_first_write = asyncio.Event()

    async def checkpoint(snapshot):
        nonlocal writing
        writing += 1
        assert writing == 1
        if len(snapshot["messages"]) == 1:
            first_message_write.set()
            await release_first_write.wait()
        writes.append(deepcopy(snapshot))
        writing -= 1

    async def post(*args, **kwargs):
        pass

    async def execute(colleague, brief, team):
        assert writes[0]["participants"][0]["status"] == "running"
        await asyncio.Event().wait()

    team = TeamSession(request(), execute, post, checkpoint=checkpoint)
    await team.start(assignments())
    first = asyncio.create_task(team.send("researcher", "First finding"))
    await asyncio.wait_for(first_message_write.wait(), timeout=1)
    second = asyncio.create_task(team.send("analyst", "Second finding"))
    release_first_write.set()
    await asyncio.wait_for(asyncio.gather(first, second), timeout=1)
    assert [message["body"] for message in writes[-1]["messages"]] == ["First finding", "Second finding"]
    assert team.request.input["_team_state"] == writes[-1]
    await team.close()
