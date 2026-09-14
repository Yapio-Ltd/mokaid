"""Unit tests for direct chat helpers and mission classification."""

from typing import Any

import pytest

from app.agents.direct_chat import (
    _decide,
    _latest_teammate_message,
    _web_research_context,
    asks_for_file_deliverable,
    detect_language,
    reply,
)
from app.agents.mission_kind import (
    PRODUCER_KINDS,
    detect_mission_kind,
    language_for_request,
    looks_like_research,
    looks_like_research_followup,
    producer_tool_succeeded,
    required_tool_for_kind,
    resolve_web_research,
)
from app.schemas import RunRequest, ToolCall


def test_detect_language_french():
    assert detect_language("Tu peux me créer un site internet ?") == "fr"


def test_detect_language_english():
    assert detect_language("Can you build a simple landing page?") == "en"


def test_latest_teammate_skips_agent_lines():
    conversation = [
        {"author": "teammate", "body": "hello"},
        {"author": "you", "body": "hi!"},
        {"author": "Tom", "body": "fais un site"},
    ]
    assert _latest_teammate_message(conversation) == "fais un site"


def test_mission_kind_website_from_instruction():
    req = RunRequest(
        run_id="r1",
        workspace_id="w1",
        task_id="t1",
        task_title="summarizing the week's latest information",
        input={"instruction": "Créer un site internet simple pour résumer la semaine"},
    )
    assert detect_mission_kind(req) == "website"
    assert required_tool_for_kind("website") == "generate_website"
    assert "website" in PRODUCER_KINDS


def test_mission_kind_from_metadata():
    req = RunRequest(
        run_id="r1",
        workspace_id="w1",
        task_id="t1",
        input={"mission_kind": "document"},
    )
    assert detect_mission_kind(req) == "document"


def test_language_for_request_prefers_metadata():
    req = RunRequest(
        run_id="r1",
        workspace_id="w1",
        task_id="t1",
        task_title="Build a site",
        input={"language": "fr"},
    )
    assert language_for_request(req) == "fr"


def test_producer_tool_succeeded_website():
    calls = [
        ToolCall(
            tool="search_knowledge",
            input={"query": "x"},
            output={"chunks": []},
        ),
        ToolCall(
            tool="generate_website",
            input={"brief": "x"},
            output={"filename": "landing.html", "drive_item_id": "abc"},
        ),
    ]
    assert producer_tool_succeeded(calls) is True


def test_producer_tool_failed_without_file():
    calls = [
        ToolCall(
            tool="search_knowledge",
            input={"query": "x"},
            output={"chunks": []},
        ),
        ToolCall(
            tool="generate_website",
            input={"brief": "x"},
            output={"error": "Could not save"},
        ),
    ]
    assert producer_tool_succeeded(calls) is False


def test_mission_kind_research_before_logo():
    req = RunRequest(
        run_id="r1",
        workspace_id="w1",
        task_id="t1",
        input={"instruction": "Recherche BNG CPA France Israel — voici le logo"},
    )
    assert detect_mission_kind(req) == "research"
    assert required_tool_for_kind("research") is None
    assert "research" not in PRODUCER_KINDS


def test_mission_kind_research_report_is_document():
    req = RunRequest(
        run_id="r1",
        workspace_id="w1",
        task_id="t1",
        input={"instruction": "Recherche BNG CPA et rédige un rapport markdown"},
    )
    assert detect_mission_kind(req) == "document"


def test_looks_like_research_helpers():
    assert looks_like_research("fouille sur BNG CPA")
    assert looks_like_research("look up Acme")
    assert looks_like_research(
        "Tu peux me dire qui a gagner le match argentine angleterre ?"
    )
    assert looks_like_research("regarde sur internet le score")
    assert not looks_like_research("fais-moi un café")
    assert asks_for_file_deliverable("rédige un rapport sur BNG")
    assert not asks_for_file_deliverable("recherche BNG CPA avec ce logo")


