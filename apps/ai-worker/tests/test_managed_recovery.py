"""Failure injection at durable boundaries of real mission orchestration."""

import asyncio
from unittest.mock import AsyncMock

import httpx
import pytest

from app.agents import runner
from app.agents.managed_runner import ManagedEngine, ManagedMission, RuntimePaused
from app.agents.runtime import RuntimeResult, requirements_for, verification_command
from app.schemas import Colleague, RunState, RunStatus
from tests.test_managed_runtime import Adapter, managed_test_config, mission  # noqa: F401


def resume(first):
    first.request.input.pop("_worker_recovery_stop", None)
    return ManagedMission(
        first.request,
        RunState(run_id=first.request.run_id),
        first.phoenix,
        first.toolbox,
        [],
        AsyncMock(),
        first.store,
        first.adapter,
    )


async def test_delivery_response_lost_retries_only_receipt_not_model_or_files():
    run = await mission(
        Adapter(artifacts=[("note.txt", b"durable file")]), title="Write a document"
    )
    original = run.phoenix.finalize_runtime
    calls = 0

    async def fail_once(*args, **kwargs):
        nonlocal calls
        calls += 1
        if calls == 1:
            raise httpx.ReadTimeout("response lost")
        return await original(*args, **kwargs)

    run.phoenix.finalize_runtime = fail_once
    with pytest.raises(httpx.ReadTimeout):
        await run.execute()
    saved = await run.store.get_execution(run.request.run_id)
    assert saved["delivery_pending"]["status"] == "completed"
    assert not run.adapter.deleted
    state = await resume(run).execute()
    assert state.status == RunStatus.COMPLETED
    assert len(run.adapter.sessions) == 1
    assert len(run.phoenix.outputs) == 1
    assert run.adapter.deleted == ["session-1"]
    assert not (await run.store.get_execution(run.request.run_id))["delivery_pending"]


async def test_stop_before_recovery_cancels_recorded_session_and_accounts_usage():
    run = await mission(Adapter(), title="Write a document")
    sid = (
        await run.adapter.start(
            {
                "agent": {},
                "environment": {"type": "none"},
                "input": "task",
                "metadata": {"mokaid_participant": "lead"},
            }
        )
    )["id"]
    await run.store.save_execution(
        run.request.run_id,
        session_id=sid,
        model="gpt-6-sol",
        result=RuntimeResult(summary="partial").to_dict(),
        reserved=True,
        budget_cents=50,
        usage={"input_tokens": 1000, "output_tokens": 20},
    )
    await run.store.enqueue_command(run.request.run_id, "cancel", {}, "stop-one")
    state = await run.execute()
    assert state.status == RunStatus.CANCELED
    assert run.adapter.cancelled == [sid]
    settlement = [args for name, args in run.phoenix.calls if name == "settle"][-1]
    assert settlement["cost_cents"] > 0 and settlement["terminal_status"] == "canceled"
    assert len(run.adapter.sessions) == 1


async def test_pending_approval_without_creation_receipt_is_recreated_idempotently():
    run = await mission(Adapter(), title="Send an approved message")
    engine = ManagedEngine(run, run.request)
    engine.session_id = "session-old"
    action = {"call_id": "call", "turn_id": "turn"}
    params = {"body": "requested"}
    operation = await run.store.begin_operation(run.request.run_id, "send_email", params)
    binding = {"session_id": engine.session_id, **action, "params": params}
    await run.store.finish_operation(run.request.run_id, operation["key"], "pending", binding)
    operation = await run.store.begin_operation(run.request.run_id, "send_email", params)
    run.phoenix.request_approval = AsyncMock(return_value={"id": "approval"})
    from app.schemas import ResumeRequest

    run.wait_for_decision = AsyncMock(
        return_value=ResumeRequest(run_id=run.request.run_id, decision="approved")
    )
    assert (
        await run.approve(engine, operation["key"], "send_email", params, action, operation)
        == params
    )
    assert run.phoenix.request_approval.call_args.kwargs["operation_key"] == operation["key"]


