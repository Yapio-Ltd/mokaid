"""Mission kind classification — drives producer guardrails.

A "producer" mission must leave at least one Drive artifact. Clarification-only
closings are not success.
"""

from __future__ import annotations

import re
from typing import Any

from app.schemas import RunRequest

# Tools whose successful output counts as a real deliverable.
PRODUCER_TOOLS = frozenset(
    {
        "generate_website",
        "draft_document",
        "generate_report",
        "transform_image",
        "transcribe_audio",
        "analyze_file",
        "extract_document_text",
    }
)

# Mission kinds that must produce a file (or fail / wait).
PRODUCER_KINDS = frozenset({"website", "document", "image", "analysis"})


def detect_mission_kind(request: RunRequest) -> str:
    """Prefer explicit metadata from Phoenix; fall back to instruction heuristics."""
    meta_kind = (request.input or {}).get("mission_kind")
    if isinstance(meta_kind, str) and meta_kind.strip():
        return meta_kind.strip().lower()

    text = " ".join(
        filter(
            None,
            [
                request.task_title or "",
                request.task_description or "",
                str((request.input or {}).get("instruction") or ""),
            ],
        )
    ).lower()

    if re.search(r"\b(site|website|landing|page web|html|vitrine)\b", text):
        return "website"
    if re.search(r"\b(image|logo|photo|picture|design|visuel|avatar)\b", text):
        return "image"
    if re.search(r"\b(rapport|report|document|résumé|resume|brief|markdown)\b", text):
        return "document"
    if re.search(r"\b(analyse|analyze|transcri)", text):
        return "analysis"
    return "general"


def required_tool_for_kind(kind: str) -> str | None:
    return {
        "website": "generate_website",
        "document": "draft_document",
        "image": "transform_image",
        "analysis": "analyze_file",
    }.get(kind)


def producer_tool_succeeded(tool_calls: list[Any]) -> bool:
    for call in tool_calls:
        tool = getattr(call, "tool", None) or (call.get("tool") if isinstance(call, dict) else None)
        output = getattr(call, "output", None) or (call.get("output") if isinstance(call, dict) else None)
        if tool not in PRODUCER_TOOLS:
            continue
        if isinstance(output, dict) and not output.get("error") and (
            output.get("filename")
            or output.get("content")
            or output.get("report")
            or output.get("transcript")
            or output.get("analysis")
            or output.get("drive_item_id")
        ):
            return True
    return False


def language_for_request(request: RunRequest) -> str:
    explicit = (request.input or {}).get("language")
    if explicit in ("fr", "en"):
        return explicit
    text = f"{request.task_title or ''} {request.task_description or ''} {(request.input or {}).get('instruction') or ''}"
    if re.search(
        r"\b(je|tu|le|la|les|un|une|pour|avec|dans|que|qui|site|créer|peux)\b|[éèêàçù]",
        text,
        re.IGNORECASE,
    ):
        return "fr"
    return "en"
