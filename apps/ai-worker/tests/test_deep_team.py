"""Integration boundaries for real, scoped colleague execution."""

import asyncio
from unittest.mock import AsyncMock

import pytest
from langchain_core.messages import AIMessage, ToolMessage

from app.agents import deep_runner
from app.agents.team import TeamAssignment
from app.schemas import Colleague, RunRequest, RunState, RunStatus
from app.tools.registry import RunContext


def engine(phoenix, **kwargs):
    request = RunRequest(
        run_id="team-run", workspace_id="ws", task_id="task", agent_id="lead",
        task_title="Préparer les supports de lancement",
        colleagues=[Colleague(id="writer", name="Rédacteur", agent={"instructions": "Keep it concise."})],
        **kwargs,
    )
    phoenix.post_tool_activity = AsyncMock()
    return deep_runner._Engine(
        request, RunContext(run_id=request.run_id, workspace_id="ws", task_id="task"),
        RunState(run_id=request.run_id, status=RunStatus.RUNNING), phoenix, None, [], AsyncMock(),
    )


async def test_colleague_uses_own_knowledge_scope_and_real_internal_tools(phoenix, monkeypatch):
    import langchain.agents

    agent = engine(phoenix, autonomy={"rules": [{"tool_pattern": "web_search", "behavior": "deny"}]})
    agent.request.colleagues[0].agent["tool_preferences"] = {"disabled": ["transform_image"]}
    seen = {}

    async def tool(params, ctx):
        seen["context"] = ctx
        return {"content": "Une contribution concrète.", "title": params.get("title", "Notes")}

    def create_graph(**kwargs):
        available = {tool.name: tool for tool in kwargs["tools"]}
        seen["tools"] = available
        seen["prompt"] = kwargs["system_prompt"]

        class Graph:
            async def astream(self, state, **config):
                await available["search_knowledge"].ainvoke({"query": "Positionnement"})
                await available["send_team_message"].ainvoke({"message": "J’ai trouvé le positionnement dans nos notes."})
                await available["draft_document"].ainvoke({"title": "Lancement", "brief": "Préparer les supports"})
                yield {"messages": [AIMessage(content="Les supports de lancement sont rédigés.")]}

        return Graph()

    monkeypatch.setattr(langchain.agents, "create_agent", create_graph)
    monkeypatch.setattr(deep_runner, "_build_model", lambda *_: object())
    monkeypatch.setattr(deep_runner, "get_tool", lambda _: tool)
    await agent.team.start([TeamAssignment(colleague="writer", brief="Rédige les supports de lancement à partir de nos notes.")])
    result = await agent.team.collect()
    assert result["participants"][0]["status"] == "completed"
    assert seen["context"].agent_id == "writer"
    assert seen["context"].task_id == "task"
    assert seen["context"].usage is not agent.ctx.usage
    assert "Keep it concise." in seen["prompt"]
    assert not ({"web_search", "transform_image", "send_email", "update_task", "delegate_work", "task"} & seen["tools"].keys())
    assert all(call.agent_id == "writer" for call in agent.state.tool_calls)
    assert any("Rédacteur — Lancement" == call.input.get("title") for call in agent.state.tool_calls)
    assert result["messages"][0]["agent_id"] == "writer"
    events = [call.args[1] for call in phoenix.post_tool_activity.call_args_list]
    assert all(event["id"].startswith("team-run:team:writer:") for event in events)


async def test_lead_cannot_finish_before_collecting_and_synthesizing(phoenix):
    agent = engine(phoenix)
    ready = asyncio.Event()

    async def contribute(*_):
        await ready.wait()
        return {"summary": "Contribution indépendante terminée."}

    agent.team.execute = contribute
    await agent.team.start([TeamAssignment(colleague="writer", brief="Rédige les notes du lancement.")])

    class Graph:
        inputs = []

        async def astream(self, value, **kwargs):
            self.inputs.append(value)
            yield {"messages": [AIMessage(content="Livraison consolidée avec Rédacteur.")]}

    graph = Graph()
    finished = asyncio.create_task(agent._consolidate_team(graph, {}, {}, checkpointed=False))
    await asyncio.sleep(0)
    assert not finished.done()
    ready.set()
    output = await finished
    assert "consolidée" in output["messages"][0].content
    assert "Contribution indépendante terminée" in graph.inputs[0]["messages"][-1]["content"]
    assert agent.team.collected


