"""generate_webapp codebase (offline-gated + mocked happy path)."""

import zipfile
from io import BytesIO

from app.tools.registry import RunContext
from app.tools.webapp import _fallback_files, _zip_bytes, generate_webapp


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


async def test_fallback_files_include_next_tree():
    files = _fallback_files("Atelier", "site ecommerce boutique tables", None)
    assert "package.json" in files
    assert "app/page.tsx" in files
    assert "app/catalogue/page.tsx" in files
    assert "CODEBASE.md" in files
    assert "README.md" in files
    z = _zip_bytes(files, "atelier")
    with zipfile.ZipFile(BytesIO(z)) as zf:
        names = zf.namelist()
    assert "atelier/package.json" in names
    assert "atelier/CODEBASE.md" in names


async def test_generate_webapp_with_mocks_saves_zip_and_tree(phoenix, monkeypatch):
    import app.llm as llm_mod
    import app.tools.webapp as webapp_mod

    async def fake_website(params, ctx):
        await ctx.phoenix.save_task_output(
            ctx.workspace_id, ctx.task_id, "atelier.html", "<html></html>", mime_type="text/html"
        )
        return {
            "filename": "atelier.html",
            "drive_item_id": "fake-drive-item",
            "style": "editorial craft",
            "mood": "warm craft",
            "sections": ["hero", "catalogue"],
        }

    async def fake_llm_files(brief, brand, design, ctx):
        return None  # use fallback scaffold

    monkeypatch.setattr(llm_mod, "is_configured", lambda: True)
    monkeypatch.setattr(webapp_mod, "generate_website", fake_website)
    monkeypatch.setattr(webapp_mod, "_llm_files", fake_llm_files)

    ctx = RunContext(
        run_id="r-wa3",
        workspace_id="ws-1",
        task_id="t1",
        phoenix=phoenix,
        task_title="Atelier",
        task_description="ecommerce",
    )
    result = await generate_webapp(
        {"brief": "Site ecommerce tables en bois", "brand_name": "Atelier"},
        ctx,
    )
    assert "error" not in result
    assert result.get("stack")
    assert "package.json" in (result.get("file_tree") or [])
    assert result.get("zip_filename", "").endswith(".zip")
    assert result.get("commands") == ["npm install", "npm run dev", "npm run build"]
    kinds = {a.get("kind") for a in result.get("artifacts") or []}
    assert "codebase_zip" in kinds
    assert "preview_html" in kinds
    # ZIP content was base64-uploaded
    zip_calls = [c for c in phoenix.calls if c[0] == "output" and str(c[1].get("filename", "")).endswith(".zip")]
    assert zip_calls
