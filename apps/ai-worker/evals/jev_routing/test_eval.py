"""Offline checks for measurement code; never call either provider."""

import hashlib
import json
from argparse import Namespace
from collections import Counter
from pathlib import Path
from types import SimpleNamespace

import pytest
import run_eval
from run_eval import (
    CAPTURE,
    CapturedTracker,
    captured_baseline,
    dispatcher,
    jev_request,
    llm,
    load_archetypes,
    normalize_haiku,
    parse_jev,
    payload_with_archetypes,
    score,
)

PAYLOAD = {"agents": [{"id": "dev", "skills": []}], "instruction": "Build a website"}


def test_catalog_enrichment_preserves_the_frozen_case_and_explicit_catalogs():
    catalog = [{"key": "devops", "skills": ["infrastructure"]}]
    payload = {"instruction": "Diagnose Kubernetes", "agents": []}
    enriched = payload_with_archetypes(payload, catalog)
    assert enriched["agent_archetypes"] == catalog
    enriched["agent_archetypes"][0]["skills"].append("mutated")
    assert "agent_archetypes" not in payload
    assert catalog[0]["skills"] == ["infrastructure"]
    # An explicit empty catalog is a deliberate contract/error test, not an omission.
    assert payload_with_archetypes({"agent_archetypes": []}, catalog)["agent_archetypes"] == []
    supplied = {"agent_archetypes": [{"key": "security"}]}
    assert payload_with_archetypes(supplied, catalog) == supplied


def test_catalog_fixture_matches_the_api_fields_and_covers_specialists():
    path = Path(__file__).parent / "agent_archetypes.json"
    catalog, digest = load_archetypes(path)
    assert digest == hashlib.sha256(path.read_bytes()).hexdigest()
    assert {"blank", "devops", "legal", "security", "developer"} <= {a["key"] for a in catalog}
    fields = {"key", "name", "role_title", "department", "domain", "skills", "description"}
    assert all(set(archetype) == fields for archetype in catalog)


@pytest.mark.parametrize("catalog", [{}, [], [None], [{"key": " "}], [{"key": "devops"}] * 2])
def test_invalid_catalog_is_rejected_before_provider_calls(tmp_path, catalog):
    path = tmp_path / "catalog.json"
    path.write_text(json.dumps(catalog))
    with pytest.raises(ValueError):
        load_archetypes(path)


@pytest.mark.asyncio
async def test_run_records_catalog_fingerprint_and_enriches_only_provider_payload(monkeypatch, tmp_path):
    dataset = {"cases": [{"id": "case", "family": "family", "payload": PAYLOAD}]}
    dataset_path = tmp_path / "cases.json"
    dataset_bytes = json.dumps(dataset).encode()
    dataset_path.write_bytes(dataset_bytes)
    catalog_path = tmp_path / "catalog.json"
    catalog_bytes = b'[{"key": "devops"}]\n'
    catalog_path.write_bytes(catalog_bytes)
    seen = []

    def enrich(payload, catalog):
        result = payload_with_archetypes(payload, catalog)
        seen.append(result)
        return result

    monkeypatch.setattr(run_eval, "payload_with_archetypes", enrich)
    monkeypatch.setattr(run_eval, "get_settings", lambda: SimpleNamespace(
        anthropic_api_key="", openai_api_key="", deepseek_api_key="",
        anthropic_fast_model="test-model",
    ))
    monkeypatch.setattr(run_eval.logging, "disable", lambda *_: None)
    monkeypatch.setattr(run_eval.structlog, "configure", lambda **_: None)
    monkeypatch.setattr(llm, "UsageTracker", llm.UsageTracker)
    monkeypatch.chdir(tmp_path)
    output = tmp_path / "output"
    await run_eval.run(Namespace(
        archetypes=Path("catalog.json"), cases=dataset_path, output=output,
        providers=[], limit=1, repeats=False,
    ))
    manifest = json.loads((output / "manifest.json").read_text())
    assert manifest["archetypes_sha256"] == hashlib.sha256(catalog_bytes).hexdigest()
    assert manifest["dataset_sha256"] == hashlib.sha256(dataset_bytes).hexdigest()
    assert manifest["archetype_count"] == 1
    assert seen[0]["agent_archetypes"] == [{"key": "devops"}]
    assert dataset_path.read_bytes() == dataset_bytes


