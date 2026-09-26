"""Research must use evidence before the same graph can close a mission."""

from unittest.mock import AsyncMock

import pytest
from langchain_core.messages import AIMessage

from app.agents import deep_runner
from app.schemas import RunRequest, RunState, RunStatus, ToolCall
from app.tools.registry import RunContext


def engine(phoenix, brief="Recherche les tarifs publics de mokaid.com", **kwargs):
    request = RunRequest(run_id="r", workspace_id="ws", task_id="t", task_title=brief, **kwargs)
    return deep_runner._Engine(
        request, RunContext(run_id="r", workspace_id="ws", task_id="t"),
        RunState(run_id="r", status=RunStatus.RUNNING), phoenix, None, [], AsyncMock(),
    )


def answer(text, **kwargs):
    return {"messages": [AIMessage(content=text)], **kwargs}


def evidence():
    return ToolCall(tool="web_search", input={"query": "mokaid"}, output={
        "results": [{"title": "Prices", "url": "https://mokaid.com/pricing", "snippet": "Public plans"}],
    })


async def test_refusal_is_repaired_in_existing_state_once(phoenix):
    agent = engine(phoenix)
    initial = answer("I'm unable to perform live searches.", files={"/notes.txt": {"content": ["Keep my notes"]}})

    class Graph:
        calls = []

        async def astream(self, state, **kwargs):
            self.calls.append(state)
            agent.state.tool_calls.append(evidence())
            yield answer("Les offres publiques figurent sur https://mokaid.com/pricing")

    graph = Graph()
    _, review = await agent._research_and_repair(graph, initial, {}, checkpointed=False)
    assert review["status"] == "passed"
    assert len(graph.calls) == 1
    assert graph.calls[0]["files"] == initial["files"]
    assert "Do not repeat successful work" in graph.calls[0]["messages"][-1]["content"]
    assert len(agent.state.tool_calls) == 1


async def test_repair_does_not_loop_when_model_still_refuses(phoenix):
    agent = engine(phoenix)

    class Graph:
        calls = 0

        async def astream(self, state, **kwargs):
            self.calls += 1
            assert len(state["messages"]) == 1  # Checkpoint adds only new feedback.
            yield answer("Je suis prêt à vous aider.")

    graph = Graph()
    _, review = await agent._research_and_repair(graph, answer("Je suis prêt."), {}, checkpointed=True)
    assert graph.calls == 1
    assert review["status"] == "needs_changes"


@pytest.mark.parametrize("restriction", ["disabled", "denied", "rejected", "policy"])
async def test_repair_respects_unavailable_or_refused_actions(phoenix, restriction):
    agent = engine(phoenix)
    if restriction == "disabled":
        agent.disabled_tools = ["web_*"]
    elif restriction == "denied":
        agent.policy.rules = [{"tool_pattern": "web_search", "behavior": "deny"}]
    elif restriction == "rejected":
        agent.state.tool_calls.append(ToolCall(tool="web_search", input={}, approved=False))
    text = "I cannot help with this harmful request due to content policy." if restriction == "policy" else "No research."
    graph = AsyncMock()
    _, review = await agent._research_and_repair(graph, answer(text), {}, checkpointed=False)
    assert review["status"] == "needs_changes"
    graph.astream.assert_not_called()


def test_report_needs_document_and_actual_source(phoenix):
    agent = engine(phoenix, "Research and report Google indexation and SEO visibility status of mokaid.com")
    agent.state.tool_calls.append(evidence())
    assert any("written report" in issue for issue in agent._research_findings(answer("See https://mokaid.com/pricing")))
    report = answer("Rapport livré.", files={"/deliverables/seo.md": {"content": ["Source: https://mokaid.com/pricing"]}})
    assert agent._research_findings(report) == []
    report["files"]["/deliverables/seo.md"]["content"] = ["Trust me, it is indexed."]
    assert any("source URLs" in issue for issue in agent._research_findings(report))


def test_empty_search_is_valid_evidence_and_denied_search_is_not(phoenix):
    agent = engine(phoenix)
    agent.state.tool_calls.append(ToolCall(tool="web_search", input={}, output={"results": []}))
    assert agent._research_findings(answer("La recherche n’a retourné aucun résultat ; l’indexation reste à vérifier.")) == []
    assert agent._research_findings(answer("Done."))
    assert agent._research_findings(answer("I'll research it."))
    agent.state.tool_calls[0].approved = False
    assert agent._research_findings(answer("Aucun résultat."))


def test_malformed_search_payload_does_not_crash_verification(phoenix):
    agent = engine(phoenix)
    agent.state.tool_calls.append(ToolCall(tool="web_search", input={}, output={"results": None}))
    assert agent._research_findings(answer("Done."))


def test_packaging_existing_research_does_not_restart_research(phoenix):
    agent = engine(phoenix, "Research report", input={"instruction": "Export the completed report as a PDF"})
    assert agent._research_findings(answer("PDF exported.")) == []
    agent.request.input["instruction"] = "Export the report and verify the latest pricing"
    assert agent._research_findings(answer("Done."))


def test_full_answer_and_late_sources_are_preserved(phoenix):
    agent = engine(phoenix)
    agent.state.tool_calls.append(evidence())
    text = "Constat détaillé. " * 130 + "Source : https://mokaid.com/pricing"
    assert deep_runner._final_message(answer(text)) == text
    assert agent._research_findings(answer(text)) == []