async def test_uncertain_external_action_never_reexecutes_in_new_session():
    run = await mission(
        Adapter(),
        title="Send a message",
        autonomy={"rules": [{"tool_pattern": "send_email", "behavior": "allow"}]},
    )
    engine = ManagedEngine(run, run.request)
    engine.configure_tools()
    engine.session_id = "replacement-session"
    params = {"to": "person@example.test", "subject": "subject", "body": "body"}
    operation = await run.store.begin_operation(run.request.run_id, "send_email", params)
    await run.store.finish_operation(run.request.run_id, operation["key"], "ambiguous", None)
    with pytest.raises(RuntimePaused, match="uncertain outcome"):
        await engine.handle_action(
            {"name": "send_email", "arguments": params, "turn_id": "turn", "call_id": "new-call"}
        )
    assert not run.adapter.results


async def test_continuation_waits_for_new_turn_not_prior_completed_answer():
    adapter = Adapter()
    run = await mission(adapter, title="Write a short answer")
    engine = ManagedEngine(run, run.request)
    run.engines[""] = engine
    engine.model = run.model
    await engine.run()
    old, new = adapter.turn_id(engine.session_id, 1), adapter.turn_id(engine.session_id, 2)
    turns = AsyncMock(
        side_effect=[
            [{"id": old, "status": "completed"}],  # captured before sending
            [{"id": old, "status": "completed"}],  # API has not exposed new turn
            [{"id": old, "status": "completed"}, {"id": new, "status": "completed"}],
        ]
    )
    adapter.turns = turns
    await engine.continue_work("Create the consolidated answer", purpose="team_synthesis")
    await asyncio.wait_for(engine.run(), 1)
    assert turns.await_count == 3
    assert len(adapter.sessions[engine.session_id]["inputs"]) == 2
    assert engine.record["continuation"] is None


async def test_budget_resume_requires_new_authorized_revision():
    run = await mission(Adapter(), title="Write a short answer")
    engine = ManagedEngine(run, run.request)
    await engine.run()
    await engine.checkpoint(
        resume_required=True, pause_reason="waiting_for_budget", pause_budget_revision=1
    )
    run.budget_revision = 1
    with pytest.raises(RuntimePaused, match="Extend"):
        await engine.run()
    assert len(run.adapter.sessions[engine.session_id]["inputs"]) == 1
    run.budget_revision = 2
    old, new = run.adapter.turn_id(engine.session_id, 1), run.adapter.turn_id(engine.session_id, 2)
    run.adapter.turns = AsyncMock(
        side_effect=[
            [{"id": old, "status": "cancelled"}],
            [{"id": new, "status": "completed"}],
        ]
    )
    await engine.run()
    assert len(run.adapter.sessions[engine.session_id]["inputs"]) == 2


def test_budget_decision_cannot_approve_external_tool():
    from app.schemas import ResumeRequest

    runner.seed_decision(
        ResumeRequest(
            run_id="budget",
            decision="approved",
            command_id="command",
            payload={"runtime_budget_extended": True, "budget_revision": 2},
        )
    )
    assert runner.take_seeded_runtime_resume("budget").command_id == "command"
    assert runner.take_seeded_decision("budget", "send_email") is None


@pytest.mark.parametrize(
    "command",
    [
        "echo test",
        "printf build",
        "echo 'pytest'",
        "false || pytest",
        "python -c 'print(\"assert True\")'",
    ],
)
def test_words_are_not_execution_evidence(command):
    assert not verification_command(command)


@pytest.mark.parametrize(
    "command",
    [
        "cd /workspace && python -m pytest",
        "npm run build",
        "bash -lc 'pytest -q'",
        "python -c 'assert 2+2 == 4'",
    ],
)
def test_recognizes_real_verification_invocations(command):
    assert verification_command(command)


async def test_user_followup_changes_required_execution_capabilities():
    run = await mission(
        Adapter(), input={"instruction": "Écris et teste un script Python à partir des résultats."}
    )
    requirements = requirements_for(run.request)
    assert requirements.code and requirements.sandbox and requirements.artifact


