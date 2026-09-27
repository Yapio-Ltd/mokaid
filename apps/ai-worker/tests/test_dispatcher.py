"""Dispatch must validate every provider path before returning a recommendation."""

from copy import deepcopy
from types import SimpleNamespace
from unittest.mock import AsyncMock

import httpx
import pytest
from pydantic import ValidationError

from app import main
from app.agents import dispatcher


@pytest.fixture
def payload():
    return {
        "instruction": "Investigate the Kubernetes incident and repair the deployment.",
        "agents": [{"id": "writer", "name": "Writer", "skills": []}],
        "agent_archetypes": [{"key": "devops", "name": "DevOps", "skills": []}],
        "mcp_connected": [{"server_key": "github", "name": "GitHub"}],
        "mcp_available": [{"key": "slack", "name": "Slack"}],
    }


@pytest.fixture
def valid_analysis():
    return {
        "task": {"title": "Repair deployment", "description": "Investigate the incident."},
        "recommendation": {
            "mode": "custom_agent",
            "confidence": 85,
            "agent_id": None,
            "reason": "A DevOps specialist is needed for this incident.",
            "custom_agent": {
                "display_name": "DevOps specialist",
                "role_title": "DevOps Engineer",
                "archetype_key": "devops",
                "skills": [{"name": "Kubernetes"}],
            },
        },
    }


def test_original_missing_profile_regression(valid_analysis):
    valid_analysis["recommendation"]["custom_agent"] = None
    with pytest.raises(ValidationError):
        dispatcher.DispatchAnalysis.model_validate(valid_analysis)


@pytest.mark.parametrize(
    "field,value",
    [
        ("display_name", "  "),
        ("role_title", ""),
        ("archetype_key", " "),
        ("skills", []),
        ("skills", [{"name": "  "}]),
    ],
)
def test_profile_requires_usable_fields(valid_analysis, field, value):
    valid_analysis["recommendation"]["custom_agent"][field] = value
    with pytest.raises(ValidationError):
        dispatcher.DispatchAnalysis.model_validate(valid_analysis)


@pytest.mark.parametrize(
    "recommendation",
    [
        {"mode": "existing_agent", "agent_id": None, "confidence": 90},
        {"mode": "existing_agent", "agent_id": "writer", "confidence": 44},
        {"mode": "user_choice", "agent_id": "writer", "custom_agent": None},
    ],
)
def test_incoherent_modes_rejected(valid_analysis, recommendation):
    valid_analysis["recommendation"] = recommendation
    with pytest.raises(ValidationError):
        dispatcher.DispatchAnalysis.model_validate(valid_analysis)


async def test_valid_structured_result_needs_no_repair(monkeypatch, payload, valid_analysis):
    structured = AsyncMock(return_value=dispatcher.DispatchAnalysis.model_validate(valid_analysis))
    repair = AsyncMock()
    monkeypatch.setattr(dispatcher.llm, "chat_structured", structured)
    monkeypatch.setattr(dispatcher.llm, "chat_json", repair)
    result = await dispatcher.analyze(payload)
    assert result["recommendation"]["custom_agent"]["archetype_key"] == "devops"
    structured.assert_awaited_once()
    repair.assert_not_awaited()
    assert "devops" in structured.call_args.kwargs["user"]


@pytest.mark.parametrize("mode", ["existing_agent", "user_choice"])
async def test_existing_and_partial_routes_preserve_the_known_agent(
    monkeypatch, payload, valid_analysis, mode
):
    rec = valid_analysis["recommendation"]
    rec.update(mode=mode, agent_id="writer")
    if mode == "existing_agent":
        rec["custom_agent"] = None
    monkeypatch.setattr(dispatcher.llm, "chat_structured", AsyncMock(return_value=valid_analysis))
    repair = AsyncMock()
    monkeypatch.setattr(dispatcher.llm, "chat_json", repair)
    result = await dispatcher.analyze(payload)
    assert result["recommendation"]["mode"] == mode
    assert result["recommendation"]["agent_id"] == "writer"
    repair.assert_not_awaited()


@pytest.mark.parametrize("field,value", [("reason", " "), ("confidence", None)])
def test_cannot_invent_missing_evidence(valid_analysis, field, value):
    if value is None:
        valid_analysis["recommendation"].pop(field)
    else:
        valid_analysis["recommendation"][field] = value
    with pytest.raises(ValidationError):
        dispatcher.DispatchAnalysis.model_validate(valid_analysis)


