"""Offline acceptance tests for the real managed mission and function bridge."""

import asyncio
import base64
import json
from copy import deepcopy
from io import BytesIO
from unittest.mock import AsyncMock

import pytest

from app.agents import managed_runner
from app.agents.managed_runner import ManagedEngine, ManagedMission
from app.agents.runtime import Requirements, RuntimeResult
from app.agents.runtime_cost import estimate_cents
from app.config import get_settings
from app.mcp.client import McpToolbox
from app.runtime_store import MemoryStore
from app.schemas import Colleague, RunRequest, RunState, RunStatus, ToolCall


class Phoenix:
    def __init__(self, request):
        self.request = request
        self.events = []
        self.outputs = []
        self.completed = []
        self.calls = []

    async def runtime_call(self, run_id, workspace_id, action, **kwargs):
        assert run_id == self.request.run_id
        assert workspace_id == self.request.workspace_id
        self.calls.append((action, kwargs))
        if action == "authorize":
            return {"allowed": True, "runtime_policy": {"verified_models": ["gpt-6-sol", "gpt-6-astra"]},
                    "autonomy": self.request.autonomy, "agent": self.request.agent}
        if action == "reserve":
            cents = 200 if kwargs.get("complexity") == "complex" else 50
            return {"reserved": True, "budget_cents": cents, "reserved_credits": cents * 10}
        if action == "participants":
            return {"reserved": True}
        if action == "settle":
            return {"settled": True, "status": "settled"}
        if action == "release-participant":
            return {"released": True}
        raise AssertionError(f"Unexpected authority call: {action}")

    async def post_tool_activity(self, _run_id, event):
        self.events.append(deepcopy(event))

    async def save_task_output(self, workspace, task, filename, content, **kwargs):
        assert workspace == self.request.workspace_id and task == self.request.task_id
        assert kwargs["artifact_key"]
        raw = base64.b64decode(content) if kwargs.get("encoding") == "base64" else content.encode()
        self.outputs.append({"id": f"file-{len(self.outputs) + 1}", "name": filename, "bytes": raw, **kwargs})
        return self.outputs[-1]

    async def update_run_status(self, *_args, **_kwargs):
        return None

    async def post_task_comment(self, *_args, **_kwargs):
        return True

    async def complete_run(self, _run_id, output, **kwargs):
        self.completed.append(deepcopy(output))

    async def finalize_runtime(self, run_id, status, output, cost_cents=0):
        assert run_id == self.request.run_id
        if status == "completed":
            self.completed.append(deepcopy(output))
        return {"status": status}

    async def request_approval(self, *_args, **_kwargs):
        return {"id": "approval-one"}


