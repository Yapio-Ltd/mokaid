"""Regression coverage for desktop attachments, adaptive QA and honest delivery."""

import io
import json
import zipfile
from unittest.mock import AsyncMock

import pytest

from app.agents import deep_runner, runner
from app.agents.mission_kind import detect_mission_kind
from app.agents.planner import deterministic_plan
from app.agents.quality import DeliveryReview, execution_profile, review_evidence, unresolved_errors
from app.memory import extractors
from app.schemas import AttachedFile, RunRequest, RunState, RunStatus, ToolCall
from app.tools import files as file_tools
from app.tools.registry import RunContext
from app.tools.webapp import _fallback_files, _validate_codebase, _zip_bytes, generate_webapp


def request(brief: str = "Analyse les fichiers", **kwargs) -> RunRequest:
    return RunRequest(run_id="delivery-test", workspace_id="ws", task_id="task", task_description=brief, **kwargs)


def archive(entries: dict[str, bytes]) -> bytes:
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w", zipfile.ZIP_DEFLATED) as output:
        for name, data in entries.items():
            output.writestr(name, data)
    return buffer.getvalue()


def test_archive_reads_code_and_preserves_binary_inventory():
    result = extractors.extract_bytes(archive({
        "src/main.py": b"print('project')",
        "model.bin": bytes(range(256)),
        "../escape.txt": b"must not read",
        "node_modules/large.js": b"ignored dependency",
    }), "project.zip")
    assert result.format == "zip"
    assert "print('project')" in result.text
    assert "Binary file preserved" in result.text
    assert "must not read" not in result.text
    assert "ignored dependency" not in result.text
    assert result.metadata["truncated"] is True
    assert result.metadata["omitted_entries"] == ["../escape.txt", "node_modules/large.js"]


def test_archive_limits_uncompressed_size(monkeypatch):
    monkeypatch.setattr(extractors, "_MAX_MEMBER_BYTES", 20)
    result = extractors.extract_bytes(archive({"small.txt": b"read me", "big.txt": b"z" * 100}), "a.zip")
    assert "read me" in result.text
    assert "z" * 21 not in result.text
    assert "big.txt" in result.metadata["omitted_entries"]


def test_utf16_csv_extracts_readable_text():
    result = extractors.extract_bytes("Nom;Montant\nÉté;42".encode("utf-16"), "report.csv")
    assert "Été;42" in result.text
    assert "\x00" not in result.text


async def test_analyze_document_uses_text_provider_with_original_attachment_name(monkeypatch):
    doc = io.BytesIO()
    import docx

    document = docx.Document()
    document.add_paragraph("Le montant est de 42 euros.")
    document.save(doc)
    monkeypatch.setattr(file_tools.llm, "is_configured", lambda: True)
    monkeypatch.setattr(file_tools, "_download", AsyncMock(return_value=doc.getvalue()))
    chat = AsyncMock(return_value="Le montant est de 42 euros.")
    vision = AsyncMock(side_effect=AssertionError("Word is not a vision input"))
    monkeypatch.setattr(file_tools.llm, "chat", chat)
    monkeypatch.setattr(file_tools.llm, "vision", vision)
    result = await file_tools.analyze_file({
        "file_url": "https://files.example/object", "question": "Quel montant ?",
        "_attached_files": [{"name": "contrat.docx", "download_url": "https://files.example/object"}],
    }, RunContext(run_id="r", workspace_id="ws", task_id="t"))
    assert result["format"] == "docx"
    assert "42 euros" in chat.call_args.kwargs["user"]
    assert result["source_filename"] == "contrat.docx"
    vision.assert_not_called()


async def test_opaque_file_is_preserved_without_sending_binary_to_vision(monkeypatch):
    monkeypatch.setattr(file_tools.llm, "is_configured", lambda: True)
    monkeypatch.setattr(file_tools, "_download", AsyncMock(return_value=bytes(range(256))))
    vision = AsyncMock(side_effect=AssertionError("opaque file is not an image"))
    monkeypatch.setattr(file_tools.llm, "vision", vision)
    result = await file_tools.extract_document_text(
        {"file_url": "https://files.example/object", "original_filename": "drawing.cad"},
        RunContext(run_id="r", workspace_id="ws", task_id="t"),
    )
    assert result["needs_user_input"] is True
    assert result["source_filename"] == "drawing.cad"
    assert "preserved" in result["error"]
    vision.assert_not_called()


def test_mixed_attachments_are_all_routed_and_analysis_never_edits_image():
    req = request(attached_files=[
        AttachedFile(name="notes.pdf", download_url="https://example/pdf"),
        AttachedFile(name="photo.png", mime_type="image/png", download_url="https://example/png"),
        AttachedFile(name="demo.mp4", mime_type="video/mp4", download_url="https://example/mp4"),
    ])
    assert [s["tool"] for s in deterministic_plan(req)] == ["extract_document_text", "analyze_file", "transcribe_audio"]
    assert detect_mission_kind(request("Analyse cette image")) == "analysis"


async def test_unreadable_attachment_pauses_even_when_other_files_produced_output(phoenix, monkeypatch):
    status_update = AsyncMock(wraps=phoenix.update_run_status)
    monkeypatch.setattr(phoenix, "update_run_status", status_update)
    async def fake_deep(req, ctx, state, *_args, **_kwargs):
        state.tool_calls.append(ToolCall(tool="extract_document_text", input={}, output={
            "error": "Unreadable", "needs_user_input": True,
            "input_reason": "unsupported_file_format", "source_filename": "drawing.cad",
        }))
        return {"summary": "One file processed.", "artifacts": ["partial.md"]}

    monkeypatch.setattr(runner.deep_runner, "is_available", lambda: True)
    monkeypatch.setattr(runner.deep_runner, "execute", fake_deep)
    state = await runner.execute_run(request(), phoenix=phoenix)
    assert state.status == RunStatus.WAITING_FOR_USER_INPUT
    assert not any(kind == "complete" for kind, _ in phoenix.calls)
    assert any("drawing.cad" in data.get("body", "") for kind, data in phoenix.calls if kind == "comment")
    assert any("drawing.cad" in call.kwargs.get("extra", {}).get("question", "") for call in status_update.call_args_list)