@pytest.mark.parametrize("confidence,normalized,mode", [
    (None, 50, "existing_agent"), ("80", 50, "existing_agent"),
    (44.4, 44, "custom_agent"), (44.5, 45, "existing_agent"),
    (44.6, 45, "existing_agent"), (-9, 0, "custom_agent"),
    (120, 100, "existing_agent"), (True, 50, "existing_agent"),
])
def test_phoenix_confidence_gate(confidence, normalized, mode):
    result = normalize_haiku({"recommendation": {"mode": "existing_agent", "agent_id": "dev", "confidence": confidence}}, PAYLOAD)
    assert result["confidence"] == normalized
    assert result["mode"] == mode


def test_invalid_agent_requires_fallback():
    result = normalize_haiku({"recommendation": {"mode": "existing_agent", "agent_id": "ghost", "confidence": 90}}, PAYLOAD)
    assert result["fallback_required"]
    assert result["agent_id"] is None


def test_custom_clears_id_and_missing_confidence_defaults_to_50():
    result = normalize_haiku({"recommendation": {"mode": "custom_agent", "agent_id": "dev"}}, PAYLOAD)
    assert result["agent_id"] is None
    assert result["confidence"] == 50


def test_no_fit_user_choice_is_harmful_but_blocked_proposal_is_separate():
    expected = {"modes": ["custom_agent"], "agent_ids": None}
    prediction = {"mode": "user_choice", "agent_id": "dev", "fallback_required": False}
    assert score(prediction, expected)["usable_harmful_no_fit_assignment"]
    prediction["fallback_required"] = True
    assert score(prediction, expected)["harmful_no_fit_assignment"]
    assert not score(prediction, expected)["usable_harmful_no_fit_assignment"]


def test_relative_confidence_does_not_override_absolute_fit():
    body = {"code": 0, "data": {"answers": {
        "mode": {"choice": "existing_agent", "confidence": 1},
        "agent": {"choice": "dev", "confidence": 1},
        "full_fit::dev": {"noul": 0.1},
    }}}
    result = parse_jev(body, PAYLOAD)
    assert result["fallback_required"]
    measured = score(result, {"modes": ["existing_agent"], "agent_ids": ["dev"]})
    assert measured["routing_correct"]
    assert not measured["usable_correct"]


def test_empty_roster_does_not_send_single_option_question():
    request = jev_request({"agents": [], "instruction": "Build a website"})
    assert "agent" not in request["questions"]
    result = parse_jev({"code": 0, "data": {"answers": {"mode": {"choice": "custom_agent"}}}}, {"agents": []})
    assert result["agent_id"] is None
    assert not result["fallback_required"]


def test_transport_failure_is_not_successful_decision():
    with pytest.raises(ValueError):
        parse_jev({"code": -1, "data": None}, PAYLOAD)
    assert not score(None, {"modes": ["existing_agent"], "agent_ids": ["dev"]})["usable_correct"]


@pytest.mark.parametrize("bad", [None, "not a recommendation", [], {"mode": []}])
def test_malformed_fallback_does_not_abort_measurement(bad):
    assert not score(bad, {"modes": ["existing_agent"], "agent_ids": ["dev"]})["usable_correct"]
    assert normalize_haiku({"recommendation": bad}, PAYLOAD)["fallback_required"]


def test_dataset_is_frozen_and_balanced():
    import hashlib
    raw = (Path(__file__).parent / "cases.json").read_bytes()
    assert hashlib.sha256(raw).hexdigest() == "3d2c387177bf8f0eb36b523a2d59965a9ca486348e3d036092093467d95afee9"
    cases = json.loads(raw)["cases"]
    assert len(cases) == 72
    assert Counter(c["language"] for c in cases) == {"en": 24, "fr": 24, "he": 24}
    assert len({c["family"] for c in cases}) == 24
    assert all(len(json.dumps(jev_request(c["payload"]), ensure_ascii=False).encode()) <= 32768 for c in cases)


@pytest.mark.asyncio
async def test_usage_survives_timeout_child_context(monkeypatch):
    async def fake_analyze(payload):
        tracker = llm.UsageTracker()
        tracker.add("claude-haiku-4-5", 100, 50)
        return {"recommendation": {"mode": "existing_agent", "agent_id": "dev", "confidence": 95}}
    monkeypatch.setattr(llm, "UsageTracker", CapturedTracker)
    monkeypatch.setattr(dispatcher, "analyze", fake_analyze)
    result = await captured_baseline({"payload": PAYLOAD})
    assert result["status"] == "ok"
    assert result["full_schema_valid"] is False
    assert result["usage"]["total_tokens"] == 150
    assert result["estimated_cost_usd"] == pytest.approx(0.00035)
    CAPTURE.set(None)