class Adapter:
    """Scripted provider resources; actual worker orchestration is unmodified."""

    def __init__(self, actions=(), *, commands=(), artifacts=(), usage=None, hold=False, fail_after=None):
        self.actions = list(actions)
        self.commands = list(commands)
        self.published = list(artifacts)
        self.usage = usage if usage is not None else {"input_tokens": 100, "output_tokens": 40}
        self.hold, self.fail_after = hold, fail_after
        self.sessions = {}
        self.configurations = []
        self.results = []
        self.cancelled = []
        self.deleted = []
        self.closed = False

    async def start(self, configuration):
        if configuration["environment"]["type"] == "none":
            assert configuration.get("input"), "SDK requires initial input for environment=none"
        self.configurations.append(deepcopy(configuration))
        sid = f"session-{len(self.sessions) + 1}"
        participant = configuration["metadata"]["mokaid_participant"]
        self.sessions[sid] = {"index": 0, "inputs": [configuration["input"]] if configuration.get("input") else [],
                              "actions": deepcopy(self.actions) if participant == "lead" else [],
                              "configuration": deepcopy(configuration)}
        return {"id": sid, "status": "in_progress" if configuration.get("input") else "idle"}

    async def find_session(self, creation_id):
        for sid, record in self.sessions.items():
            if record["configuration"]["metadata"].get("mokaid_creation_id") == creation_id:
                return {"id": sid}
        return None

    async def continue_session(self, sid, text):
        self.sessions[sid]["canceled"] = False
        self.sessions[sid]["inputs"].append(text)

    async def retrieve(self, sid):
        record = self.sessions[sid]
        if record.get("canceled"):
            return {"id": sid, "status": "idle", "usage": deepcopy(self.usage), "required_actions": []}
        index, actions = record["index"], record["actions"]
        pending = []
        if index < len(actions):
            name, arguments = actions[index]
            pending = [{"type": "function_call", "name": name, "arguments": arguments,
                        "call_id": f"call-{index}", "turn_id": f"turn-{sid}"}]
        failed = self.fail_after is not None and index >= self.fail_after
        status = "failed" if failed else "requires_action" if pending else "in_progress" if self.hold else "idle"
        return {"id": sid, "status": status, "usage": deepcopy(self.usage), "required_actions": pending}

    async def items(self, sid):
        record = self.sessions[sid]
        messages = [{"type": "message", "role": "user", "status": "completed", "turn_id": self.turn_id(sid, index + 1), "content": [{"type": "input_text", "text": text}]} for index, text in enumerate(record["inputs"])]
        if record["index"] >= len(record["actions"]) and not self.hold:
            messages.append({"id": "answer", "type": "message", "role": "assistant", "phase": "final_answer", "status": "completed", "turn_id": self.turn_id(sid),
                             "content": [{"type": "output_text", "text": "Result with verified public findings: https://example.test/source"}]})
        return messages + deepcopy(self.commands)

    def turn_id(self, sid, index=None):
        count = index if index is not None else len(self.sessions[sid]["inputs"])
        return f"turn-{sid}" + (f"-{count}" if count > 1 else "")

    async def turns(self, sid):
        return [{"id": self.turn_id(sid), "subagent_id": None,
                 "status": "cancelled" if self.sessions[sid].get("canceled") else "completed"}]

    async def tool_result(self, sid, action, result):
        self.results.append((sid, action["call_id"], deepcopy(result)))
        if sid in self.sessions:
            self.sessions[sid]["index"] += 1

    async def artifacts(self, sid):
        return [{"id": f"artifact-{i}", "path": filename, "size_bytes": len(raw)} for i, (filename, raw) in enumerate(self.published)]

    async def artifact_content(self, sid, artifact_id, max_bytes):
        return self.published[int(artifact_id.split("-")[-1])][1]

    async def cancel(self, sid):
        self.cancelled.append(sid)
        if sid in self.sessions:
            self.sessions[sid]["canceled"] = True

    async def delete(self, sid):
        self.deleted.append(sid)

    async def close(self):
        self.closed = True


@pytest.fixture(autouse=True)
def managed_test_config(monkeypatch):
    from app import runtime_dispatch
    settings = get_settings().model_copy(update={"openai_agents_poll_seconds": 0.005,
        "openai_agents_usage_grace_seconds": 0.02})
    monkeypatch.setattr(managed_runner, "get_settings", lambda: settings)
    monkeypatch.setattr(runtime_dispatch, "assert_lease", AsyncMock())


async def mission(adapter, *, title="Research current information", **kwargs):
    request = RunRequest(run_id="mission-one", workspace_id="workspace-one", task_id="task-one",
                         agent_id="lead", task_title=title,
                         agent=kwargs.pop("agent", {"display_name": "Sira"}), **kwargs)
    store = MemoryStore()
    await store.accept_run(request.model_dump(mode="json"))
    phoenix = Phoenix(request)
    result = ManagedMission(request, RunState(run_id=request.run_id), phoenix, McpToolbox([]), [],
                            AsyncMock(), store, adapter)
    return result


async def test_research_function_runs_and_real_file_is_saved_before_completion(monkeypatch):
    search = AsyncMock(return_value={"results": [{"url": "https://example.test/source", "title": "Source"}]})
    monkeypatch.setattr(managed_runner, "get_tool", lambda name: search if name == "web_search" else None)
    adapter = Adapter([("web_search", {"query": "verified sources"}),
                       ("save_deliverable", {"filename": "report.md", "content": "# Findings\nhttps://example.test/source"})])
    run = await mission(adapter, title="Research and write a report on public information")
    state = await asyncio.wait_for(run.execute(), 3)
    assert state.status == RunStatus.COMPLETED
    search.assert_awaited_once()
    assert run.phoenix.outputs[0]["bytes"].startswith(b"# Findings")
    assert state.output["runtime"]["manifest"][0]["id"] == "file-1"
    assert all(check["passed"] for check in state.output["runtime"]["verification"]["checks"])
    assert run.phoenix.completed and adapter.deleted == ["session-1"]
    assert all(event["id"].startswith("mission-one:") for event in run.phoenix.events)