def test_research_followup_and_multi_turn_resolution():
    assert looks_like_research_followup("Oui regarde")
    assert looks_like_research_followup("alors ?")
    assert looks_like_research_followup("yes look")
    assert not looks_like_research_followup("fais un site internet")

    fact = "Tu peux me dire qui a gagner le match argentine angleterre ?"
    # Turn 1: factual ask
    needed, query = resolve_web_research(fact, [{"author": "Tom", "body": fact}])
    assert needed is True
    assert "argentine" in query.lower()

    # Turn 2: confirmation after agent offered online check
    conversation = [
        {"author": "Tom", "body": fact},
        {
            "author": "you",
            "body": (
                "Hmm, je ne suis pas trop sûr — je peux jeter un œil rapide "
                "sur internet pour te trouver la réponse."
            ),
        },
        {"author": "Tom", "body": "Oui regarde"},
    ]
    needed, query = resolve_web_research("Oui regarde", conversation)
    assert needed is True
    assert "argentine" in query.lower()
    assert "gagn" in query.lower()

    # Turn 3: nudge after stalled lookup
    conversation.append(
        {
            "author": "you",
            "body": "Je vais checker ça pour toi, une seconde !",
        }
    )
    conversation.append({"author": "Tom", "body": "alors ?"})
    needed, query = resolve_web_research("alors ?", conversation)
    assert needed is True
    assert "angleterre" in query.lower()


@pytest.mark.asyncio
async def test_decide_research_forced_to_chat(monkeypatch):
    from app.agents.direct_chat import ChatDecision

    async def fake_structured(**_kwargs):
        return ChatDecision(
            kind="task",
            instruction="Recherche BNG CPA",
            language="fr",
            needs_web_search=True,
            search_query="BNG CPA",
        )

    monkeypatch.setattr("app.agents.direct_chat.llm.chat_structured", fake_structured)
    decision = await _decide("prev", "Recherche BNG CPA Israel avec ce logo")
    assert decision["kind"] == "chat"
    assert decision["instruction"] == ""
    assert decision["needs_web_search"] is True


@pytest.mark.asyncio
async def test_decide_report_request_stays_task(monkeypatch):
    from app.agents.direct_chat import ChatDecision

    async def fake_structured(**_kwargs):
        return ChatDecision(
            kind="task",
            instruction="Rédige un rapport sur BNG CPA",
            language="fr",
        )

    monkeypatch.setattr("app.agents.direct_chat.llm.chat_structured", fake_structured)
    decision = await _decide("prev", "Rédige un rapport sur BNG CPA")
    assert decision["kind"] == "task"
    assert "rapport" in decision["instruction"].lower()


@pytest.mark.asyncio
async def test_decide_returns_structured_task(monkeypatch):
    from app.agents.direct_chat import ChatDecision

    async def fake_structured(**_kwargs):
        return ChatDecision(
            kind="task",
            instruction="Créer un site internet pour résumer la semaine",
            language="fr",
        )

    monkeypatch.setattr("app.agents.direct_chat.llm.chat_structured", fake_structured)
    decision = await _decide("prev", "Tu peux me créer un site internet ?")
    assert decision == {
        "kind": "task",
        "instruction": "Créer un site internet pour résumer la semaine",
        "language": "fr",
        "needs_web_search": False,
        "search_query": "",
    }


@pytest.mark.asyncio
async def test_decide_failure_falls_back_to_chat(monkeypatch):
    async def fake_structured(**_kwargs):
        raise ValueError("structured output parse failed")

    monkeypatch.setattr("app.agents.direct_chat.llm.chat_structured", fake_structured)
    decision = await _decide("prev", "Tu peux me créer un site internet ?")
    assert decision["kind"] == "chat"
    assert decision["language"] == "fr"
    assert decision["instruction"] == ""
    assert decision["needs_web_search"] is False


@pytest.mark.asyncio
async def test_reply_persists_final_message_before_done(monkeypatch, phoenix):
    async def fake_decide(*_args, **_kwargs):
        return {
            "kind": "chat",
            "instruction": "",
            "language": "fr",
            "needs_web_search": False,
            "search_query": "",
        }

    async def fake_stream(**_kwargs):
        assert _kwargs["conversation_id"] == "original-conversation"
        return "Voici la réponse complète."

    monkeypatch.setattr("app.agents.direct_chat.llm.is_configured", lambda: True)
    monkeypatch.setattr("app.agents.direct_chat._decide", fake_decide)
    monkeypatch.setattr("app.agents.direct_chat._stream_reply", fake_stream)

    posted = await reply(
        {
            "workspace_id": "ws-1",
            "agent_id": "agent-1",
            "member_id": "member-1",
            "conversation_id": "original-conversation",
            "agent": {"display_name": "Pablo", "skills": []},
            "conversation": [{"author": "Tom", "body": "Réponds-moi"}],
        },
        phoenix=phoenix,
    )

    assert posted
    assert phoenix.calls[-2][0] == "chat"
    assert phoenix.calls[-2][1]["body"] == "Voici la réponse complète."
    assert phoenix.calls[-2][1]["conversation_id"] == "original-conversation"
    assert phoenix.calls[-1][0] == "stream"
    assert phoenix.calls[-1][1]["done"] is True
    assert phoenix.calls[-1][1]["conversation_id"] == "original-conversation"


