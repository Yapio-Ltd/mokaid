import json
from unittest.mock import AsyncMock

import pytest
from pydantic import ValidationError

from app.agents import orchestrator_chat as coordinator


@pytest.mark.asyncio
async def test_real_structured_response_preserves_language_and_proposal(monkeypatch):
    monkeypatch.setattr(coordinator.llm, "is_configured", lambda: True)
    call = AsyncMock(
        return_value=coordinator.CoordinatorReply(
            reply="Voici le plan à lancer.",
            language="fr",
            mission_instruction="Livrer une étude sourcée.",
        )
    )
    monkeypatch.setattr(coordinator.llm, "chat_structured", call)
    response = await coordinator.respond({"message": "Fais une étude", "language": "fr"})
    assert response["language"] == "fr"
    assert response["mission_instruction"] == "Livrer une étude sourcée."
    snapshot = json.loads(call.call_args.kwargs["user"])
    assert snapshot["latest_user_message"] == "Fais une étude"
    assert snapshot["language_hint"] == "fr"
    assert "Never claim a proposal has" in call.call_args.kwargs["system"]


@pytest.mark.asyncio
async def test_foreign_task_id_from_model_cannot_become_navigation_target(monkeypatch):
    monkeypatch.setattr(coordinator.llm, "is_configured", lambda: True)
    monkeypatch.setattr(
        coordinator.llm,
        "chat_structured",
        AsyncMock(return_value={"reply": "Status", "task_id": "foreign-task", "language": "en"}),
    )
    result = await coordinator.respond({"message": "Status?", "missions": [{"id": "task-a"}]})
    assert result["task_id"] == ""
    assert result["mission_instruction"] == ""


@pytest.mark.asyncio
async def test_provider_failure_is_not_a_canned_success(monkeypatch):
    monkeypatch.setattr(coordinator.llm, "is_configured", lambda: False)
    with pytest.raises(RuntimeError, match="not configured"):
        await coordinator.respond({"message": "Hello"})
    monkeypatch.setattr(coordinator.llm, "is_configured", lambda: True)
    monkeypatch.setattr(coordinator.llm, "chat_structured", AsyncMock(return_value={"reply": ""}))
    with pytest.raises(ValidationError):
        await coordinator.respond({"message": "Hello"})


@pytest.mark.asyncio
async def test_context_is_bounded_and_known_task_links_survive(monkeypatch):
    monkeypatch.setattr(coordinator.llm, "is_configured", lambda: True)
    call = AsyncMock(return_value={"reply": "Ready for review", "task_id": "task-a"})
    monkeypatch.setattr(coordinator.llm, "chat_structured", call)
    result = await coordinator.respond(
        {
            "message": "Status?",
            "missions": [{"id": "task-a"}],
            "conversation": [{"role": "user", "body": str(i)} for i in range(40)],
        }
    )
    assert result["task_id"] == "task-a"
    assert len(json.loads(call.call_args.kwargs["user"])["conversation"]) == 24