async def test_three_colleagues_share_files_and_receive_one_consolidation_turn():
    class TeamAdapter(Adapter):
        async def start(self, configuration):
            session = await super().start(configuration)
            participant = configuration["metadata"]["mokaid_participant"]
            if participant != "lead":
                self.sessions[session["id"]]["actions"] = [
                    ("send_team_message", {"message": f"Findings from {participant}"}),
                    (
                        "save_deliverable",
                        {
                            "filename": f"{participant}.txt",
                            "content": f"Findings from {participant}",
                        },
                    ),
                ]
            return session

    names = ["Ada", "Navi", "Sira"]
    adapter = TeamAdapter(
        [
            (
                "delegate_work",
                {
                    "assignments": [
                        {
                            "colleague": name,
                            "brief": f"Inspect the existing context independently as {name}",
                        }
                        for name in names
                    ]
                },
            )
        ]
    )
    run = await mission(
        adapter,
        title="Coordinate the team answer",
        colleagues=[Colleague(id=name.lower(), name=name) for name in names],
    )
    state = await asyncio.wait_for(run.execute(), 3)
    assert state.status == RunStatus.COMPLETED
    assert len(adapter.sessions) == 4
    assert len(state.output["runtime"]["manifest"]) == 3
    assert len(run.team.messages) == 3
    assert len(adapter.sessions["session-1"]["inputs"]) == 2
    assert len(run.phoenix.completed) == 1
    assert (await run.store.get_execution(run.request.run_id))["synthesized"] is True


async def test_expired_sandbox_rotates_with_preserved_outputs_and_cumulative_cost():
    class ExpiredAdapter(Adapter):
        async def retrieve(self, sid):
            result = await super().retrieve(sid)
            if sid == "session-1" and not self.sessions[sid].get("canceled"):
                result["status"] = "requires_action"
                result["required_actions"] = [{"type": "environment_connection"}]
            return result

    adapter = ExpiredAdapter(
        commands=[
            {
                "id": "verified",
                "type": "command_execution",
                "command": "python -m pytest",
                "exit_code": 0,
            }
        ],
        artifacts=[("result.py", b"assert 2+2 == 4")],
    )
    run = await mission(adapter, title="Implement Python code and test it")
    state = await asyncio.wait_for(run.execute(), 3)
    assert state.status == RunStatus.COMPLETED
    assert len(adapter.sessions) == 2
    assert adapter.cancelled == ["session-1"]
    assert set(adapter.deleted) == {"session-1", "session-2"}
    assert len(run.phoenix.outputs) == 1
    saved = await run.store.get_execution(run.request.run_id)
    assert saved["archived_sessions"][0]["session_id"] == "session-1"
    from app.agents.runtime_cost import estimate_cents

    assert run.budget.usage[""] == 2 * estimate_cents(run.model, adapter.usage)


async def test_unknown_usage_is_not_free_and_is_visible_as_unavailable():
    run = await mission(Adapter(usage={}), title="Answer briefly: what is a tree?")
    state = await run.execute()
    assert state.status == RunStatus.COMPLETED
    settlement = [args for name, args in run.phoenix.calls if name == "settle"][-1]
    assert settlement["cost_cents"] is None and settlement["usage_status"] == "unknown"
    assert state.output["runtime"]["budget"]["used_credits"] is None
    assert not run.adapter.deleted