def test_execution_effort_preserves_simple_speed_and_complex_review():
    assert execution_profile(request("Traduis bonjour en anglais")).mode == "direct"
    assert execution_profile(request("Audit de sécurité de ce projet")).review is True
    assert execution_profile(request("Create a Next.js application")).mode == "deep"


def test_review_packet_omits_binary_and_signed_urls():
    evidence = review_evidence({}, [ToolCall(tool="generate_webapp", input={"token": "secret"}, output={
        "filename": "project.zip", "base64": "secret bytes", "download_url": "https://secret", "verification": {"build": "not_run"},
    })], "Done")
    payload = json.dumps(evidence)
    assert "secret" not in payload
    assert "not_run" in payload


async def test_complex_quality_review_has_one_bounded_repair(phoenix, monkeypatch):
    review = AsyncMock(side_effect=[
        DeliveryReview(status="needs_changes", findings=["Disclose build not run"]),
        DeliveryReview(status="passed", checks=["Completion claims match evidence"]),
    ])
    monkeypatch.setattr(deep_runner, "review_delivery", review)
    req = request("Audit de sécurité du projet")
    engine = deep_runner._Engine(req, RunContext(run_id="r", workspace_id="ws", task_id="t"), RunState(run_id="r", status=RunStatus.RUNNING), phoenix, None, [], AsyncMock())

    class Graph:
        def __init__(self):
            self.inputs = []

        async def astream(self, value, **_kwargs):
            self.inputs.append(value)
            yield {"messages": [], "files": {"/deliverables/report.md": {"content": ["Build not run."]}}}

    graph = Graph()
    state, verification = await engine._review_and_repair(graph, {"messages": []}, {}, checkpointed=False)
    assert review.await_count == 2
    assert len(graph.inputs) == 1
    assert "Disclose build not run" in graph.inputs[0]["messages"][-1]["content"]
    assert verification["status"] == "passed"
    assert verification["review_passes"] == 2
    assert state["files"]


async def test_direct_mission_skips_extra_reviewer(phoenix, monkeypatch):
    reviewer = AsyncMock(side_effect=AssertionError("no extra latency for a short translation"))
    monkeypatch.setattr(deep_runner, "review_delivery", reviewer)
    req = request("Traduis bonjour")
    engine = deep_runner._Engine(req, RunContext(run_id="r", workspace_id="ws", task_id="t"), RunState(run_id="r", status=RunStatus.RUNNING), phoenix, None, [], AsyncMock())
    _, result = await engine._review_and_repair(None, {}, {}, checkpointed=False)
    assert result["review_passes"] == 0
    reviewer.assert_not_called()


def test_successful_retry_resolves_only_its_own_file_failure():
    calls = [
        ToolCall(tool="analyze_file", input={"file_url": "first"}, output={"error": "retry"}),
        ToolCall(tool="analyze_file", input={"file_url": "second"}, output={"error": "unreadable"}),
        ToolCall(tool="extract_document_text", input={"file_url": "first"}, output={"text": "readable now"}),
    ]
    assert [c.input["file_url"] for c in unresolved_errors(calls)] == ["second"]


async def test_unresolved_delivery_review_never_notifies_completion(phoenix, monkeypatch):
    async def fake_deep(*_args, **_kwargs):
        return {
            "artifacts": ["partial-report.md"], "summary": "Done",
            "verification": {"status": "needs_changes", "findings": ["Missing requested comparison"]},
        }

    monkeypatch.setattr(runner.deep_runner, "is_available", lambda: True)
    monkeypatch.setattr(runner.deep_runner, "execute", fake_deep)
    state = await runner.execute_run(request("Audit de sécurité"), phoenix=phoenix)
    assert state.status == RunStatus.FAILED
    assert "Missing requested comparison" in state.error
    assert state.output["artifacts"] == ["partial-report.md"]
    assert not any(kind == "complete" for kind, _ in phoenix.calls)


def test_source_verification_detects_missing_import_and_invalid_manifest():
    files = _fallback_files("Test", "application", None)
    files["app/page.tsx"] += '\nimport Missing from "@/components/Missing";'
    files["package.json"] = "invalid JSON"
    result = _validate_codebase(files)
    assert result["status"] == "failed"
    assert "Invalid package.json" in result["issues"]
    assert any("Missing" in issue for issue in result["issues"])
    assert result["build"] == "not_run"
    with pytest.raises(ValueError, match="Unsafe project path"):
        _zip_bytes({"../outside.txt": "bad"}, "project")


async def test_preview_does_not_count_as_saved_source_project(phoenix, monkeypatch):
    import app.tools.webapp as webapp

    monkeypatch.setattr(webapp, "generate_website", AsyncMock(return_value={"filename": "preview.html"}))
    monkeypatch.setattr(webapp, "_llm_files", AsyncMock(return_value=None))
    original = phoenix.save_task_output

    async def save(*args, **kwargs):
        return None if args[2].endswith(".zip") else await original(*args, **kwargs)

    monkeypatch.setattr(phoenix, "save_task_output", save)
    result = await generate_webapp({"brief": "Build an app"}, RunContext(run_id="r", workspace_id="ws", task_id="t", phoenix=phoenix))
    assert "source ZIP" in result["error"]
    assert "filename" not in result
