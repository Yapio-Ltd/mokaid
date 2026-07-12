"""Deep-agent execution engine, built on LangChain's `deepagents` harness.

Replaces the fixed plan-then-execute loop with a full deep agent per the
LangChain Deep Agents best practices:

- planning through the built-in `write_todos` tool — every plan update is
  streamed to Phoenix so the UI shows a live mission checklist;
- a virtual filesystem for context management — files written under
  `/deliverables/` become Drive files linked to the task, files under
  `/memories/` enrich the agent's vectorized knowledge;
- sub-agent delegation via the built-in `task` tool;
- agent-to-agent consultation via `consult_colleague` (visible in the task
  thread, so users watch their AI employees confer);
- the existing human-in-the-loop approvals: risky tools pause the run until
  a human decides, exactly like the legacy engine.

The legacy deterministic engine in `runner.py` remains the offline/test path.
"""

from collections.abc import Awaitable, Callable
from pathlib import PurePosixPath
from typing import Any

import structlog

from app import llm
from app.agents import colleagues as colleagues_mod
from app.clients.phoenix import PhoenixClient
from app.config import get_settings
from app.mcp.client import McpToolbox
from app.policies.approval import requires_approval, risk_for_tool
from app.schemas import RunRequest, RunState, RunStatus, ToolCall
from app.tools.registry import RunContext, get_tool

log = structlog.get_logger()

DELIVERABLES_DIR = "/deliverables/"
MEMORIES_DIR = "/memories/"
RECURSION_LIMIT = 100

_MIME_BY_EXT = {
    ".md": "text/markdown",
    ".txt": "text/plain",
    ".json": "application/json",
    ".html": "text/html",
    ".htm": "text/html",
    ".csv": "text/csv",
    ".xml": "application/xml",
    ".yml": "text/yaml",
    ".yaml": "text/yaml",
}

_SYSTEM_TEMPLATE = """You are {name}, an AI employee working inside your team's workspace.
Role: {role} — Department: {department}
Skills: {skills}

You were assigned a real mission by a teammate. Work autonomously and
deliver professional-quality results. Reply and write deliverables ENTIRELY
in {language_name} — never switch languages mid-mission.

## Mission
Title: {task_title}
Description: {task_description}
Priority: {priority} — Due: {due}
Mission kind: {mission_kind}
Attached files:
{files_block}
Conversation so far (most recent last — follow the latest human instructions):
{conversation_block}

## How you work
1. For any non-trivial mission, first lay out your plan with `write_todos`
   and keep it updated as you progress — your teammates watch this checklist
   live. Keep todos short and in {language_name}.
2. Use your tools; offload long intermediate content to files.
3. Write every final deliverable as a file under `{deliverables_dir}`
   (e.g. `{deliverables_dir}rapport-onboarding.md`). Documents in Markdown,
   data in JSON/CSV, web pages in HTML. Deliverables saved there are handed
   to your teammate automatically — a mission without a deliverable file is
   an unfinished mission, UNLESS a specialized tool (transform_image,
   generate_website, transcribe_audio) already produced the deliverable
   itself.
4. {mission_kind_rule}
5. When another AI employee's specialty would clearly enrich the result,
   consult them with `consult_colleague` — only when genuinely useful, at
   most a couple of times. Available colleagues:
{colleagues_block}
6. If you learned something reusable (domain facts, preferences, pitfalls),
   write a short note to `{memories_dir}notes.md` — it becomes part of your
   long-term memory.
7. Some tools (emails, social posts, sensitive external actions) require
   human approval: calling them pauses you until a human decides. If the
   action is rejected, adapt and continue without it.

## Iteration rules
- Files labeled [agent output] are results of your previous runs. When the
  conversation asks to adjust a previous result, start from the MOST RECENT
  [agent output] file — never restart from the original input unless asked.
- Never invent facts, metrics or sources. Search the workspace knowledge
  base when workspace context would help.
- Do NOT end the mission with clarifying questions alone. Produce a first
  version with sensible defaults; your teammate can ask for revisions after.

When the mission is complete, end with a short, warm closing message (first
person, no markdown, in {language_name}) summarizing what you delivered —
it is relayed to your teammate in chat."""