async def test_unconfirmed_stop_keeps_reservation_and_retries_without_work(monkeypatch):
    from app.agents import managed_runner
    from app.agents.runtime_cancellation import CancellationUnconfirmed

    run = await mission(Adapter(), title="Answer briefly")
    engine = ManagedEngine(run, run.request)
    await engine.run()
    await engine.checkpoint(reserved=True, budget_cents=50)
    await run.store.enqueue_command(run.request.run_id, "cancel", {}, "stop")
    original = managed_runner.cancel_and_confirm
    monkeypatch.setattr(
        managed_runner,
        "cancel_and_confirm",
        AsyncMock(side_effect=CancellationUnconfirmed(engine.session_id)),
    )
    with pytest.raises(CancellationUnconfirmed):
        await run.execute()
    assert not any(name == "settle" for name, _ in run.phoenix.calls)
    assert (await run.store.get_execution(run.request.run_id))["stop_intent"][
        "status"
    ] == "canceled"
    monkeypatch.setattr(managed_runner, "cancel_and_confirm", original)
    state = await resume(run).execute()
    assert state.status == RunStatus.CANCELED
    assert len(run.adapter.sessions) == 1
    assert any(name == "settle" for name, _ in run.phoenix.calls)


async def test_comment_resume_reconfigures_none_environment_for_code_without_new_budget():
    from app.schemas import ResumeRequest

    adapter = Adapter(
        commands=[{"id": "test", "type": "command_execution", "command": "pytest", "exit_code": 0}],
        artifacts=[("result.py", b"assert 1 == 1")],
    )
    run = await mission(adapter, title="Answer briefly")
    engine = ManagedEngine(run, run.request)
    await engine.run()
    await engine.checkpoint(
        reserved=True, budget_cents=50, requirements={"sandbox": False}, resume_required=True
    )
    runner.seed_decision(
        ResumeRequest(
            run_id=run.request.run_id,
            decision="approved",
            command_id="comment",
            payload={"runtime_user_input": True, "instruction": "Create and test a Python script"},
        )
    )
    state = await resume(run).execute()
    assert state.status == RunStatus.COMPLETED
    assert len(adapter.sessions) == 2
    assert adapter.configurations[-1]["environment"]["type"] == "openai_hosted"
    assert "Create and test a Python script" in adapter.sessions["session-2"]["inputs"][0]
    assert all(
        params.get("recovery") is True
        for action, params in run.phoenix.calls
        if action == "reserve"
    )
    assert (await run.store.get_execution(run.request.run_id))["resume_command_id"] == "comment"


async def test_one_unreachable_session_does_not_prevent_stopping_other_participants(monkeypatch):
    from app.agents import managed_runner
    from app.agents.runtime_cancellation import CancellationUnconfirmed

    run = await mission(Adapter(), title="Answer briefly")
    called = []

    async def cancel(adapter, sid, **_kwargs):
        called.append(sid)
        if sid == "lead-session":
            raise CancellationUnconfirmed(sid)

    monkeypatch.setattr(managed_runner, "cancel_and_confirm", cancel)
    for participant, sid in [("", "lead-session"), ("colleague", "child-session")]:
        engine = ManagedEngine(run, run.request, participant)
        engine.session_id = sid
        run.engines[participant] = engine
    with pytest.raises(CancellationUnconfirmed):
        await run.stop_remote()
    assert set(called) == {"lead-session", "child-session"}


async def test_connector_call_refreshes_secret_without_persisting_or_returning_it(monkeypatch):
    from app.mcp.client import McpToolbox

    run = await mission(Adapter(), title="Read my connector")
    name = "mcp:crm:list_contacts"
    run.mcp_tools = [{"name": name}]
    engine = ManagedEngine(run, run.request)
    engine.authorize = AsyncMock(
        side_effect=[
            {
                "allowed": True,
                "mcp_server": {
                    "key": "crm",
                    "name": "CRM",
                    "url": "https://connector.test/mcp",
                    "credentials": {"token": token},
                },
            }
            for token in ("old-token", "rotated-token")
        ]
    )
    observed = []

    async def call(_self, grant, tool, arguments):
        observed.append(grant.credentials["token"])
        return {"contacts": []}

    monkeypatch.setattr(McpToolbox, "_call_tool", call)
    assert await engine.invoke_registered(name, {}) == {"contacts": []}
    assert await engine.invoke_registered(name, {}) == {"contacts": []}
    assert observed == ["old-token", "rotated-token"]
    assert "rotated-token" not in str(await run.store.get_run(run.request.run_id))