async def test_missing_profile_gets_one_validated_repair(monkeypatch, payload, valid_analysis):
    broken = deepcopy(valid_analysis)
    broken["recommendation"]["custom_agent"] = None
    # Do not trust even a model object constructed without validation.
    structured = AsyncMock(return_value=dispatcher.DispatchAnalysis.model_construct(**broken))
    repair = AsyncMock(return_value=valid_analysis)
    monkeypatch.setattr(dispatcher.llm, "chat_structured", structured)
    monkeypatch.setattr(dispatcher.llm, "chat_json", repair)
    result = await dispatcher.analyze(payload)
    assert result["recommendation"]["custom_agent"]["role_title"] == "DevOps Engineer"
    structured.assert_awaited_once()
    repair.assert_awaited_once()
    assert "archetype_key" in repair.call_args.kwargs["system"]


@pytest.mark.parametrize(
    "defect",
    [
        "missing_profile",
        "unknown_agent",
        "unknown_alternative",
        "duplicate_alternative",
        "primary_alternative",
        "unknown_archetype",
        "missing_catalog",
        "unknown_mcp",
        "too_many_mcp",
        "blank_brief",
        "custom_with_existing_id",
        "existing_with_profile",
    ],
)
async def test_invalid_json_fallback_is_blocked(monkeypatch, payload, valid_analysis, defect):
    rec = valid_analysis["recommendation"]
    if defect == "missing_profile":
        rec["custom_agent"] = None
    elif defect == "unknown_archetype":
        rec["custom_agent"]["archetype_key"] = "invented"
    elif defect == "missing_catalog":
        payload.pop("agent_archetypes")
    elif defect == "unknown_mcp":
        valid_analysis["mcp_suggestions"] = [{"server_key": "invented"}]
    elif defect == "too_many_mcp":
        valid_analysis["mcp_suggestions"] = [{"server_key": "github"}] * 4
    elif defect == "blank_brief":
        valid_analysis["task"]["description"] = " "
    elif defect == "custom_with_existing_id":
        rec["agent_id"] = "writer"
    elif defect == "existing_with_profile":
        rec.update(mode="existing_agent", agent_id="writer")
    else:
        rec.update(mode="existing_agent", agent_id="writer", custom_agent=None)
        payload["agents"].append({"id": "other"})
        if defect == "unknown_agent":
            rec["agent_id"] = "foreign-workspace-agent"
        elif defect == "unknown_alternative":
            rec["alternatives"] = [{"agent_id": "foreign-workspace-agent"}]
        elif defect == "duplicate_alternative":
            rec["alternatives"] = [{"agent_id": "other"}] * 2
        else:
            rec["alternatives"] = [{"agent_id": "writer"}]
    monkeypatch.setattr(
        dispatcher.llm, "chat_structured", AsyncMock(side_effect=RuntimeError("provider"))
    )
    repair = AsyncMock(return_value=valid_analysis)
    monkeypatch.setattr(dispatcher.llm, "chat_json", repair)
    with pytest.raises(dispatcher.InvalidDispatchAnalysis):
        await dispatcher.analyze(payload)
    repair.assert_awaited_once()


async def test_invalid_structured_then_failed_repair_still_blocks_dispatch(
    monkeypatch, payload, valid_analysis
):
    valid_analysis["recommendation"]["custom_agent"] = None
    monkeypatch.setattr(dispatcher.llm, "chat_structured", AsyncMock(return_value=valid_analysis))
    monkeypatch.setattr(
        dispatcher.llm, "chat_json", AsyncMock(side_effect=RuntimeError("provider down"))
    )
    with pytest.raises(dispatcher.InvalidDispatchAnalysis):
        await dispatcher.analyze(payload)


async def test_provider_outage_remains_distinct(monkeypatch, payload):
    monkeypatch.setattr(
        dispatcher.llm, "chat_structured", AsyncMock(side_effect=RuntimeError("provider down"))
    )
    monkeypatch.setattr(
        dispatcher.llm, "chat_json", AsyncMock(side_effect=RuntimeError("provider down"))
    )
    with pytest.raises(RuntimeError, match="provider down"):
        await dispatcher.analyze(payload)


async def test_endpoint_marks_invalid_decision_as_422(monkeypatch):
    monkeypatch.setattr(main, "get_settings", lambda: SimpleNamespace(worker_auth_token="test"))
    monkeypatch.setattr(dispatcher, "is_available", lambda: True)
    monkeypatch.setattr(
        dispatcher, "analyze", AsyncMock(side_effect=dispatcher.InvalidDispatchAnalysis())
    )
    async with httpx.AsyncClient(
        transport=httpx.ASGITransport(app=main.app), base_url="http://worker"
    ) as client:
        response = await client.post(
            "/dispatch/analyze", json={}, headers={"authorization": "Bearer test"}
        )
    assert response.status_code == 422
    assert response.json() == {"detail": "invalid_dispatch_analysis"}