def _mission_kind_rule(kind: str, language: str) -> str:
    fr = language == "fr"
    if kind == "website":
        return (
            "This is a WEBSITE mission. You MUST call `generate_website` with a "
            "complete brief (fill sensible defaults for missing brand/style). "
            "Do not finish without that tool succeeding."
            if not fr
            else "Mission SITE WEB. Tu DOIS appeler `generate_website` avec un "
            "brief complet (complète avec des valeurs raisonnables si des détails "
            "manquent). Ne termine jamais sans ce livrable."
        )
    if kind in ("document", "image", "analysis"):
        tool = {"document": "draft_document", "image": "transform_image", "analysis": "analyze_file"}[
            kind
        ]
        return (
            f"This is a {kind} mission. You MUST produce a real deliverable via "
            f"`{tool}` (or an equivalent specialized tool) before closing."
        )
    return (
        "Produce a concrete deliverable when the mission asks for one — "
        "never close with questions alone."
    )


def is_available() -> bool:
    """Deep engine is usable when deepagents is installed and an LLM key set."""
    if not llm.is_configured():
        return False
    try:
        import deepagents  # noqa: F401
    except ImportError:
        return False
    return True


def _build_model() -> Any:
    settings = get_settings()
    if settings.anthropic_api_key:
        from langchain_anthropic import ChatAnthropic

        return ChatAnthropic(
            model=settings.anthropic_smart_model,
            api_key=settings.anthropic_api_key,
            max_tokens=8000,
        )

    from langchain_openai import ChatOpenAI

    return ChatOpenAI(
        model=settings.openai_model,
        api_key=settings.openai_api_key,
        use_responses_api=False,
    )


def _price_key(model_name: str) -> str:
    """Maps a provider model id to the closest known pricing key."""
    from app.llm import _PRICES  # noqa: PLC0415

    for key in _PRICES:
        if model_name.startswith(key) or key.startswith(model_name):
            return key
    return model_name


def _files_block(request: RunRequest) -> str:
    lines = [
        f"- [{'agent output' if f.source == 'agent_output' else 'input'}] "
        f"{f.name} ({f.mime_type or 'unknown type'})"
        + (f" download_url: {f.download_url}" if f.download_url else "")
        for f in request.attached_files
    ]
    return "\n".join(lines) or "(none)"


def _conversation_block(request: RunRequest) -> str:
    conversation = request.input.get("conversation") or []
    lines = [
        f"- {entry.get('author', '?')}: {entry.get('body', '')}"
        for entry in conversation[-10:]
        if isinstance(entry, dict)
    ]
    return "\n".join(lines) or "(none)"


def _colleagues_block(request: RunRequest) -> str:
    lines = [
        f"   - {c.name} — {c.role_title or 'Generalist'}"
        + (f" ({', '.join(c.skills[:4])})" if c.skills else "")
        for c in request.colleagues
    ]
    return "\n".join(lines) or "   - (none — you work solo on this one)"


def _system_prompt(request: RunRequest) -> str:
    from app.agents.mission_kind import detect_mission_kind, language_for_request

    agent = request.agent or {}
    language = language_for_request(request)
    kind = detect_mission_kind(request)
    return _SYSTEM_TEMPLATE.format(
        name=agent.get("display_name") or "an AI employee",
        role=agent.get("role_title") or "Generalist",
        department=agent.get("department") or "—",
        skills=", ".join(agent.get("skills") or []) or "generalist",
        task_title=request.task_title or "Untitled",
        task_description=request.task_description or "(none)",
        priority=request.task_priority or "medium",
        due=request.task_due_at or "(none)",
        mission_kind=kind,
        mission_kind_rule=_mission_kind_rule(kind, language),
        language_name="French" if language == "fr" else "English",
        files_block=_files_block(request),
        conversation_block=_conversation_block(request),
        colleagues_block=_colleagues_block(request),
        deliverables_dir=DELIVERABLES_DIR,
        memories_dir=MEMORIES_DIR,
    )