@pytest.mark.asyncio
async def test_stream_deltas_keep_execution_conversation(monkeypatch, phoenix):
    from app.agents.direct_chat import _stream_reply

    async def fake_llm(**_kwargs):
        yield "A scoped reply."

    monkeypatch.setattr("app.agents.direct_chat.llm.chat_stream", fake_llm)
    assert await _stream_reply(system="system", user="prompt", phoenix=phoenix,
                               workspace_id="ws", agent_id="agent", stream_id="stream",
                               conversation_id="original") == "A scoped reply."
    assert phoenix.calls == [("stream", {"agent_id": "agent", "stream_id": "stream",
                                          "chunk": "A scoped reply.", "done": False,
                                          "conversation_id": "original"})]


@pytest.mark.asyncio
async def test_phoenix_transport_preserves_optional_conversation_id(monkeypatch):
    from app.clients.phoenix import PhoenixClient

    client = PhoenixClient()
    calls = []

    async def capture(path, payload):
        calls.append((path, payload))
        return {"data": {"ok": True}}

    monkeypatch.setattr(client, "_post", capture)
    await client.stream_agent_chat_chunk("ws", "agent", "stream", "delta", conversation_id="original")
    assert await client.post_agent_chat_message("ws", "agent", "final", stream_id="stream", conversation_id="original")
    assert all(payload["conversation_id"] == "original" for _, payload in calls)
    calls.clear()
    await client.stream_agent_chat_chunk("ws", "agent", "stream", "legacy")
    await client.post_agent_chat_message("ws", "agent", "legacy final")
    assert all("conversation_id" not in payload for _, payload in calls)


@pytest.mark.asyncio
async def test_reply_runs_web_search_on_followup(monkeypatch, phoenix):
    """Reproduce Adi screenshots: fact ask → oui regarde → must search same turn."""
    fact = "Tu peux me dire qui a gagner le match argentine angleterre ?"
    searched: dict[str, Any] = {}

    async def fake_decide(*_args, **_kwargs):
        # Simulate a weak LLM gate that misses the follow-up — heuristics recover.
        return {
            "kind": "chat",
            "instruction": "",
            "language": "fr",
            "needs_web_search": False,
            "search_query": "",
        }

    async def fake_web(query: str) -> str:
        searched["query"] = query
        return (
            "Web search results (use ONLY these facts; cite source URLs):\n"
            "1. Argentina beat England\n   https://example.com/match\n   2-1"
        )

    async def fake_stream(*, system: str, user: str, **_kwargs):
        assert "Web search results" in user
        assert "argentine" in searched["query"].lower()
        assert "never promise" in system.lower()
        return "D'après les sources, l'Argentine a gagné."

    monkeypatch.setattr("app.agents.direct_chat.llm.is_configured", lambda: True)
    monkeypatch.setattr("app.agents.direct_chat._decide", fake_decide)
    monkeypatch.setattr("app.agents.direct_chat._web_research_context", fake_web)
    monkeypatch.setattr("app.agents.direct_chat._stream_reply", fake_stream)

    posted = await reply(
        {
            "workspace_id": "ws-1",
            "agent_id": "agent-1",
            "member_id": "member-1",
            "agent": {"display_name": "Adi", "skills": ["Design"]},
            "conversation": [
                {"author": "Tom", "body": fact},
                {
                    "author": "you",
                    "body": (
                        "Hmm, je ne suis pas trop sûr — je peux jeter un œil "
                        "rapide sur internet."
                    ),
                },
                {"author": "Tom", "body": "Oui regarde"},
            ],
        },
        phoenix=phoenix,
    )

    assert posted
    assert "argentine" in searched["query"].lower()


@pytest.mark.asyncio
async def test_web_research_context_propagates_provider_error(monkeypatch):
    async def fake_web_search(params, _ctx):
        return {"results": [], "query": params["query"], "error": "web search unavailable: no ddgs"}

    monkeypatch.setattr("app.tools.web.web_search", fake_web_search)
    text = await _web_research_context("match Argentine Angleterre")
    assert "UNAVAILABLE" in text
    assert "Do NOT invent" in text
    assert "no ddgs" in text
