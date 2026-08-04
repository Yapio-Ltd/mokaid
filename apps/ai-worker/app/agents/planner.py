"""Run planning: LLM planner with a deterministic fallback.

With an OpenAI key configured, the plan is produced by the model constrained
to the registered tools. Without a key (offline dev, tests) the deterministic
plans keep the full run/approve/resume lifecycle exercisable.
"""

from typing import Any

import structlog

from app import llm
from app.schemas import RunRequest
from app.tools.registry import list_tools

log = structlog.get_logger()

MAX_PLAN_STEPS = 8

_PLANNER_SYSTEM = """You are the planner for an AI agent working inside a team workspace.
Given a task, produce a short plan of tool calls that accomplishes it.

Respond with a JSON object: {"steps": [{"tool": string, "input": object}]}

Available tools:
- search_knowledge {query}: semantic search in the workspace knowledge base
- traverse_knowledge {query}: knowledge-graph neighborhood (multi-hop relationships)
- knowledge_path {from, to}: shortest path between two concepts
- explain_concept {query}: neighbors with EXTRACTED/INFERRED confidence
- save_knowledge_outcome {outcome, question, answer_summary, node_ids}: record useful|dead_end|corrected after using the graph
- web_search {query, max_results}: search the public internet (titles, URLs, snippets) — use for research / lookup / who-is / company questions
- summarize {text}: summarize text
- draft_document {title, brief, context}: write a Markdown document
- generate_report {period}: produce a structured work report
- update_task {status, progress_percent, description}: update the current task
- create_subtasks {subtasks: [string]}: break the task into subtasks
- send_email {to, subject, body}: send an email (requires human approval)
- post_social {network, content}: publish a social post (requires human approval)
- analyze_file {file_url, question}: analyze any file (image, document) using AI vision — describe, explain, extract info
- transform_image {file_url, instruction, original_filename}: modify an image (color changes, filters, resize, rotate, flip, or creative edits via DALL-E)
- transcribe_audio {file_url, original_filename}: transcribe audio/video to text using Whisper
- extract_document_text {file_url, original_filename}: extract text from PDFs and documents
- choose_site_delivery {brief}: ALWAYS call first for any new website/site/shop ask unless delivery is already known (html|webapp). Pauses for the human to pick HTML showcase vs full Next.js codebase.
- generate_website {brief, brand_name, style}: polished self-contained HTML landing/vitrine (only after delivery=html)
- generate_webapp {brief, brand_name, style}: full React/Next.js/TypeScript multi-file codebase + HTML preview + ZIP + GitHub/Vercel docs (only after delivery=webapp)
%(mcp_tools)s
Rules:
- 1 to %(max_steps)d steps, ordered.
- Only use listed tools. Prefer the minimal plan that completes the task.
- Start with web_search for public-web research; use search_knowledge when workspace context would help.
- Prefer traverse_knowledge / explain_concept when the question is about how concepts connect; call save_knowledge_outcome after graph-backed answers.
- Only include send_email/post_social if the task explicitly asks for it.
- Research / lookup without an explicit written-report ask: web_search only (possibly summarize). Do NOT add draft_document, transform_image, or generate_website.

File processing (HIGHEST PRIORITY):
- When the task involves modifying, analyzing, or processing an attached file,
  ALWAYS use the appropriate file tool (transform_image, analyze_file, transcribe_audio, extract_document_text).
- Pass the file's download_url as file_url and the file's name as original_filename.
- For image modifications (color change, resize, filter, edit, transform, etc.), use transform_image.
  transform_image IS the deliverable — do NOT add draft_document after it.

Iteration & continuity (CRITICAL):
- Files are labeled [input] (user-provided) or [agent output] (result of a
  previous run), listed oldest first.
- When the conversation asks to adjust, correct or iterate on the previous
  result ("change the text", "I prefer it in blue", "same but…"), you MUST
  use the MOST RECENT [agent output] file as file_url — never restart from
  the original [input] unless the user explicitly asks to start over.
- Write the transform_image instruction so it modifies ONLY what the user
  asked to change and explicitly preserves everything else about that image
  (style, composition, colors), e.g. "Replace the text 'METRO' with 'Mocina',
  keep the retro style, colors and layout identical."
- For understanding/describing an image or document, use analyze_file.
  analyze_file IS the deliverable — do NOT add draft_document after it.
- For audio/video, use transcribe_audio. This IS the deliverable.
- Never skip file processing — if files are attached, they MUST be processed.
- File tool outputs (transformed images, transcripts, analyses) are complete
  deliverables on their own. Do NOT append draft_document or generate_report
  after a file processing tool.

Text-only tasks (no attached files, or files already processed):
- Research / info lookup: end with web_search (and optional summarize). That
  IS enough — do not invent a report file.
- Other written work MUST end with a reviewable deliverable: draft_document
  (briefs, specs, plans…) or generate_report for reporting tasks.
  search_knowledge or summarize alone is never a complete plan for those.

Websites & landing pages:
- For ANY new site / ecommerce / boutique / landing ask: call choose_site_delivery
  FIRST (unless delivery=html|webapp is already set). Never jump straight to
  generate_website for ecommerce / "site entier" — the human must choose.
- After delivery=html: generate_website with a complete brief. That IS the deliverable.
- After delivery=webapp: generate_webapp (HTML preview + real Next codebase + ZIP).
- On iteration requests ("change the color", "add a pricing section"), call
  generate_website or generate_webapp again with a brief that restates the
  full previous intent plus the requested change (skip choose_site_delivery).

Prioritization judgment:
- Urgent/high-priority tasks (or tasks close to their due date): go straight to
  the deliverable — skip optional research and never pad the plan with
  nice-to-have steps.
- Low-priority tasks: it is fine to invest one extra step in context gathering
  (search_knowledge) if it clearly improves the result.
- Large or vague tasks: create_subtasks first so humans can follow progress.

MCP judgment (connected external tools, prefixed mcp:*):
- They are real external integrations with real side effects and latency.
- Use one ONLY when the task genuinely needs that external system (its data or
  its actions cannot be replicated with internal tools). If an internal tool
  achieves the same outcome, always prefer the internal tool.
- Never call an MCP tool "just in case" or to double-check something you
  already know. One targeted call beats several exploratory calls.
- Pass arguments matching the tool schema exactly.
- Attached files already have download URLs — you do not need a storage MCP to
  read them.
"""