class _Engine:
    """One deep-agent execution: tools, approval gating, todo streaming."""

    def __init__(
        self,
        request: RunRequest,
        ctx: RunContext,
        state: RunState,
        phoenix: PhoenixClient,
        toolbox: McpToolbox,
        mcp_tools: list[dict[str, Any]],
        wait_for_decision: Callable[[str], Awaitable[Any]],
    ) -> None:
        self.request = request
        self.ctx = ctx
        self.state = state
        self.phoenix = phoenix
        self.toolbox = toolbox
        self.mcp_tools = mcp_tools
        self.wait_for_decision = wait_for_decision
        self.consultations: list[dict[str, Any]] = []
        self.last_todos: list[dict[str, Any]] = []
        self.progress_updates = 0

    # ---------- Approval gating (human in the loop) ----------

    async def _gate(self, tool_name: str, tool_input: dict[str, Any]) -> tuple[bool, dict]:
        """Pauses the run for approval when the tool is risky. Returns
        (approved, effective_input)."""
        if not requires_approval(tool_name):
            return True, tool_input

        risk = risk_for_tool(tool_name)
        self.state.status = RunStatus.WAITING_FOR_APPROVAL
        self.state.pending_tool = ToolCall(tool=tool_name, input=tool_input, risk=risk)

        created = await self.phoenix.request_approval(
            self.request.run_id,
            tool_name,
            tool_input,
            risk.value,
            proposed_action=_describe_action(tool_name, tool_input),
        )
        if created is None:
            raise RuntimeError(f"could not create the approval request for {tool_name}")

        await self.phoenix.update_run_status(self.request.run_id, self.state.status.value)
        log.info("deep_run_waiting_approval", run_id=self.request.run_id, tool=tool_name)

        decision = await self.wait_for_decision(self.request.run_id)
        self.state.pending_tool = None
        self.state.status = RunStatus.RUNNING
        await self.phoenix.update_run_status(self.request.run_id, self.state.status.value)

        if decision.decision == "rejected":
            return False, tool_input
        if decision.decision == "edited" and decision.payload:
            return True, decision.payload
        return True, tool_input

    async def _run_tool(self, tool_name: str, tool_input: dict[str, Any]) -> Any:
        """Executes one gated tool call and records it on the run state."""
        risk = risk_for_tool(tool_name)
        call = ToolCall(tool=tool_name, input=tool_input, risk=risk)

        if requires_approval(tool_name):
            approved, effective_input = await self._gate(tool_name, tool_input)
            call.approved = approved
            call.input = effective_input
            if not approved:
                self.state.tool_calls.append(call)
                return {
                    "skipped": True,
                    "reason": "The human reviewer rejected this action. Adapt and continue without it.",
                }
        else:
            call.approved = None

        if self.toolbox.has(tool_name):
            output = await self.toolbox.call(tool_name, call.input)
        else:
            fn = get_tool(tool_name)
            if fn is None:
                raise ValueError(f"unknown tool: {tool_name}")
            enriched = {
                **call.input,
                "_attached_files": [f.model_dump() for f in self.request.attached_files],
            }
            output = await fn(enriched, self.ctx)

        call.output = output
        self.state.tool_calls.append(call)
        self.state.steps.append({"tool": tool_name, "ok": True})
        log.info("deep_tool_executed", run_id=self.request.run_id, tool=tool_name)
        return output

    # ---------- LangChain tool construction ----------

    def _build_tools(self) -> list[Any]:
        from langchain_core.tools import StructuredTool

        engine = self

        async def search_knowledge(query: str) -> Any:
            """Semantic search over the workspace knowledge base (general +
            project + your own experience). Use when workspace context helps."""
            return await engine._run_tool("search_knowledge", {"query": query})

        async def draft_document(title: str, brief: str = "", context: str = "") -> Any:
            """Writes a complete, professional Markdown document with the
            long-form generator. Prefer this for large polished documents;
            remember to also save the result under /deliverables/."""
            return await engine._run_tool(
                "draft_document", {"title": title, "brief": brief, "context": context}
            )

        async def generate_report(period: str = "last_30_days") -> Any:
            """Produces a structured JSON work report for a period."""
            return await engine._run_tool("generate_report", {"period": period})

        async def update_task(
            status: str = "", progress_percent: int = -1, description: str = ""
        ) -> Any:
            """Updates the current task (status, progress_percent 0-100,
            description). Only pass the fields you want to change."""
            payload: dict[str, Any] = {}
            if status:
                payload["status"] = status
            if progress_percent >= 0:
                payload["progress_percent"] = progress_percent
            if description:
                payload["description"] = description
            return await engine._run_tool("update_task", payload)

        async def create_subtasks(subtasks: list[str]) -> Any:
            """Breaks the mission into visible subtasks (list of titles)."""
            return await engine._run_tool("create_subtasks", {"subtasks": subtasks})

        async def send_email(to: str, subject: str, body: str = "") -> Any:
            """Sends an email (requires human approval — the run pauses)."""
            return await engine._run_tool(
                "send_email", {"to": to, "subject": subject, "body": body}
            )

        async def post_social(network: str, content: str) -> Any:
            """Publishes a social media post (requires human approval)."""
            return await engine._run_tool(
                "post_social", {"network": network, "content": content}
            )

        async def analyze_file(file_url: str = "", question: str = "") -> Any:
            """Analyzes any attached file (image, document) with AI vision —
            describe, explain, extract information. Pass the attached file's
            download_url as file_url when known; if omitted, the most recent
            attached file is used automatically."""
            return await engine._run_tool(
                "analyze_file", {"file_url": file_url, "question": question}
            )

        async def transform_image(
            instruction: str, file_url: str = "", original_filename: str = ""
        ) -> Any:
            """Modifies an image (colors, filters, resize, creative edits).
            Pass the attached file's download_url as file_url (and its name as
            original_filename). If file_url is omitted, the most recent attached
            image is used automatically. The transformed image is saved as a
            deliverable automatically."""
            return await engine._run_tool(
                "transform_image",
                {
                    "file_url": file_url,
                    "instruction": instruction,
                    "original_filename": original_filename,
                },
            )

        async def transcribe_audio(file_url: str = "", original_filename: str = "") -> Any:
            """Transcribes an audio/video file to text (Whisper). Pass the
            attached file's download_url as file_url when known."""
            return await engine._run_tool(
                "transcribe_audio",
                {"file_url": file_url, "original_filename": original_filename},
            )

        async def extract_document_text(file_url: str = "", original_filename: str = "") -> Any:
            """Extracts the text of a PDF or document file. Pass the attached
            file's download_url as file_url when known."""
            return await engine._run_tool(
                "extract_document_text",
                {"file_url": file_url, "original_filename": original_filename},
            )

        async def generate_website(brief: str, brand_name: str = "", style: str = "") -> Any:
            """Designs and builds a complete landing page / one-page website
            (premium, responsive, self-contained HTML). Saved as a
            deliverable automatically. Put ALL requirements in the brief."""
            return await engine._run_tool(
                "generate_website",
                {"brief": brief, "brand_name": brand_name, "style": style},
            )

        async def consult_colleague(colleague_name: str, question: str) -> str:
            """Asks another AI employee of the team for professional input.
            Use only when their specialty genuinely enriches the deliverable.
            The exchange is visible to your teammates in the task thread."""
            return await colleagues_mod.consult(
                engine.request, engine.ctx, colleague_name, question, engine.consultations
            )

        native = [
            search_knowledge,
            draft_document,
            generate_report,
            update_task,
            create_subtasks,
            send_email,
            post_social,
            analyze_file,
            transform_image,
            transcribe_audio,
            extract_document_text,
            generate_website,
        ]
        tools = [StructuredTool.from_function(coroutine=fn) for fn in native]

        if self.request.colleagues:
            tools.append(StructuredTool.from_function(coroutine=consult_colleague))

        for mcp_tool in self.mcp_tools:
            tools.append(self._build_mcp_tool(mcp_tool))

        return tools

    def _build_mcp_tool(self, mcp_tool: dict[str, Any]) -> Any:
        from langchain_core.tools import StructuredTool

        engine = self
        qualified = mcp_tool["name"]
        schema = mcp_tool.get("input_schema") or {"type": "object", "properties": {}}

        async def call_mcp(**kwargs: Any) -> Any:
            return await engine._run_tool(qualified, kwargs)

        description = (
            f"[External integration via {mcp_tool.get('server', 'MCP')}] "
            f"{(mcp_tool.get('description') or '').strip()[:600]}"
        )
        # LangChain tool names must be alphanumeric/_/- : mcp:github:create_issue
        # becomes mcp__github__create_issue and is mapped back on execution.
        safe_name = qualified.replace(":", "__")
        return StructuredTool.from_function(
            coroutine=call_mcp,
            name=safe_name,
            description=description,
            args_schema=schema,
        )

    # ---------- Todo plan streaming ----------

    async def _push_todos(self, todos: list[dict[str, Any]]) -> None:
        normalized = [
            {"content": t.get("content", ""), "status": t.get("status", "pending")}
            for t in todos
            if isinstance(t, dict)
        ]
        if normalized == self.last_todos:
            return
        previous = self.last_todos
        self.last_todos = normalized
        try:
            await self.phoenix.update_run_plan(self.request.run_id, normalized)
        except Exception as exc:  # noqa: BLE001 — plan streaming is best-effort
            log.warning("todo_push_failed", run_id=self.request.run_id, error=str(exc))

        await self._post_progress_update(previous, normalized)

    # Cap the conversational progress messages so long plans don't flood the
    # thread — the live checklist already shows every tick.
    _MAX_PROGRESS_UPDATES = 4

    async def _post_progress_update(
        self, previous: list[dict[str, Any]], current: list[dict[str, Any]]
    ) -> None:
        """Posts a short, human update ("done with X, now doing Y") when a
        todo just transitioned to completed. Never raises."""
        if self.progress_updates >= self._MAX_PROGRESS_UPDATES:
            return

        before = {t["content"]: t["status"] for t in previous}
        newly_done = [
            t["content"]
            for t in current
            if t["status"] == "completed"
            and t["content"]
            and before.get(t["content"]) not in (None, "completed")
        ]
        if not newly_done:
            return

        # Skip the very last todo: the final delivery message covers it.
        if all(t["status"] == "completed" for t in current):
            return

        next_up = next(
            (t["content"] for t in current if t["status"] == "in_progress"), None
        )

        french = _looks_french(
            f"{self.request.task_title or ''} {self.request.task_description or ''}"
        )
        done_part = newly_done[0]
        if french:
            text = f"✅ {done_part}"
            if next_up:
                text += f" — je passe à : {next_up}"
        else:
            text = f"✅ {done_part}"
            if next_up:
                text += f" — now on to: {next_up}"

        self.progress_updates += 1
        try:
            if self.request.input.get("chat_task") and self.request.agent_id:
                # Chat-born mission: progress lives where the user asked for it.
                await self.phoenix.post_agent_chat_message(
                    self.request.workspace_id, self.request.agent_id, text
                )
            else:
                await self.phoenix.post_task_comment(
                    self.request.workspace_id,
                    self.request.task_id,
                    text,
                    agent_id=self.request.agent_id,
                )
        except Exception as exc:  # noqa: BLE001 — progress chatter is a nicety
            log.warning(
                "progress_update_failed", run_id=self.request.run_id, error=str(exc)
            )

    # ---------- Deliverables & memories ----------

    @staticmethod
    def _file_content(file_data: Any) -> str | None:
        if isinstance(file_data, dict):
            content = file_data.get("content")
            if isinstance(content, str):
                return content
            if isinstance(content, list):  # v1 format: list of lines
                return "\n".join(str(line) for line in content)
        if isinstance(file_data, str):
            return file_data
        return None

    async def _collect_outputs(self, files: dict[str, Any]) -> list[str]:
        """Saves /deliverables/ files to the Drive and /memories/ files to
        the agent's knowledge. Returns the list of artifact filenames."""
        artifacts: list[str] = []

        for path, file_data in (files or {}).items():
            content = self._file_content(file_data)
            if content is None or not content.strip():
                continue

            if path.startswith(DELIVERABLES_DIR):
                filename = PurePosixPath(path).name
                mime = _MIME_BY_EXT.get(PurePosixPath(path).suffix.lower(), "text/plain")
                try:
                    saved = await self.phoenix.save_task_output(
                        self.request.workspace_id,
                        self.request.task_id,
                        filename,
                        content,
                        mime_type=mime,
                    )
                    if saved:
                        artifacts.append(filename)
                except Exception as exc:  # noqa: BLE001 — best-effort per file
                    log.warning(
                        "deliverable_save_failed",
                        run_id=self.request.run_id,
                        path=path,
                        error=str(exc),
                    )
            elif path.startswith(MEMORIES_DIR) and self.request.agent_id:
                try:
                    await self.phoenix.save_agent_memory(
                        self.request.workspace_id,
                        self.request.agent_id,
                        f"Notes — {self.request.task_title or 'mission'}",
                        content,
                    )
                except Exception as exc:  # noqa: BLE001
                    log.warning(
                        "memory_save_failed", run_id=self.request.run_id, error=str(exc)
                    )

        return artifacts

    async def _save_mission_memory(
        self, final_state: dict[str, Any], artifacts: list[str], summary: str
    ) -> None:
        """Auto-ingests a "mission memory" (what was asked, what was delivered)
        as agent-scoped knowledge, even when the agent wrote no /memories/ file
        itself — every mission enriches the employee's vectorized experience."""
        if not self.request.agent_id or not summary:
            return

        wrote_memories = any(
            path.startswith(MEMORIES_DIR) for path in (final_state.get("files") or {})
        )
        if wrote_memories:
            return  # The agent's own notes are richer than an auto-summary.

        parts = [f"Mission: {self.request.task_title or 'Untitled'}", "", summary]
        if artifacts:
            parts += ["", "Deliverables: " + ", ".join(artifacts[:10])]
        if self.consultations:
            consulted = ", ".join(c["colleague"] for c in self.consultations)
            parts += [f"Consulted colleagues: {consulted}"]

        try:
            await self.phoenix.save_agent_memory(
                self.request.workspace_id,
                self.request.agent_id,
                f"Souvenir — {self.request.task_title or 'mission'}",
                "\n".join(parts),
            )
        except Exception as exc:  # noqa: BLE001 — memory is a bonus
            log.warning("mission_memory_failed", run_id=self.request.run_id, error=str(exc))

    # ---------- Main loop ----------

    async def run(self) -> dict[str, Any]:
        from deepagents import create_deep_agent
        from langchain_core.callbacks import UsageMetadataCallbackHandler

        agent = create_deep_agent(
            model=_build_model(),
            tools=self._build_tools(),
            system_prompt=_system_prompt(self.request),
        )

        usage_handler = UsageMetadataCallbackHandler()
        config = {
            "recursion_limit": RECURSION_LIMIT,
            "callbacks": [usage_handler],
        }

        instruction = (
            self.request.input.get("instruction")
            or self.request.task_description
            or self.request.task_title
            or "Complete the mission described in your instructions."
        )

        final_state: dict[str, Any] = {}
        try:
            async for chunk in agent.astream(
                {"messages": [{"role": "user", "content": instruction}]},
                stream_mode="values",
                config=config,
            ):
                if isinstance(chunk, dict):
                    final_state = chunk
                    todos = chunk.get("todos")
                    if isinstance(todos, list):
                        await self._push_todos(todos)
        finally:
            # Whatever happened, meter the tokens actually consumed.
            for model_name, meta in (usage_handler.usage_metadata or {}).items():
                self.ctx.usage.add(
                    _price_key(model_name),
                    int(meta.get("input_tokens", 0)),
                    int(meta.get("output_tokens", 0)),
                )

        artifacts = await self._collect_outputs(final_state.get("files") or {})
        summary = _final_message(final_state)
        await self._save_mission_memory(final_state, artifacts, summary)

        return {
            "engine": "deepagents",
            "steps": len(self.state.steps),
            "todos": self.last_todos,
            "tool_calls": [c.model_dump(mode="json") for c in self.state.tool_calls],
            "artifacts": artifacts,
            "consultations": self.consultations,
            "summary": summary,
        }