def test_delegation_can_be_disabled_without_hiding_core_tools(phoenix):
    agent = engine(phoenix, autonomy={"rules": [{"tool_pattern": "delegate_work", "behavior": "deny"}]})
    names = {tool.name for tool in agent._build_tools()}
    assert "delegate_work" not in names
    assert "web_search" in names


async def test_disabled_tool_is_also_denied_at_execution(phoenix, monkeypatch):
    agent = engine(phoenix, agent={"tool_preferences": {"disabled": ["web_*"]}})
    lookup = AsyncMock()
    monkeypatch.setattr(deep_runner, "get_tool", lookup)
    result = await agent._run_tool("web_search", {"query": "test"})
    assert result["skipped"]
    assert agent.state.tool_calls[0].approved is False
    lookup.assert_not_called()
    await asyncio.gather(*agent._activity_bg)


async def test_resume_restores_completed_contribution_evidence_and_cost_without_repeating(phoenix, monkeypatch):
    import deepagents

    from app import persistence
    from app.agents import runner

    agent = engine(phoenix)
    agent.request.input["_team_state"] = {
        "participants": [{
            "agent_id": "writer", "name": "Rédacteur", "brief": "Rédige les supports du lancement.",
            "status": "completed", "summary": "Supports prêts.", "artifacts": ["launch.pdf"],
            "tool_calls": [{"tool": "draft_document", "agent_id": "writer", "input": {}, "output": {
                "content": "Supports prêts.", "_saved_artifacts": ["launch.pdf"],
            }}],
            "usage": {"prompt_tokens": 40, "completion_tokens": 20, "images": 0, "cost_usd": 0.04},
        }],
        "messages": [],
    }
    execute = AsyncMock(side_effect=AssertionError("completed work must not repeat"))
    agent.team.execute = execute

    class Graph:
        inputs = []

        async def astream(self, value, **kwargs):
            self.inputs.append(value)
            yield {"messages": [AIMessage(content="Livraison réunie avec Rédacteur : launch.pdf.")]}

    graph = Graph()
    monkeypatch.setattr(deepagents, "create_deep_agent", lambda **_: graph)
    monkeypatch.setattr(deep_runner, "_build_model", lambda *_: object())
    monkeypatch.setattr(persistence, "get_checkpointer", AsyncMock(return_value=object()))
    result = await agent.run(resume=True)
    assert graph.inputs[0] is None
    assert len(graph.inputs) == 2  # Resumed graph + mandatory consolidation.
    assert agent.ctx.usage.prompt_tokens == 40
    assert agent.ctx.usage.cost_cents == 4
    assert agent.state.tool_calls[0].agent_id == "writer"
    assert await runner._save_artifacts(agent.request, agent.state, phoenix) == ["launch.pdf"]
    assert not any(kind == "output" for kind, _ in phoenix.calls)
    assert result["team"]["participants"][0]["status"] == "completed"
    assert "tool_calls" not in result["team"]["participants"][0]
    execute.assert_not_called()


async def test_missing_team_checkpoint_cannot_turn_into_a_success(phoenix):
    agent = engine(phoenix)
    lost = {"messages": [ToolMessage(
        name="delegate_work", tool_call_id="delegation", content='{"started":[{"agent_id":"writer"}]}',
    )]}
    with pytest.raises(RuntimeError, match="team_recovery_required"):
        await agent._consolidate_team(None, lost, {}, checkpointed=True)


async def test_failed_research_preserves_partial_output_and_usage(phoenix):
    from app.agents.runner import _fail_research

    agent = engine(phoenix)
    phoenix.update_run_status = AsyncMock()
    output = {"artifacts": ["partial.pdf"], "team": {"participants": [{"name": "Rédacteur", "status": "failed"}]}}
    await _fail_research(agent.request, agent.state, phoenix, output, ["No search evidence"], ctx=agent.ctx)
    persisted = phoenix.update_run_status.call_args.kwargs["extra"]
    assert persisted["output"]["artifacts"] == ["partial.pdf"]
    assert persisted["output"]["team"] == output["team"]
    assert persisted["token_usage"] == agent.ctx.usage.as_dict()
    assert agent.state.status == RunStatus.FAILED
