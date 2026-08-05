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
from app.agents.mission_kind import looks_like_research, resolve_web_research
from app.clients.phoenix import PhoenixClient

log = structlog.get_logger()

_FLUSH_CHARS = 24

_EXPLICIT_FILE_DELIVERABLE_RE = re.compile(
    r"\b("
    r"rédige|redige|écris|ecris|write|draft|"
    r"crée\s+(?:un|le|une|la)\s+(?:rapport|doc|document|pdf|deck|site)|"
    r"create\s+(?:a\s+)?(?:report|doc|document|pdf|deck|website|landing)|"
    r"génère\s+(?:un\s+)?(?:rapport|pdf|doc|site)|"
    r"generate\s+(?:a\s+)?(?:report|pdf|document|website)|"
    r"modifie\s+(?:le\s+|cet?\s+)?(?:logo|image|avatar)|"
    r"(?:edit|change|transform)\s+(?:the\s+)?(?:logo|image|avatar)"
    r")\b",
    re.IGNORECASE,
)


def asks_for_file_deliverable(text: str) -> bool:
    """True when the teammate explicitly wants a saved file / branding edit."""
    return bool(text and _EXPLICIT_FILE_DELIVERABLE_RE.search(text))


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
    needs_web_search: bool = Field(
        default=False,
        description=(
            "True when answering needs fresh public-web facts in THIS turn: "
            "sports scores, news, 'who won', company/person lookup, explicit "
            "'check online' asks, OR a short follow-up confirming a pending "
            "lookup ('oui regarde', 'yes look', 'alors?'). False for small "
            "talk, status, or answers fully grounded in the thread/files."
        ),
    )
    search_query: str = Field(
        default="",
        description=(
            "Self-contained web query when needs_web_search is true. For "
            "follow-ups, reconstruct the original fact-seeking question from "
            "the thread (do not leave 'oui' / 'alors?' as the query)."
        ),
    )


