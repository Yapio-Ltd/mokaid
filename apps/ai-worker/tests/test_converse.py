"""Idle task follow-ups must reach Phoenix's authorized execution path."""

from unittest.mock import AsyncMock

import pytest

from app.agents import converse
from app.clients.phoenix import PhoenixClient


@pytest.fixture
def payload():
    return {
        "workspace_id": "w",
        "task_id": "t",
        "agent_id": "a",
        "task_title": "Google indexing report",
        "task_status": "waiting",
        "trigger": {"id": "c", "body": "Fais la recherche et rédige le rapport"},
        "conversation": [{"author": "agent", "body": "I cannot search online."}],
    }


@pytest.fixture
def phoenix():
    client = AsyncMock(spec=PhoenixClient)
    client.apply_task_followup.return_value = {"outcome": "started", "run_id": "run"}
    return client


async def test_work_instruction_requests_real_execution_without_empty_promise(
    monkeypatch, payload, phoenix
):
    monkeypatch.setattr(converse.llm, "is_configured", lambda: True)
    classifier = AsyncMock(
        return_value=converse.TaskThreadDecision(
            kind="resume", reply="I am ready to help once you launch the mission."
        )
    )
    monkeypatch.setattr(converse.llm, "chat_structured", classifier)

    assert await converse.converse(payload, phoenix)

    phoenix.apply_task_followup.assert_awaited_once_with(
        "w", "t", "c", agent_id="a", kind="resume", reply="", language="fr"
    )
    phoenix.post_task_comment.assert_not_awaited()
    assert "Triggering human message:\nFais la recherche" in classifier.call_args.kwargs["user"]


@pytest.mark.parametrize("message", ["Bonjour", "Où en es-tu ?", "Merci", "Why did it fail?"])
async def test_conversation_only_posts_an_anchored_chat_decision(
    monkeypatch, payload, phoenix, message
):
    payload["trigger"]["body"] = message
    monkeypatch.setattr(converse.llm, "is_configured", lambda: True)
    monkeypatch.setattr(
        converse.llm,
        "chat_structured",
        AsyncMock(
            return_value=converse.TaskThreadDecision(kind="chat", reply="The task is waiting.")
        ),
    )
    assert await converse.converse(payload, phoenix)
    assert phoenix.apply_task_followup.call_args.kwargs["kind"] == "chat"
    phoenix.post_task_comment.assert_not_awaited()


async def test_legacy_unanchored_payload_never_starts_or_posts(payload, phoenix):
    del payload["trigger"]
    assert not await converse.converse(payload, phoenix)
    phoenix.apply_task_followup.assert_not_awaited()
    phoenix.post_task_comment.assert_not_awaited()


async def test_classifier_failure_explains_no_run_started(monkeypatch, payload, phoenix):
    monkeypatch.setattr(converse.llm, "is_configured", lambda: True)
    monkeypatch.setattr(
        converse.llm, "chat_structured", AsyncMock(side_effect=RuntimeError("offline"))
    )
    assert await converse.converse(payload, phoenix)
    callback = phoenix.apply_task_followup.call_args.kwargs
    assert callback["kind"] == "chat"
    assert "Aucune nouvelle exécution" in callback["reply"]


async def test_failed_callback_is_not_acknowledged(monkeypatch, payload, phoenix):
    monkeypatch.setattr(converse.llm, "is_configured", lambda: True)
    monkeypatch.setattr(
        converse.llm,
        "chat_structured",
        AsyncMock(return_value=converse.TaskThreadDecision(kind="resume")),
    )
    phoenix.apply_task_followup.return_value = None
    assert not await converse.converse(payload, phoenix)
    phoenix.post_task_comment.assert_not_awaited()


async def test_http_delivery_waits_for_callback_and_reports_failure(monkeypatch, payload):
    from fastapi import HTTPException

    from app import main

    monkeypatch.setattr(main, "_check_auth", lambda _: None)
    handler = AsyncMock(return_value=False)
    monkeypatch.setattr(converse, "converse", handler)
    with pytest.raises(HTTPException) as error:
        await main.converse(payload)
    assert error.value.status_code == 503
    handler.return_value = True
    assert await main.converse(payload) == {"accepted": True}


async def test_sqs_does_not_delete_failed_followup(monkeypatch, payload):
    from app.queue.consumer import _handle_message

    handler = AsyncMock(return_value=False)
    monkeypatch.setattr(converse, "converse", handler)
    with pytest.raises(RuntimeError, match="not applied"):
        await _handle_message({"type": "converse", **payload})
    handler.return_value = True
    await _handle_message({"type": "converse", **payload})
