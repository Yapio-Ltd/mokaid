"""Tests for file tool URL resolution and producer forcing."""

from app.agents import runner
from app.schemas import AttachedFile, RunRequest, RunState, RunStatus
from app.tools.files import (
    _is_svg,
    _prepare_image_bytes,
    _svg_recolor,
    _target_color_hex,
    resolve_file_url,
    transform_image,
)
from app.tools.registry import RunContext

_MINI_SVG = b"""<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64" viewBox="0 0 64 64">
  <rect x="8" y="8" width="48" height="48" fill="#ff0000"/>
</svg>
"""


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


async def test_transform_image_asks_for_file_when_modification_has_no_image():
    ctx = RunContext(run_id="r2", workspace_id="ws-1", task_id="t1")
    result = await transform_image({"instruction": "Ajouter une moustache"}, ctx)
    assert "No image is attached" in result.get("error", "")
    assert result.get("needs_user_input") is True


async def test_transform_image_creation_without_file_is_offline_gated():
    # Creation-style ask without a source file goes to text-to-image, which
    # needs the OpenAI key — offline test env returns the key error instead
    # of asking the user for a file.
    ctx = RunContext(run_id="r3", workspace_id="ws-1", task_id="t1")
    result = await transform_image({"instruction": "Crée un logo minimaliste"}, ctx)
    assert result.get("note") == "offline fallback"
    assert not result.get("needs_user_input")


def test_is_svg_detects_filename_and_payload():
    assert _is_svg(filename="rubik.svg")
    assert _is_svg(mime="image/svg+xml")
    assert _is_svg(_MINI_SVG)
    assert not _is_svg(b"\x89PNG\r\n\x1a\n", filename="x.png")


def test_target_color_hex_maps_french_green():
    assert _target_color_hex("colorie le logo en vert") == "#22c55e"
    assert _target_color_hex("make it #0f0") == "#00ff00"


def test_svg_recolor_to_green():
    out, err = _svg_recolor(_MINI_SVG, "#22c55e")
    assert err is None
    assert out is not None
    text = out.decode()
    assert "#22c55e" in text.lower() or "22c55e" in text.lower()
    assert "#ff0000" not in text.lower()


def test_prepare_image_bytes_svg_does_not_raise():
    data, img, fmt, err = _prepare_image_bytes(
        _MINI_SVG, filename="rubik.svg", mime="image/svg+xml"
    )
    assert err is None
    assert fmt == "SVG"
    assert img is None
    assert data == _MINI_SVG


def test_prepare_image_bytes_garbage_gives_stable_error():
    data, img, fmt, err = _prepare_image_bytes(b"not-an-image-at-all", filename="x.bin")
    assert data is None
    assert img is None
    assert err is not None
    assert "BytesIO" not in err


async def test_transform_image_recolors_svg_without_openai(phoenix, monkeypatch):
    async def fake_download(url: str) -> bytes:
        return _MINI_SVG

    monkeypatch.setattr("app.tools.files._download", fake_download)
    ctx = RunContext(run_id="r-svg", workspace_id="ws-1", task_id="t1", phoenix=phoenix)
    result = await transform_image(
        {
            "instruction": "colorie le logo en vert",
            "file_url": "https://cdn.example/rubik.svg",
            "original_filename": "rubik.svg",
            "mime_type": "image/svg+xml",
        },
        ctx,
    )
    assert "error" not in result or result.get("method") == "svg_recolor"
    assert result.get("method") == "svg_recolor"
    assert result.get("filename", "").endswith(".svg")
    assert "Cannot identify image" not in (result.get("error") or "")
    assert any(c[0] == "output" for c in phoenix.calls)


async def test_transform_image_bad_bytes_no_bytesio_leak(phoenix, monkeypatch):
    async def fake_download(url: str) -> bytes:
        return b"%%%%not-image%%%%"

    monkeypatch.setattr("app.tools.files._download", fake_download)
    monkeypatch.setattr(
        "app.config.get_settings",
        lambda: type("S", (), {"openai_api_key": "sk-test"})(),
    )
    ctx = RunContext(run_id="r-bad", workspace_id="ws-1", task_id="t1", phoenix=phoenix)
    result = await transform_image(
        {
            "instruction": "make it green",
            "file_url": "https://cdn.example/x.bin",
            "original_filename": "x.bin",
        },
        ctx,
    )
    assert "error" in result
    assert "BytesIO" not in result["error"]
    assert "Cannot identify image file" not in result["error"]


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
