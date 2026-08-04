"""Site delivery choice gate (HTML vs Next codebase)."""

from app.agents.mission_kind import detect_mission_kind
from app.schemas import RunRequest
from app.tools.site_delivery import (
    choice_payload,
    delivery_from_request,
    explicit_delivery,
    needs_delivery_choice,
    recommend_delivery,
)


def _req(**kwargs) -> RunRequest:
    base = dict(
        run_id="r1",
        workspace_id="ws",
        task_id="t1",
        agent_id="a1",
        task_title="",
        task_description="",
        input={},
    )
    base.update(kwargs)
    return RunRequest(**base)


def test_ecommerce_mission_kind_is_webapp():
    req = _req(task_description="Créer un site ecommerce entier pour L'Atelier des Tables")
    assert detect_mission_kind(req) == "webapp"


def test_landing_vitrine_html_is_website():
    req = _req(task_description="Landing vitrine html pour mon spa")
    assert detect_mission_kind(req) == "website"
    assert explicit_delivery(req.task_description) == "html"


def test_delivery_input_overrides_kind():
    req = _req(
        task_description="site ecommerce",
        input={"delivery": "html"},
    )
    assert detect_mission_kind(req) == "website"
    assert delivery_from_request(req) == "html"


def test_ambiguous_site_needs_choice():
    req = _req(task_description="Fais-moi un site pour ma boutique de tables")
    assert needs_delivery_choice(req) is True
    assert recommend_delivery(req.task_description) == "webapp"


def test_explicit_next_skips_choice():
    req = _req(task_description="Site Next.js React TypeScript pour mon CRM")
    assert needs_delivery_choice(req) is False
    assert delivery_from_request(req) == "webapp"


def test_choice_payload_shape():
    payload = choice_payload("site ecommerce boutique", lang="fr")
    assert payload["kind"] == "site_delivery_choice"
    assert payload["recommended"] == "webapp"
    ids = {o["id"] for o in payload["options"]}
    assert ids == {"html", "webapp"}


async def test_ensure_site_delivery_applies_edited_payload(phoenix):
    """Resume with decision=edited + delivery=webapp forces webapp routing."""
    from app.agents.runner import seed_decision, _ensure_site_delivery_choice
    from app.schemas import ResumeRequest, RunState, RunStatus

    req = _req(task_description="Fais un site pour ma boutique")
    assert needs_delivery_choice(req) is True

    seed_decision(
        ResumeRequest(run_id=req.run_id, decision="edited", payload={"delivery": "webapp"})
    )
    state = RunState(run_id=req.run_id, status=RunStatus.RUNNING)
    ok = await _ensure_site_delivery_choice(req, state, phoenix)
    assert ok is True
    assert req.input.get("delivery") == "webapp"
    assert detect_mission_kind(req) == "webapp"
