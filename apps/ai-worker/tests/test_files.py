"""Tests for file tool URL resolution and producer forcing."""

from app.agents import runner
from app.schemas import AttachedFile, RunRequest, RunState, RunStatus
from app.tools.files import resolve_file_url, transform_image
from app.tools.registry import RunContext


def test_resolve_file_url_uses_explicit_param():
    url, name = resolve_file_url(
        {
            "file_url": "https://cdn.example/a.png",
            "original_filename": "a.png",
            "_attached_files": [
                {
                    "name": "other.png",
                    "mime_type": "image/png",
                    "download_url": "https://cdn.example/other.png",
                    "source": "input",
                }
            ],
        },
        mime_prefixes=("image/",),
        name_exts=(".png",),
    )
    assert url == "https://cdn.example/a.png"
    assert name == "a.png"


def test_resolve_file_url_falls_back_to_attached_image():
    url, name = resolve_file_url(
        {
            "_attached_files": [
                {
                    "name": "notes.pdf",
                    "mime_type": "application/pdf",
                    "download_url": "https://cdn.example/notes.pdf",
                    "source": "input",
                },
                {
                    "name": "avatar_to_circle.png",
                    "mime_type": "image/png",
                    "download_url": "https://cdn.example/avatar.png",
                    "source": "input",
                },
            ],
        },
        mime_prefixes=("image/",),
        name_exts=(".png", ".jpg", ".jpeg", ".webp"),
    )
    assert url == "https://cdn.example/avatar.png"
    assert name == "avatar_to_circle.png"


def test_resolve_file_url_prefers_input_over_agent_output():
    url, name = resolve_file_url(
        {
            "_attached_files": [
                {
                    "name": "original.png",
                    "mime_type": "image/png",
                    "download_url": "https://cdn.example/original.png",
                    "source": "input",
                },
                {
                    "name": "edited.png",
                    "mime_type": "image/png",
                    "download_url": "https://cdn.example/edited.png",
                    "source": "agent_output",
                },
            ],
        },
        mime_prefixes=("image/",),
        name_exts=(".png",),
    )
    assert url == "https://cdn.example/original.png"
    assert name == "original.png"


def test_resolve_file_url_empty_without_attachments():
    url, name = resolve_file_url({"instruction": "add a mustache"})
    assert url is None
    assert name is None


async def test_transform_image_falls_back_to_attached_files():
    ctx = RunContext(run_id="r1", workspace_id="ws-1", task_id="t1")
    result = await transform_image(
        {
            "instruction": "Ajouter une moustache",
            "_attached_files": [
                {
                    "name": "avatar_to_circle.png",
                    "mime_type": "image/png",
                    "download_url": "https://cdn.example/avatar.png",
                    "source": "input",
                }
            ],
        },
        ctx,
    )
    # Fallback found the URL; offline fixture then blocks the OpenAI call.
    assert "No image URL provided" not in (result.get("error") or "")
    assert result.get("note") == "offline fallback"


async def test_transform_image_errors_without_url_or_attachment():
    ctx = RunContext(run_id="r2", workspace_id="ws-1", task_id="t1")
    result = await transform_image({"instruction": "Ajouter une moustache"}, ctx)
    assert result.get("error") == (
        "No image URL provided. Ensure an image file is attached to the task."
    )


async def test_force_producer_injects_file_url_for_transform_image(phoenix, monkeypatch):
    captured: dict = {}

    async def fake_tool(params, ctx):
        captured.update(params)
        return {"filename": "avatar_to_circle-modified.png", "description": "ok"}

    monkeypatch.setattr(
        "app.tools.registry.get_tool",
        lambda name: fake_tool if name == "transform_image" else None,
    )

    req = RunRequest(
        run_id="run-force-img",
        workspace_id="ws-1",
        agent_id="agent-1",
        task_id="task-1",
        task_title="Ajouter une moustache",
        task_description="Ajouter une moustache à l'avatar",
        input={"instruction": "Ajouter une moustache à l'avatar"},
        attached_files=[
            AttachedFile(
                id="drive-1",
                name="avatar_to_circle.png",
                mime_type="image/png",
                download_url="https://cdn.example/avatar.png",
                source="input",
            )
        ],
    )
    ctx = RunContext(
        run_id=req.run_id,
        workspace_id=req.workspace_id,
        task_id=req.task_id,
        phoenix=phoenix,
    )
    state = RunState(run_id=req.run_id, status=RunStatus.RUNNING)

    artifacts = await runner._force_producer_tool(req, ctx, state, "transform_image")

    assert artifacts == ["avatar_to_circle-modified.png"]
    assert captured["file_url"] == "https://cdn.example/avatar.png"
    assert captured["original_filename"] == "avatar_to_circle.png"
    assert "moustache" in captured["instruction"].lower()
    assert captured["_attached_files"][0]["download_url"] == "https://cdn.example/avatar.png"