_DECIDE_SYSTEM = """You are routing a teammate's DM for an AI employee.

Decide whether the latest teammate message is:
(a) conversation — a question, status check, small talk, clarification,
    a QUESTION about an attached file, OR a research / lookup request
    ("recherche", "look up", "who is", "qui a gagné", "fouille", "find info",
    "enquête", "regarde sur internet", "dis-moi ce que tu trouves") WITHOUT
    an explicit ask for a saved file; or
(b) an actionable work request — they want a PRODUCED deliverable
    (document, report, website/landing page, analysis, edited image,
    transcription…) that should be saved as a file.

Also set needs_web_search when THIS turn needs a live internet lookup:
- Factual/public questions that change over time (scores, news, "who won").
- Explicit lookup asks ("cherche", "look up", "regarde sur internet").
- Short follow-ups that confirm a pending lookup after you offered to check
  online ("oui regarde", "yes look", "alors?", "so?") — set search_query to
  the ORIGINAL fact question from the thread.

Rules:
- Use "task" ONLY when they clearly want a saved deliverable an AI employee
  can produce. Questions or conversational requests about attached files stay
  "chat" — the agent will answer inline.
- Research / info lookup WITHOUT an explicit file ask ("rédige un rapport",
  "crée un doc", "génère un PDF", "write a report") is ALWAYS "chat".
  Mentioning a logo/image as context for research is still "chat".
- "Create a website / landing page / site internet" is always "task", even if
  details are incomplete — the worker will fill sensible defaults.
- "Rédige un rapport / write a report about X" is "task" (document deliverable).
- When needs_web_search is true, search_query must be a full standalone query
  in the teammate's language (not "oui" / "alors?").
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
- NEVER promise to "check the internet later", "take a look online", or
  defer a live lookup to a future turn. Either use web results already in
  the user message, or say clearly that live lookup failed right now.
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
        return {
            "kind": "chat",
            "instruction": "",
            "language": language,
            "needs_web_search": False,
            "search_query": "",
        }

    instruction = decision.instruction.strip()
    kind = decision.kind
    # Hard override: pure research/lookup without an explicit file ask stays chat.
    if kind == "task" and looks_like_research(latest) and not asks_for_file_deliverable(latest):
        kind = "chat"
        instruction = ""
    if kind == "task" and not instruction:
        instruction = latest
    return {
        "kind": kind,
        "instruction": instruction,
        "language": decision.language,
        "needs_web_search": bool(decision.needs_web_search),
        "search_query": (decision.search_query or "").strip(),
    }


async def _stream_reply(
    *,
    system: str,
    user: str,
    phoenix: PhoenixClient,
    workspace_id: str,
    agent_id: str,
    stream_id: str,
    usage: llm.UsageTracker | None = None,
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
            usage=usage,
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
_PDF_VISION_PAGES = 2


async def _download_bytes(url: str) -> bytes:
    import httpx

    async with httpx.AsyncClient(timeout=30, follow_redirects=True) as client:
        resp = await client.get(url)
        resp.raise_for_status()
        return resp.content


def _pdf_pages_needing_vision(data: bytes) -> list[int]:
    """Return 0-based page indices that have embedded images or signature widgets."""
    try:
        import fitz
    except ImportError:
        return []

    try:
        doc = fitz.open(stream=data, filetype="pdf")
    except Exception:  # noqa: BLE001
        return []

    pages: list[int] = []
    for i, page in enumerate(doc):
        has_images = bool(page.get_images(full=True))
        has_sig_widget = False
        for w in page.widgets() or []:
            wtype = (getattr(w, "field_type_string", None) or "").lower()
            wname = (getattr(w, "field_name", None) or "").lower()
            if "sign" in wtype or "sign" in wname:
                has_sig_widget = True
                break
        if has_images or has_sig_widget:
            pages.append(i)
    return pages[:_PDF_VISION_PAGES]


def _render_pdf_page_png(data: bytes, page_index: int) -> bytes | None:
    try:
        import fitz
    except ImportError:
        return None
    try:
        doc = fitz.open(stream=data, filetype="pdf")
        if page_index < 0 or page_index >= doc.page_count:
            return None
        page = doc[page_index]
        # ~150 dpi — enough for signatures without huge payloads
        pix = page.get_pixmap(matrix=fitz.Matrix(1.5, 1.5), alpha=False)
        return pix.tobytes("png")
    except Exception as exc:  # noqa: BLE001
        log.warning("pdf_page_render_failed", page=page_index, error=str(exc))
        return None


async def _vision_pdf_signature_pages(
    name: str, data: bytes, usage: llm.UsageTracker | None = None
) -> str:
    """Vision-read PDF pages that contain images/signature fields (max 2)."""
    pages = _pdf_pages_needing_vision(data)
    if not pages:
        return ""

    chunks: list[str] = []
    for page_index in pages:
        png = _render_pdf_page_png(data, page_index)
        if not png:
            continue
        try:
            description = await llm.vision(
                system=(
                    "You are reading a scanned/signed PDF page. Focus on signature "
                    "blocks, handwritten marks, stamps, and printed names near "
                    "signature lines. Identify EACH party (discloser/recipient/"
                    "מגלה/מקבל/etc.) and say clearly whether their signature is "
                    "present, blank, or unclear. Quote any visible names and IDs. "
                    "Reply in the document's primary language when possible."
                ),
                user_text=(
                    f"PDF «{name}» page {page_index + 1}: describe all signatures "
                    "and signed parties on this page."
                ),
                image_url="page.png",
                image_bytes=png,
                mime_type="image/png",
                usage=usage,
                max_tokens=900,
            )
            if description and description.strip():
                chunks.append(f"[Vision page {page_index + 1}]\n{description.strip()}")
        except Exception as exc:  # noqa: BLE001
            log.warning("pdf_signature_vision_failed", page=page_index, error=str(exc))

    if not chunks:
        return ""
    return "### Visual signature scan\n" + "\n\n".join(chunks)


async def _load_attachment_previews(
    attachments: list[dict[str, Any]], usage: llm.UsageTracker | None = None
) -> str:
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
                        "logos, brand marks, and key visual details. Reply in the "
                        "language of any text you find on the image, otherwise English."
                    ),
                    user_text=f"Analyze the attached image «{name}».",
                    image_url=url,
                    image_bytes=data,
                    mime_type=mime or None,
                    usage=usage,
                    max_tokens=1000,
                )
                parts.append(f"### {name} (image)\n{(description or '(empty)').strip()}")
            except Exception as exc:  # noqa: BLE001
                log.warning("direct_chat_vision_failed", name=name, error=str(exc))
                parts.append(f"### {name}\n(vision analysis failed)")
            continue

        if extractors.is_extractable(name, mime):
            result = extractors.extract_bytes(data, filename=name, mime_type=mime)
            block_parts: list[str] = []
            if result and result.text.strip():
                preview = result.text.strip()[:_PREVIEW_CHARS]
                truncated = "…" if len(result.text) > _PREVIEW_CHARS else ""
                block_parts.append(
                    f"### {name} ({result.format})\n{preview}{truncated}"
                )
            else:
                block_parts.append(f"### {name}\n(no extractable text)")

            if (ext == ".pdf" or mime == "application/pdf"):
                from app.config import get_settings

                if get_settings().openai_api_key:
                    vision_extra = await _vision_pdf_signature_pages(name, data, usage=usage)
                    if vision_extra:
                        block_parts.append(vision_extra)

            parts.append("\n\n".join(block_parts))
            continue

        parts.append(f"### {name}\n(unsupported format for inline reading)")

    if not parts:
        return ""
    return (
        "Attached file contents (use these to answer the teammate's question "
        "directly — do not ask which document they mean). When a visual "
        "signature scan is present, TRUST it over empty printed signature lines:\n\n"
        + "\n\n".join(parts)
    )


async def _web_research_context(query: str) -> str:
    """Run web_search and format hits for the chat reply prompt."""
    unavailable = (
        "Web search results: UNAVAILABLE. Tell the teammate clearly that you "
        "could not look this up live right now. Do NOT invent facts or scores. "
        "Do NOT promise to check later."
    )
    try:
        import app.tools.web  # noqa: F401 — ensure tool registration
        from app.tools.registry import RunContext
        from app.tools.web import format_results_for_llm, web_search

        ctx = RunContext(
            run_id="direct-chat",
            workspace_id="",
            task_id="",
            task_title=query[:200],
        )
        payload = await web_search({"query": query, "max_results": 5}, ctx)
        if not isinstance(payload, dict):
            return f"{unavailable} Error: invalid search payload"
        if payload.get("error") or not (payload.get("results") or []):
            err = payload.get("error") or "no results"
            log.warning("direct_chat_web_search_empty", query=query[:120], error=err)
            return f"{unavailable} Error: {err}"
        body = format_results_for_llm(payload)
        return (
            "Web search results (use ONLY these facts; cite source URLs):\n" + body
        )
    except Exception as exc:  # noqa: BLE001
        log.warning("direct_chat_web_search_failed", error=str(exc))
        return f"{unavailable} Error: {exc}"


async def reply(payload: dict[str, Any], phoenix: PhoenixClient | None = None) -> bool:
    """Streams the agent's DM reply (and possibly starts a task) via Phoenix."""
    if not llm.is_configured():
        return False

    phoenix = phoenix or PhoenixClient()
    agent = payload.get("agent") or {}
    conversation = payload.get("conversation") or []
    attachments = payload.get("attachments") or []
    usage = llm.UsageTracker()

    thread = "\n".join(
        f"- {entry.get('author', '?')}: {entry.get('body', '')}"
        for entry in conversation[-14:]
        if isinstance(entry, dict)
    )
    latest = _latest_teammate_message(conversation)

    file_context = _format_attachments(attachments)
    # Bound content preview so questions about a PDF/image can be answered
    # inline without spinning up a task.
    file_preview = (
        await _load_attachment_previews(attachments, usage=usage) if attachments else ""
    )
    decide_thread = thread
    if file_context:
        decide_thread = f"{decide_thread}\n{file_context}"
    if file_preview:
        decide_thread = f"{decide_thread}\n\n{file_preview}"

    decision = await _decide(decide_thread, latest, usage=usage)
    start_task = decision["kind"] == "task"
    instruction = decision["instruction"]
    language = decision["language"]
    needs_web, search_query = resolve_web_research(
        latest,
        conversation if isinstance(conversation, list) else None,
        decision_needs_web=bool(decision.get("needs_web_search")),
        decision_query=str(decision.get("search_query") or ""),
    )

    if start_task:
        intent_block = (
            "The teammate asked you to PRODUCE something. Confirm enthusiastically "
            "what you'll deliver and say you'll share the result in this thread "
            "shortly. Do NOT ask blocking clarifying questions — start with sensible "
            f"defaults if details are missing.\nBrief you will execute: {instruction}"
        )
        needs_web = False
    elif needs_web:
        intent_block = (
            "This is a RESEARCH / lookup question. Answer inline in 1-3 short "
            "paragraphs using ONLY the web search results provided in the user "
            "message. Cite sources by URL. Do not invent facts. If results are "
            "UNAVAILABLE, say so clearly in this turn — never promise to check "
            "the internet later. Do not start a task, write a report file, or "
            "edit/generate logos."
        )
    else:
        intent_block = (
            "This is a conversational message. Answer it directly using any "
            "attached file contents provided in the user message. Do not start "
            "a task or invent deliverables. Do not ask which document they mean "
            "when an attachment is already provided. Do not offer to look "
            "something up on the internet unless web search results are already "
            "in the user message."
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

    if needs_web:
        web_block = await _web_research_context(search_query or latest)
        if web_block:
            user_prompt = f"{user_prompt}\n\n{web_block}"

    text = await _stream_reply(
        system=system,
        user=user_prompt,
        phoenix=phoenix,
        workspace_id=workspace_id,
        agent_id=agent_id,
        stream_id=stream_id,
        usage=usage,
    )

    # Meter the whole DM turn (decision + attachment vision + streamed reply)
    # even when the reply came out empty — the LLM cost is already incurred.
    await phoenix.report_usage(
        workspace_id,
        "agent_chat",
        usage.cost_cents,
        token_usage=usage.as_dict(),
        agent_id=agent_id,
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
