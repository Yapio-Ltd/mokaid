"""Unit tests for direct chat helpers and mission classification."""

import pytest

from app.agents.direct_chat import _decide, _latest_teammate_message, detect_language, reply
from app.agents.mission_kind import (
    PRODUCER_KINDS,
    detect_mission_kind,
    language_for_request,
    producer_tool_succeeded,
    required_tool_for_kind,
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


@pytest.mark.asyncio
async def test_decide_returns_structured_task(monkeypatch):
    async def fake_json(**_kwargs):
        return {
            "kind": "task",
            "instruction": "Créer un site internet pour résumer la semaine",
            "language": "fr",
        }

    monkeypatch.setattr("app.agents.direct_chat.llm.chat_json", fake_json)
    decision = await _decide("prev", "Tu peux me créer un site internet ?")
    assert decision == {
        "kind": "task",
        "instruction": "Créer un site internet pour résumer la semaine",
        "language": "fr",
    }


@pytest.mark.asyncio
async def test_decide_malformed_falls_back_to_chat(monkeypatch):
    async def fake_json(**_kwargs):
        return {"kind": "weird", "instruction": "", "language": "xx"}

    monkeypatch.setattr("app.agents.direct_chat.llm.chat_json", fake_json)
    decision = await _decide("prev", "Tu peux me créer un site internet ?")
    assert decision["kind"] == "chat"
    assert decision["language"] == "fr"
    assert decision["instruction"] == ""


@pytest.mark.asyncio
async def test_reply_persists_final_message_before_done(monkeypatch, phoenix):
    async def fake_decide(*_args, **_kwargs):
        return {"kind": "chat", "instruction": "", "language": "fr"}

    async def fake_stream(**_kwargs):
        return "Voici la réponse complète."

    monkeypatch.setattr("app.agents.direct_chat.llm.is_configured", lambda: True)
    monkeypatch.setattr("app.agents.direct_chat._decide", fake_decide)
    monkeypatch.setattr("app.agents.direct_chat._stream_reply", fake_stream)

    posted = await reply(
        {
            "workspace_id": "ws-1",
            "agent_id": "agent-1",
            "member_id": "member-1",
            "agent": {"display_name": "Pablo", "skills": []},
            "conversation": [{"author": "Tom", "body": "Réponds-moi"}],
        },
        phoenix=phoenix,
    )

    assert posted
    assert phoenix.calls[-2][0] == "chat"
    assert phoenix.calls[-2][1]["body"] == "Voici la réponse complète."
    assert phoenix.calls[-1][0] == "stream"
    assert phoenix.calls[-1][1]["done"] is True
