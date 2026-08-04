"""generate_webapp scaffold (offline-gated)."""

from app.tools.registry import RunContext
from app.tools.webapp import generate_webapp


async def test_generate_webapp_requires_brief(phoenix):
    ctx = RunContext(run_id="r-wa", workspace_id="ws-1", task_id="t1", phoenix=phoenix)
    result = await generate_webapp({}, ctx)
    assert result.get("error")


async def test_generate_webapp_offline_returns_error(phoenix, monkeypatch):
    import app.llm as llm_mod

    monkeypatch.setattr(llm_mod, "is_configured", lambda: False)
    ctx = RunContext(
        run_id="r-wa2",
        workspace_id="ws-1",
        task_id="t1",
        phoenix=phoenix,
        task_title="Acme CRM",
        task_description="Complete Next.js app",
    )
    result = await generate_webapp({"brief": "Full CRM app", "brand_name": "Acme"}, ctx)
    assert "error" in result