async def test_environment_none_sends_required_input_only_once(monkeypatch):
    search = AsyncMock(return_value={"results": []})
    monkeypatch.setattr(managed_runner, "get_tool", lambda _name: search)
    adapter = Adapter([("web_search", {"query": "current news"})])
    run = await mission(adapter, input={"instruction": "Compare the latest findings with our earlier report."},
                        agent={"display_name": "Sira", "instructions": "Cite the evidence behind every conclusion."})
    state = await asyncio.wait_for(run.execute(), 3)
    assert state.status == RunStatus.COMPLETED
    assert adapter.configurations[0]["environment"]["type"] == "none"
    assert len(adapter.sessions["session-1"]["inputs"]) == 1
    assert adapter.configurations[0]["metadata"]["mokaid_creation_id"]
    wire = json.dumps(adapter.configurations[0])
    assert "Compare the latest findings with our earlier report." in wire
    assert "Cite the evidence behind every conclusion." in wire


async def test_teammate_binary_document_is_read_as_evidence_before_synthesis():
    from docx import Document

    document = Document()
    document.add_paragraph("Observed result: seven indexed product pages.")
    content = BytesIO()
    document.save(content)
    run = await mission(Adapter())
    run.read_file = AsyncMock(return_value=(content.getvalue(), {
        "name": "colleague-report.docx",
        "mime_type": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    }))
    engine = ManagedEngine(run, run.request)
    engine.configure_tools()
    result = await engine.tools["read_team_artifact"].ainvoke({"file_id": "teammate-document"})
    assert "seven indexed product pages" in result["content"]
    assert result["file_id"] == "teammate-document"
    assert result["truncated"] is False
    run.read_file.assert_awaited_once_with(engine, "teammate-document", shared_only=True)


async def test_sandbox_configuration_does_not_leak_connector_secrets_or_enable_native_team():
    run = await mission(Adapter(), agent={"display_name": "Sira", "credentials": {"token": "persona-secret"}},
                        input={"api_key": "input-secret"}, runtime_policy={"private_setting": "policy-secret"},
                        mcp_servers=[{"key": "mail", "name": "Mail", "url": "https://private.test", "credentials": {"api_key": "connector-secret"}}])
    engine = ManagedEngine(run, run.request)
    engine.model = "gpt-6-sol"
    configuration = await engine.configuration(Requirements(sandbox=True))
    wire = json.dumps(configuration)
    assert not any(secret in wire for secret in ("persona-secret", "input-secret", "policy-secret", "connector-secret"))
    assert configuration["environment"]["network"] == {"access": "disabled"}
    assert configuration["agent"]["multi_agent"] == {"enabled": False}
    assert all(tool["type"] == "function" for tool in configuration["agent"]["tools"])


async def test_budget_is_shared_by_parent_and_colleague_and_cancels_both():
    adapter = Adapter([("delegate_work", {"assignments": [{"colleague": "Navi", "brief": "Inspect public information independently"}]})],
                      usage={"input_tokens": 50_000, "output_tokens": 0}, hold=True)
    run = await mission(adapter, colleagues=[Colleague(id="navi", name="Navi")])
    state = await asyncio.wait_for(run.execute(), 3)
    assert len(adapter.sessions) == 2
    assert state.status == RunStatus.WAITING_FOR_USER_INPUT
    assert state.output["runtime"]["status"] == "waiting_for_budget"
    assert len(adapter.cancelled) == 2
    assert not run.phoenix.completed
    assert state.output["runtime"]["budget"]["limit_credits"] == 500


async def test_external_effect_result_replays_across_provider_sessions_without_reexecution(monkeypatch):
    send = AsyncMock(return_value={"sent": True, "message_id": "mail-one"})
    monkeypatch.setattr(managed_runner, "get_tool", lambda _name: send)
    run = await mission(Adapter(), title="Send the requested message", autonomy={"rules": [{"tool_pattern": "send_email", "behavior": "allow"}]})
    engine = ManagedEngine(run, run.request)
    engine.configure_tools()
    engine.session_id = "old-session"
    action = {"name": "send_email", "arguments": {"to": "person@example.test", "subject": "Update", "body": "Approved content"}, "turn_id": "old-turn", "call_id": "old-call"}
    await engine.handle_action(action)
    engine.session_id = "new-session"
    await engine.handle_action({**action, "turn_id": "new-turn", "call_id": "new-call"})
    send.assert_awaited_once()
    assert len(run.adapter.results) == 2
    assert run.adapter.results[0][2] == run.adapter.results[1][2]


