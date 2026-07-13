"""Direct chat replies: the agent's DM thread with a teammate.

The chat is a work surface: the agent answers conversationally, but when the
teammate actually asks for a deliverable ("build me a landing page", "turn
this into a report"), it acknowledges and asks Phoenix to spin up a real task
assigned to it — the run's output later lands back in this thread.

Decision is made via a structured JSON call (never mixed into the streamed
body), then the visible reply is streamed token-by-token as a pure chat
message. This avoids truncated/halved replies caused by parsing a CHAT/TASK
control line out of a token stream.
"""

import re
import uuid
from typing import Any, Literal

import structlog
from pydantic import BaseModel, Field

from app import llm
from app.clients.phoenix import PhoenixClient

log = structlog.get_logger()

_FLUSH_CHARS = 24


class ChatDecision(BaseModel):
    """Structured routing decision for a teammate's DM."""

    kind: Literal["chat", "task"] = Field(
        description=(
            "'chat' for conversation (questions, status checks, small talk, "
            "questions about attached files); 'task' when the teammate wants "
            "a produced deliverable saved as a file."
        )
    )
    instruction: str = Field(
        default="",
        description="Self-contained one-line brief when kind=task, else empty.",
    )
    language: Literal["fr", "en"] = Field(
        description="Language of the teammate's latest message."
    )


_DECIDE_SYSTEM = """You are routing a teammate's DM for an AI employee.

Decide whether the latest teammate message is:
(a) conversation — a question, status check, small talk, clarification,
    or a QUESTION about an attached file (e.g. "who signed this?",
    "summarize this", "what does section 3 say?"); or
(b) an actionable work request — they want a PRODUCED deliverable
    (document, report, website/landing page, analysis, edited image,
    transcription…) that should be saved as a file.

Rules:
- Use "task" ONLY when they clearly want a saved deliverable an AI employee
  can produce. Questions or conversational requests about attached files stay
  "chat" — the agent will answer inline.
- "Create a website / landing page / site internet" is always "task", even if
  details are incomplete — the worker will fill sensible defaults.
- instruction must capture the full ask in ONE line, same language as the
  teammate.
- Never invent facts."""

_REPLY_SYSTEM = """You are {name}, an AI employee chatting one-on-one with a
teammate (like Slack DMs).

Your profile:
- Role: {role}
- Department: {department}
- Skills: {skills}
- Current status: {status}

Your current workload:
{tasks}

{intent_block}

Write your chat reply ONLY: 1-4 sentences, first person, warm and human,
no markdown, NO control prefixes like CHAT or TASK.

CRITICAL — language: reply ENTIRELY in {language_name}. Do not switch
languages mid-message. Do not mix English and French.

Rules:
- Never invent tasks or results. Never repeat your previous message.
- Answer questions about your workload using the list above.
- Do not ask clarifying questions that block starting work when the ask is
  already clear enough to produce a first version.
"""


def _format_tasks(tasks: list[dict[str, Any]]) -> str:
    if not tasks:
        return "- (no active tasks right now)"
    lines = []
    for task in tasks[:5]:
        title = task.get("title") or "Untitled"
        status = task.get("status") or "unknown"
        progress = task.get("progress_percent")
        suffix = f", {progress}% done" if isinstance(progress, (int, float)) else ""
        lines.append(f"- {title} ({status}{suffix})")
    return "\n".join(lines)


def _latest_teammate_message(conversation: list[dict[str, Any]]) -> str:
    for entry in reversed(conversation or []):
        if not isinstance(entry, dict):
            continue
        author = (entry.get("author") or "").lower()
        if author in ("you", "agent"):
            continue
        body = (entry.get("body") or "").strip()
        if body:
            return body
    return ""


def detect_language(text: str) -> str:
    """Returns 'fr' or 'en' from the teammate's wording."""
    if not text:
        return "en"
    if re.search(
        r"\b(je|tu|le|la|les|un|une|pour|avec|dans|que|qui|fais|génère|créer?|"
        r"change|voici|s'il|peux|moi|site|internet|semaine)\b|[éèêàçùœ]",
        text,
        re.IGNORECASE,
    ):
        return "fr"
    return "en"


def _language_name(code: str) -> str:
    return "French" if code == "fr" else "English"