def _mcp_tools_block(mcp_tools: list[dict[str, Any]]) -> str:
    if not mcp_tools:
        return ""

    lines = ["", "Connected external tools (via MCP, use the exact name):"]
    for tool in mcp_tools:
        description = (tool.get("description") or "").strip().split("\n")[0][:160]
        lines.append(f"- {tool['name']}: {description} [server: {tool.get('server', '?')}]")
    lines.append("")
    return "\n".join(lines)


def deterministic_plan(request: RunRequest) -> list[dict[str, Any]]:
    """Fixed plans keyed on the requested action (offline fallback)."""

    has_images = any(
        (f.mime_type or "").startswith("image/") for f in request.attached_files
    )
    has_audio = any(
        (f.mime_type or "").startswith("audio/") for f in request.attached_files
    )

    if has_images:
        # Latest image wins: files are ordered oldest→newest, so iterating on
        # a previous agent output naturally targets the most recent result.
        images = [f for f in request.attached_files if (f.mime_type or "").startswith("image/")]
        file = images[-1]
        return [
            {"tool": "transform_image", "input": {
                "file_url": file.download_url,
                "instruction": request.task_description or request.task_title or "",
                "original_filename": file.name,
            }},
        ]
    if has_audio:
        file = next(f for f in request.attached_files if (f.mime_type or "").startswith("audio/"))
        return [
            {"tool": "transcribe_audio", "input": {
                "file_url": file.download_url,
                "original_filename": file.name,
            }},
        ]

    action = request.input.get("action", "summarize")

    if action == "send_campaign":
        return [
            {"tool": "search_knowledge", "input": {"query": request.task_title or ""}},
            {"tool": "draft_document", "input": {"title": f"Campaign: {request.task_title}"}},
            {
                "tool": "send_email",
                "input": {
                    "to": request.input.get("to", "list:subscribers"),
                    "subject": request.task_title,
                },
            },
        ]
    if action == "report":
        return [
            {
                "tool": "generate_report",
                "input": {"period": request.input.get("period", "last_30_days")},
            },
        ]
    return [
        {"tool": "search_knowledge", "input": {"query": request.task_title or ""}},
        {
            "tool": "summarize",
            "input": {"text": request.task_description or request.task_title or ""},
        },
    ]