@pytest.mark.parametrize("command, exit_code, delivered", [("python -m pytest", 0, True), ("python -m pytest", 1, False), (None, None, False), ("echo test", 0, False)])
async def test_executable_delivery_requires_actual_successful_verification(command, exit_code, delivered):
    commands = [] if command is None else [{"id": "command-1", "type": "command_execution", "command": command, "exit_code": exit_code, "status": "completed", "output": "Recorded command output"}]
    adapter = Adapter(commands=commands, artifacts=[("/workspace/outputs/result.json", b'{"result":42}')])
    run = await mission(adapter, title="Implement the codebase and deliver the document")
    state = await asyncio.wait_for(run.execute(), 3)
    assert (state.status == RunStatus.COMPLETED) is delivered
    assert bool(run.phoenix.completed) is delivered
    assert run.phoenix.outputs  # Incomplete runs still retain valid partial files.


async def test_failure_preserves_saved_partial_files_and_never_claims_completion():
    adapter = Adapter([("save_deliverable", {"filename": "notes.txt", "content": "Useful partial findings"})], fail_after=1)
    run = await mission(adapter, title="Write the requested document")
    state = await asyncio.wait_for(run.execute(), 3)
    assert state.status == RunStatus.FAILED
    assert state.output["runtime"]["manifest"][0]["id"] == "file-1"
    assert run.phoenix.outputs[0]["bytes"] == b"Useful partial findings"
    assert not run.phoenix.completed
    assert not adapter.deleted
    assert adapter.cancelled and adapter.closed


async def test_completed_colleague_keeps_archived_session_costs_and_evidence_during_work():
    run = await mission(Adapter(), title="Answer this question", colleagues=[Colleague(id="navi", name="Navi")])
    team = {"participants": [{"agent_id": "navi", "name": "Navi", "brief": "Explain the relevant findings", "status": "completed", "summary": "Complete contribution", "artifacts": []}], "messages": []}
    saved = await run.store.save_execution(run.request.run_id, session_id="lead-session", model="gpt-6-sol", team=team,
        result=RuntimeResult(summary="Consolidated answer").to_dict(), usage={"input_tokens": 100, "output_tokens": 0}, synthesized=True)
    await run.store.save_execution(run.request.run_id, "navi", session_id="child-current", model="gpt-6-sol",
        status="completed", result=RuntimeResult(summary="Complete contribution").to_dict(), requirements={"sandbox": True}, active_seconds=20,
        usage={"input_tokens": 1000, "output_tokens": 0}, tool_cost_cents=2,
        tool_calls=[ToolCall(tool="web_search", input={"query": "evidence"}, agent_id="navi", output={"results": []}).model_dump(mode="json")],
        archived_sessions=[{"session_id": "child-old", "model": "gpt-6-sol", "usage": {"input_tokens": 10_000, "output_tokens": 0}}])
    await run.restore_engines(saved)
    original_child = run.engines["navi"]
    expected_usage = estimate_cents("gpt-6-sol", {"input_tokens": 1000, "output_tokens": 0}) + estimate_cents("gpt-6-sol", {"input_tokens": 10_000, "output_tokens": 0})
    assert run.budget.usage["navi"] == pytest.approx(expected_usage)
    assert run.budget.tool_cents["sandbox:navi"] == 6
    run.engines[""].run = AsyncMock(return_value=run.engines[""].result)
    original_child.run = AsyncMock(side_effect=AssertionError("A completed colleague must not execute again"))
    before = run.budget.estimated_cents
    await run.work()
    assert run.engines["navi"] is original_child
    assert run.budget.estimated_cents == before
    assert run.engines["navi"].tool_calls[0].agent_id == "navi"
    original_child.run.assert_not_awaited()


async def test_continuation_waits_for_its_own_final_message_when_items_lag_turns():
    run = await mission(Adapter(), title="Answer this question")
    engine = ManagedEngine(run, run.request)
    await engine.run()
    def final(turn, text):
        return {"id": f"answer-{turn}", "type": "message", "role": "assistant", "phase": "final_answer", "status": "completed", "turn_id": turn,
                "content": [{"type": "output_text", "text": text}]}
    old = final("old-turn", "Waiting for colleagues")
    fresh = final("new-turn", "Fresh consolidated answer")
    run.adapter.turns = AsyncMock(side_effect=[
        [{"id": "old-turn", "status": "completed"}],
        [{"id": "new-turn", "status": "completed"}],
        [{"id": "new-turn", "status": "completed"}],
    ])
    run.adapter.items = AsyncMock(side_effect=[[old], [old], [old, fresh]])
    await engine.continue_work("Consolidate the colleagues' findings", purpose="team_synthesis")
    result = await asyncio.wait_for(engine.run(), 1)
    assert result.summary == "Fresh consolidated answer"