async def _decide(
    thread: str, latest: str, usage: llm.UsageTracker | None = None
) -> dict[str, Any]:
    """Structured chat-vs-task decision, never mixed into the visible reply.
    Provider-enforced Pydantic output (with_structured_output) — no JSON
    parsing out of free text."""
    language = detect_language(latest)
    try:
        decision: ChatDecision = await llm.chat_structured(
            system=_DECIDE_SYSTEM,
            user=(
                f"Latest teammate message:\n{latest}\n\n"
                f"Recent thread (most recent last):\n{thread}"
            ),
            schema=ChatDecision,
            usage=usage,
            max_tokens=250,
            quality="fast",
        )
    except Exception as exc:  # noqa: BLE001
        log.warning("direct_chat_decide_failed", error=str(exc))
        return {"kind": "chat", "instruction": "", "language": language}

    instruction = decision.instruction.strip()
    if decision.kind == "task" and not instruction:
        instruction = latest
    return {"kind": decision.kind, "instruction": instruction, "language": decision.language}


async def _stream_reply(
    *,
    system: str,
    user: str,
    phoenix: PhoenixClient,
    workspace_id: str,
    agent_id: str,
    stream_id: str,
) -> str:
    """Streams a pure chat reply (no control header) and returns the full text."""
    text_parts: list[str] = []
    buffer = ""

    async def flush(chunk: str) -> None:
        if not chunk:
            return
        try:
            await phoenix.stream_agent_chat_chunk(
                workspace_id, agent_id, stream_id, chunk
            )
        except Exception as exc:  # noqa: BLE001
            log.warning("direct_chat_stream_failed", error=str(exc))

    try:
        async for delta in llm.chat_stream(
            system=system,
            user=user,
            max_tokens=800,
            quality="fast",
        ):
            buffer += delta
            if len(buffer) >= _FLUSH_CHARS:
                text_parts.append(buffer)
                await flush(buffer)
                buffer = ""
    except Exception as exc:  # noqa: BLE001
        log.warning("direct_chat_llm_failed", error=str(exc))
        return ""

    if buffer:
        text_parts.append(buffer)
        await flush(buffer)

    return "".join(text_parts).strip()


def _format_attachments(attachments: list[dict[str, Any]]) -> str:
    if not attachments:
        return ""
    names = [a.get("name") or "file" for a in attachments]
    return "Attached files: " + ", ".join(names)


_PREVIEW_CHARS = 12_000
_IMAGE_EXTS = {".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp"}


async def _download_bytes(url: str) -> bytes:
    import httpx

    async with httpx.AsyncClient(timeout=30, follow_redirects=True) as client:
        resp = await client.get(url)
        resp.raise_for_status()
        return resp.content


async def _load_attachment_previews(attachments: list[dict[str, Any]]) -> str:
    """Downloads each attachment and returns a bounded text preview the LLM
    can reason over inline (questions like "who signed this?"). Images go
    through vision; documents through extractors. Failures are soft."""
    if not attachments:
        return ""

    from app.memory import extractors

    parts: list[str] = []
    for att in attachments[:4]:
        if not isinstance(att, dict):
            continue
        name = att.get("name") or "file"
        url = (att.get("download_url") or "").strip()
        mime = (att.get("mime_type") or "").lower()
        ext = ("." + name.rsplit(".", 1)[-1].lower()) if "." in name else ""

        if not url:
            parts.append(f"### {name}\n(no download URL available)")
            continue

        try:
            data = await _download_bytes(url)
        except Exception as exc:  # noqa: BLE001
            log.warning("direct_chat_attachment_download_failed", name=name, error=str(exc))
            parts.append(f"### {name}\n(could not download: {exc})")
            continue

        if mime.startswith("image/") or ext in _IMAGE_EXTS:
            try:
                description = await llm.vision(
                    system=(
                        "Describe this image thoroughly for a colleague who cannot "
                        "see it. Extract any visible text, signatures, names, dates, "
                        "and key visual details. Reply in the language of any text "
                        "you find on the image, otherwise English."
                    ),
                    user_text=f"Analyze the attached image «{name}».",
                    image_url=url,
                    max_tokens=1000,
                )
                parts.append(f"### {name} (image)\n{(description or '(empty)').strip()}")
            except Exception as exc:  # noqa: BLE001
                log.warning("direct_chat_vision_failed", name=name, error=str(exc))
                parts.append(f"### {name}\n(vision analysis failed)")
            continue

        if extractors.is_extractable(name, mime):
            result = extractors.extract_bytes(data, filename=name, mime_type=mime)
            if result and result.text.strip():
                preview = result.text.strip()[:_PREVIEW_CHARS]
                truncated = "…" if len(result.text) > _PREVIEW_CHARS else ""
                parts.append(f"### {name} ({result.format})\n{preview}{truncated}")
            else:
                parts.append(f"### {name}\n(no extractable text)")
            continue

        parts.append(f"### {name}\n(unsupported format for inline reading)")

    if not parts:
        return ""
    return (
        "Attached file contents (use these to answer the teammate's question "
        "directly — do not ask which document they mean):\n\n" + "\n\n".join(parts)
    )


