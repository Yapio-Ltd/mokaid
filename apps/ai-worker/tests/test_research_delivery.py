"""Research must use permitted evidence, then actually deliver its answer."""

from unittest.mock import AsyncMock

import pytest

import app.tools.web  # noqa: F401 — register the live search tool
from app import llm
from app.agents import acknowledge, runner
from app.agents.mission_kind import (
    detect_mission_kind,
    requires_web_research,
    research_report_requested,
    web_search_succeeded,
)
from app.schemas import RunRequest, RunState, RunStatus, ToolCall
from app.tools import registry
from app.tools.registry import RunContext


def request(title="Research mokaid.com Google indexation", **kwargs):
    return RunRequest(run_id="research-regression", workspace_id="w", task_id="t", task_title=title, **kwargs)


def search_call(output=None, **kwargs):
    return ToolCall(tool="web_search", input={"query": "site:mokaid.com"}, output=output, **kwargs)


def fake_engine(monkeypatch, summary, calls=(), **output):
    async def execute(_request, _ctx, state, *_args, **_kwargs):
        state.tool_calls.extend(calls)
        return {"summary": summary, "artifacts": [], **output}

    monkeypatch.setattr(runner.deep_runner, "is_available", lambda: True)
    monkeypatch.setattr(runner.deep_runner, "execute", execute)


def test_acknowledgement_uses_registered_permitted_tools():
    capabilities = "\n".join(acknowledge._capabilities(request(), []))
    assert "web_search:" in capabilities
    restricted = request(
        agent={"tool_preferences": {"disabled": ["web_*"]}},
        autonomy={"rules": [{"tool_pattern": "draft_*", "behavior": "deny"}]},
    )
    capabilities = "\n".join(acknowledge._capabilities(restricted, [
        {"name": "mcp:seo:read_metrics", "description": "Read connected metrics"},
    ]))
    assert "web_search:" not in capabilities
    assert "draft_document:" not in capabilities
    assert "mcp:seo:read_metrics" in capabilities


@pytest.mark.parametrize("response", [
    {"feasible": False, "reply": "I don't have the ability to perform live Google searches."},
    {"feasible": True, "reply": "I'm unable to complete this research directly."},
])
async def test_acknowledgement_does_not_publish_premature_refusal(monkeypatch, response):
    monkeypatch.setattr(llm, "is_configured", lambda: True)
    chat = AsyncMock(return_value=response)
    monkeypatch.setattr(llm, "chat_json", chat)
    reply = await acknowledge.build_acknowledgement(request(), llm.UsageTracker())
    assert "checking the available evidence" in reply
    assert "web_search:" in chat.call_args.kwargs["system"]
    assert "Search Console" in chat.call_args.kwargs["system"]


def test_report_keeps_research_requirement_for_seo_review():
    req = request("Research and report Google indexation and SEO visibility status of mokaid.com")
    assert detect_mission_kind(req) == "research"
    assert requires_web_research(req)
    assert research_report_requested(req)
    assert research_report_requested(request("Rédige un rapport sur l'indexation SEO de mokaid.com"))
    assert not research_report_requested(request())
    assert not requires_web_research(request("Audit de sécurité des fichiers joints"))


@pytest.mark.parametrize("call, expected", [
    (search_call({"results": []}), True),
    (search_call({"results": [{"url": "https://mokaid.com"}]}), True),
    (search_call({"results": [], "error": "network down"}), False),
    (search_call({"results": []}, approved=False), False),
    (search_call({"results": "not a result list"}), False),
    (search_call({"skipped": True}), False),
])
def test_research_evidence_accepts_empty_results_but_not_failed_or_denied_calls(call, expected):
    assert web_search_succeeded([call]) is expected


@pytest.mark.parametrize("summary", [
    "I appreciate the task, but I’m unable to complete this research directly since I don’t have the ability to perform live Google searches.",
    "Je suis prêt à vous aider avec la rédaction du rapport de synthèse sur l'indexation Google.",
])
async def test_research_promise_or_capability_refusal_never_completes(phoenix, monkeypatch, summary):
    fake_engine(monkeypatch, summary)
    state = await runner.execute_run(request(), phoenix=phoenix)
    assert state.status == RunStatus.FAILED
    assert state.error.startswith("research_unverified:")
    assert not any(kind == "complete" for kind, _ in phoenix.calls)
    assert not state.tool_calls


@pytest.mark.parametrize("call", [
    search_call({"results": [], "error": "network down"}),
    search_call(approved=False),
])
async def test_research_failure_or_denial_cannot_be_hidden_by_artifact(phoenix, monkeypatch, call):
    fake_engine(monkeypatch, "Done", [call], artifacts=["placeholder.md"])
    state = await runner.execute_run(request(), phoenix=phoenix)
    assert state.status == RunStatus.FAILED
    assert not any(kind == "complete" for kind, _ in phoenix.calls)