def _ensure_specialist_bootstrap(request: RunRequest, steps: list[dict[str, Any]]) -> list[dict[str, Any]]:
    agent = request.agent or {}
    if not (agent.get("tier") == "specialist" or agent.get("domain_skill_index")):
        return steps
    if steps and steps[0].get("tool") == "search_knowledge":
        return steps
    query = " ".join(
        x for x in [
            request.task_title or "",
            (request.task_description or "")[:200],
            (agent.get("knowledge_brief") or "")[:200],
            agent.get("archetype") or "",
        ]
        if x
    ).strip() or (request.task_title or "domain knowledge")
    return [{"tool": "search_knowledge", "input": {"query": query}}] + list(steps)


async def plan_steps(
    request: RunRequest,
    usage: llm.UsageTracker,
    mcp_tools: list[dict[str, Any]] | None = None,
) -> list[dict[str, Any]]:
    """Returns the ordered tool steps for a run (native + granted MCP tools)."""
    mcp_tools = mcp_tools or []

    if not llm.is_configured():
        return _ensure_specialist_bootstrap(request, deterministic_plan(request))

    files_block = (
        "\n".join(
            f"- [{'agent output' if f.source == 'agent_output' else 'input'}] "
            f"{f.name} ({f.mime_type or 'unknown type'}, {f.size_bytes or '?'} bytes)"
            + (f"  download_url: {f.download_url}" if f.download_url else "")
            for f in request.attached_files
        )
        or "(none)"
    )

    # Task-thread conversation (user replies after a failed/reviewed run):
    # the latest human message often contains the actual course correction.
    conversation = request.input.get("conversation") or []
    conversation_block = (
        "\n".join(
            f"- {entry.get('author', '?')}: {entry.get('body', '')}"
            for entry in conversation[-8:]
            if isinstance(entry, dict)
        )
        or "(none)"
    )

    extra_input = {k: v for k, v in request.input.items() if k != "conversation"}

    try:
        result = await llm.chat_json(
            system=_PLANNER_SYSTEM
            % {"max_steps": MAX_PLAN_STEPS, "mcp_tools": _mcp_tools_block(mcp_tools)},
            user=(
                f"Task title: {request.task_title or 'Untitled'}\n"
                f"Task description: {request.task_description or '(none)'}\n"
                f"Priority: {request.task_priority or 'medium'}\n"
                f"Due date: {request.task_due_at or '(none)'}\n"
                f"Attached files:\n{files_block}\n"
                f"Task conversation (most recent last — follow the latest human instructions):\n"
                f"{conversation_block}\n"
                f"Extra input: {extra_input}"
            ),
            usage=usage,
            max_tokens=800,
            quality="smart",
        )
    except Exception as exc:  # noqa: BLE001 — planner errors fall back, run continues
        log.warning("llm_planner_failed", error=str(exc))
        return _ensure_specialist_bootstrap(request, deterministic_plan(request))

    known = set(list_tools()) | {tool["name"] for tool in mcp_tools}
    steps = [
        {"tool": step["tool"], "input": step.get("input") or {}}
        for step in result.get("steps", [])
        if isinstance(step, dict) and step.get("tool") in known
    ][:MAX_PLAN_STEPS]

    if not steps:
        log.warning("llm_planner_empty_plan", result=result)
        return _ensure_specialist_bootstrap(request, deterministic_plan(request))

    log.info("llm_plan_created", steps=[s["tool"] for s in steps])
    return _ensure_specialist_bootstrap(request, steps)