def _looks_french(text: str) -> bool:
    import re

    return bool(
        re.search(
            r"\b(je|tu|le|la|les|un|une|pour|avec|dans|que|qui|sur|est|été|être)\b|[éèêàçù]",
            text or "",
            re.IGNORECASE,
        )
    )


def _final_message(state: dict[str, Any]) -> str:
    messages = state.get("messages") or []
    for message in reversed(messages):
        content = getattr(message, "content", None)
        message_type = getattr(message, "type", None)
        if message_type == "ai" and content:
            if isinstance(content, list):
                content = " ".join(
                    block.get("text", "")
                    for block in content
                    if isinstance(block, dict) and block.get("type") == "text"
                )
            text = str(content).strip()
            if text:
                return text[:1500]
    return ""


def _describe_action(tool_name: str, tool_input: dict) -> str:
    detail = (
        tool_input.get("instruction")
        or tool_input.get("subject")
        or tool_input.get("message")
        or tool_input.get("prompt")
        or tool_input.get("question")
    )
    base = f"The agent wants to run {tool_name}"
    return f"{base}: {detail}" if isinstance(detail, str) and detail else base


async def execute(
    request: RunRequest,
    ctx: RunContext,
    state: RunState,
    phoenix: PhoenixClient,
    toolbox: McpToolbox,
    mcp_tools: list[dict[str, Any]],
    wait_for_decision: Callable[[str], Awaitable[Any]],
) -> dict[str, Any]:
    """Runs the mission with the deep-agent engine. Raises on fatal errors
    (the caller handles run failure); cancellation propagates as usual.

    No hard timeout here: runs legitimately pause for human approval, which
    can take hours — Phoenix's StaleRunWorker is the safety net for runs
    that are genuinely stuck.
    """
    engine = _Engine(request, ctx, state, phoenix, toolbox, mcp_tools, wait_for_decision)
    return await engine.run()