async def test_search_success_with_failed_source_review_cannot_complete(phoenix, monkeypatch):
    fake_engine(monkeypatch, "I'll research it.", [search_call({"results": [{"url": "https://mokaid.com"}]})],
                research_verification={"status": "needs_changes", "findings": ["No source cited"]})
    state = await runner.execute_run(request(), phoenix=phoenix)
    assert state.status == RunStatus.FAILED


@pytest.mark.parametrize("results, summary", [
    ([{"url": "https://mokaid.com", "snippet": "Public homepage"}], "The public homepage is visible: https://mokaid.com. Google index coverage is unverified."),
    ([], "The public search returned no results. This does not establish whether Google has indexed the site."),
])
async def test_sourced_result_or_honest_no_results_completes(phoenix, monkeypatch, results, summary):
    fake_engine(monkeypatch, summary, [search_call({"results": results})], research_verification={"status": "passed"})
    state = await runner.execute_run(request(), phoenix=phoenix)
    assert state.status == RunStatus.COMPLETED
    assert state.output["summary"] == summary


async def test_real_policy_refusal_is_preserved(phoenix, monkeypatch):
    fake_engine(monkeypatch, "I cannot help with this harmful request under the content policy.")
    force = AsyncMock(side_effect=AssertionError("must not bypass policy"))
    monkeypatch.setattr(runner, "_force_producer_tool", force)
    state = await runner.execute_run(request(), phoenix=phoenix)
    assert state.status == RunStatus.FAILED
    assert state.error.startswith("content_policy:")
    force.assert_not_called()


async def test_requested_report_must_be_saved(phoenix, monkeypatch):
    fake_engine(monkeypatch, "Source: https://mokaid.com", [search_call({"results": [{"url": "https://mokaid.com"}]})])
    monkeypatch.setattr(runner, "_force_producer_tool", AsyncMock(return_value=[]))
    state = await runner.execute_run(request("Research and report Google indexation of mokaid.com"), phoenix=phoenix)
    assert state.status == RunStatus.FAILED
    assert not any(kind == "complete" for kind, _ in phoenix.calls)


async def test_report_fallback_receives_search_evidence_and_saves_report(phoenix, monkeypatch):
    req = request("Research and report Google indexation of mokaid.com")
    fake_engine(monkeypatch, "Source: https://mokaid.com", [search_call({"results": [{"url": "https://mokaid.com", "snippet": "Homepage found"}]})])

    async def draft(params, _ctx):
        assert "https://mokaid.com" in params["context"]
        assert "Homepage found" in params["context"]
        return {"title": "Research report", "content": "Homepage found: https://mokaid.com. Google index coverage is unverified."}

    monkeypatch.setitem(registry._REGISTRY, "draft_document", draft)
    state = await runner.execute_run(req, phoenix=phoenix)
    assert state.status == RunStatus.COMPLETED
    assert state.output["artifacts"]
    assert any(kind == "output" for kind, _ in phoenix.calls)


@pytest.mark.parametrize("kwargs", [
    {"agent": {"tool_preferences": {"disabled": ["draft_*"]}}},
    {"autonomy": {"rules": [{"tool_pattern": "draft_document", "behavior": "deny"}]}},
])
async def test_report_fallback_never_bypasses_restrictions(monkeypatch, kwargs):
    req = request(**kwargs)
    tool = AsyncMock(side_effect=AssertionError("disabled tool must not run"))
    monkeypatch.setattr("app.tools.registry.get_tool", lambda _name: tool)
    state = RunState(run_id=req.run_id)
    result = await runner._force_producer_tool(req, RunContext(run_id=req.run_id, workspace_id="w", task_id="t"), state, "draft_document")
    assert result == []
    tool.assert_not_called()


async def test_offline_research_without_a_lookup_does_not_complete(phoenix):
    state = await runner.execute_run(request(), phoenix=phoenix)
    assert state.status == RunStatus.FAILED
    assert state.error.startswith("research_unverified:")


async def test_offline_planner_cannot_bypass_disabled_web_search(phoenix, monkeypatch):
    monkeypatch.setattr(runner, "plan_steps", AsyncMock(return_value=[
        {"tool": "web_search", "input": {"query": "site:mokaid.com"}},
    ]))
    search = AsyncMock(side_effect=AssertionError("disabled search must never run"))
    monkeypatch.setitem(registry._REGISTRY, "web_search", search)
    state = await runner.execute_run(request(agent={"tool_preferences": {"disabled": ["web_*"]}}), phoenix=phoenix)
    assert state.status == RunStatus.FAILED
    assert state.tool_calls[0].approved is False
    search.assert_not_called()