async def reply(payload: dict[str, Any], phoenix: PhoenixClient | None = None) -> bool:
    """Streams the agent's DM reply (and possibly starts a task) via Phoenix."""
    if not llm.is_configured():
        return False

    phoenix = phoenix or PhoenixClient()
    agent = payload.get("agent") or {}
    conversation = payload.get("conversation") or []
    attachments = payload.get("attachments") or []

    thread = "\n".join(
        f"- {entry.get('author', '?')}: {entry.get('body', '')}"
        for entry in conversation[-14:]
        if isinstance(entry, dict)
    )
    latest = _latest_teammate_message(conversation)

    file_context = _format_attachments(attachments)
    # Bound content preview so questions about a PDF/image can be answered
    # inline without spinning up a task.
    file_preview = await _load_attachment_previews(attachments) if attachments else ""
    decide_thread = thread
    if file_context:
        decide_thread = f"{decide_thread}\n{file_context}"
    if file_preview:
        decide_thread = f"{decide_thread}\n\n{file_preview}"

    decision = await _decide(decide_thread, latest)
    start_task = decision["kind"] == "task"
    instruction = decision["instruction"]
    language = decision["language"]

    if start_task:
        intent_block = (
            "The teammate asked you to PRODUCE something. Confirm enthusiastically "
            "what you'll deliver and say you'll share the result in this thread "
            "shortly. Do NOT ask blocking clarifying questions — start with sensible "
            f"defaults if details are missing.\nBrief you will execute: {instruction}"
        )
    else:
        intent_block = (
            "This is a conversational message. Answer it directly using any "
            "attached file contents provided in the user message. Do not start "
            "a task or invent deliverables. Do not ask which document they mean "
            "when an attachment is already provided."
        )

    system = _REPLY_SYSTEM.format(
        name=agent.get("display_name") or "an AI agent",
        role=agent.get("role_title") or "Generalist",
        department=agent.get("department") or "—",
        skills=", ".join(agent.get("skills") or []) or "generalist",
        status=agent.get("status") or "available",
        tasks=_format_tasks(payload.get("current_tasks") or []),
        intent_block=intent_block,
        language_name=_language_name(language),
    )

    workspace_id = payload["workspace_id"]
    agent_id = payload["agent_id"]
    stream_id = uuid.uuid4().hex

    user_prompt = (
        "DM thread (most recent last — 'you' lines are your own previous "
        f"messages; reply to the last teammate message):\n{thread}"
    )
    if file_preview:
        user_prompt = f"{user_prompt}\n\n{file_preview}"

    text = await _stream_reply(
        system=system,
        user=user_prompt,
        phoenix=phoenix,
        workspace_id=workspace_id,
        agent_id=agent_id,
        stream_id=stream_id,
    )
    if not text:
        return False

    posted = await phoenix.post_agent_chat_message(
        workspace_id,
        agent_id,
        text,
        start_task=start_task and bool(instruction),
        instruction=instruction,
        member_id=payload.get("member_id"),
        message_id=payload.get("message_id"),
        attachments=attachments if start_task else None,
        skip_ack=True,
        language=language,
        stream_id=stream_id,
    )
    if posted:
        # Persist and broadcast the canonical message before closing its
        # typewriter stream. A `done` sent first could clear the draft while
        # the final message was still in flight (or during a socket reconnect).
        try:
            await phoenix.stream_agent_chat_chunk(
                workspace_id, agent_id, stream_id, "", done=True
            )
        except Exception as exc:  # noqa: BLE001
            log.warning("direct_chat_stream_finalize_failed", error=str(exc))
        log.info(
            "direct_chat_replied",
            agent_id=agent_id,
            started_task=start_task and bool(instruction),
            language=language,
        )
    return posted
