"""Agent run orchestration.

With an LLM key configured, missions run on the deep-agent engine
(`app.agents.deep_runner`, built on LangChain's deepagents harness):
planning todos, virtual filesystem, sub-agents, colleague consultation.
Offline (dev/tests) the legacy deterministic plan-then-execute loop keeps
the full run/approve/resume lifecycle exercisable.

HIGH/CRITICAL-risk tools pause the run in `waiting_for_approval` until the
resume endpoint is called with a human decision. Run state is kept
in-memory per worker instance (production: externalize to Redis/DB
checkpointer via LangGraph's persistence layer).
"""

import asyncio
import json
import re

import structlog

from app.agents import deep_runner
from app.agents.acknowledge import post_acknowledgement
from app.agents.planner import plan_steps
from app.clients.phoenix import PhoenixClient
from app.mcp.client import TOOL_PREFIX, McpToolbox
from app.policies.approval import requires_approval, risk_for_tool
from app.schemas import ResumeRequest, RunRequest, RunState, RunStatus, ToolCall
from app.tools.registry import RunContext, get_tool

log = structlog.get_logger()

_RUNS: dict[str, RunState] = {}
_RESUME_EVENTS: dict[str, asyncio.Event] = {}
_RESUME_DECISIONS: dict[str, ResumeRequest] = {}

# asyncio task handles of in-flight runs, so a human can abort any mission
# at any moment (shared by the HTTP endpoint and the SQS consumer).
_RUN_TASKS: dict[str, asyncio.Task] = {}


def get_run(run_id: str) -> RunState | None:
    return _RUNS.get(run_id)


def register_run_task(run_id: str, task: asyncio.Task) -> None:
    """Tracks the run's asyncio task (also keeps a strong reference to it)."""
    _RUN_TASKS[run_id] = task
    task.add_done_callback(lambda _t: _RUN_TASKS.pop(run_id, None))


def cancel_run_task(run_id: str) -> bool:
    """Cancels an in-flight run, including one paused for approval."""
    task = _RUN_TASKS.get(run_id)
    if task is None or task.done():
        return False
    task.cancel()
    return True


async def execute_run(request: RunRequest, phoenix: PhoenixClient | None = None) -> RunState:
    phoenix = phoenix or PhoenixClient()
    state = RunState(run_id=request.run_id, status=RunStatus.RUNNING)
    _RUNS[request.run_id] = state

    ctx = RunContext(
        run_id=request.run_id,
        workspace_id=request.workspace_id,
        task_id=request.task_id,
        task_title=request.task_title,
        task_description=request.task_description,
        project_id=request.project_id,
        agent_id=request.agent_id,
        phoenix=phoenix,
        attached_files=[f.model_dump() for f in request.attached_files],
    )

    await phoenix.update_run_status(request.run_id, RunStatus.RUNNING.value)
    log.info("run_started", run_id=request.run_id, task_id=request.task_id)

    # Granted MCP servers: discover their tools so the planner can decide,
    # on its own, whether any external tool helps with this task.
    toolbox = McpToolbox(request.mcp_servers)
    mcp_tools = await toolbox.discover() if request.mcp_servers else []

    # Conversational acknowledgement in the task thread. Skipped for tasks
    # launched from the chat dock — that thread already got its "on it" reply,
    # and we don't want a second conversation living in the task menu.
    if not request.input.get("chat_task"):
        await post_acknowledgement(request, phoenix, ctx.usage, mcp_tools)

    # Deep-agent engine (LangChain deepagents): the default whenever an LLM
    # key is configured. The legacy loop below remains the offline path.
    if deep_runner.is_available():
        return await _execute_deep(request, state, ctx, phoenix, toolbox, mcp_tools)

    try:
        for step in await plan_steps(request, ctx.usage, mcp_tools):
            tool_name: str = step["tool"]
            tool_input: dict = step["input"]
            risk = risk_for_tool(tool_name)
            call = ToolCall(tool=tool_name, input=tool_input, risk=risk)

            if requires_approval(tool_name):
                state.status = RunStatus.WAITING_FOR_APPROVAL
                state.pending_tool = call
                created = await phoenix.request_approval(
                    request.run_id,
                    tool_name,
                    tool_input,
                    risk.value,
                    proposed_action=_describe_action(tool_name, tool_input),
                )
                if created is None:
                    # Nothing exists for a human to approve — waiting would
                    # strand the run forever, so fail loudly instead.
                    raise RuntimeError(
                        f"could not create the approval request for {tool_name}"
                    )
                await phoenix.update_run_status(request.run_id, state.status.value)
                log.info("run_waiting_approval", run_id=request.run_id, tool=tool_name)

                decision = await _wait_for_decision(request.run_id)
                state.pending_tool = None

                if decision.decision == "rejected":
                    call.approved = False
                    state.tool_calls.append(call)
                    log.info("tool_rejected", run_id=request.run_id, tool=tool_name)
                    continue

                call.approved = True
                if decision.decision == "edited" and decision.payload:
                    call.input = decision.payload
                state.status = RunStatus.RUNNING
                await phoenix.update_run_status(request.run_id, state.status.value)

            if tool_name.startswith(TOOL_PREFIX):
                call.output = await toolbox.call(tool_name, call.input)
            else:
                fn = get_tool(tool_name)
                if fn is None:
                    raise ValueError(f"unknown tool: {tool_name}")
                enriched_input = {**call.input, "_attached_files": [f.model_dump() for f in request.attached_files]}
                call.output = await fn(enriched_input, ctx)

            state.tool_calls.append(call)
            state.steps.append({"tool": tool_name, "ok": True})
            log.info("tool_executed", run_id=request.run_id, tool=tool_name)

        artifacts = await _save_artifacts(request, state, phoenix)

        # No deliverable + tool errors = the mission actually failed. Tell the
        # user what blocked the agent (in the task thread, so they can reply
        # or attach a better file) and mark the run failed so the UI offers a
        # retry instead of pretending the work is done.
        executed = [c for c in state.tool_calls if c.approved is not False]
        errors = [
            c for c in executed if isinstance(c.output, dict) and c.output.get("error")
        ]
        if errors and not artifacts:
            summary = "; ".join(str(c.output.get("error"))[:200] for c in errors[:3])
            await _post_failure_comment(request, phoenix, ctx.usage, errors)
            state.status = RunStatus.FAILED
            state.error = summary
            await phoenix.fail_run(request.run_id, summary)
            log.info("run_failed_no_deliverable", run_id=request.run_id, errors=len(errors))
            return state

        state.status = RunStatus.COMPLETED
        state.output = {
            "steps": len(state.steps),
            "tool_calls": [c.model_dump(mode="json") for c in state.tool_calls],
            "artifacts": artifacts,
        }
        await phoenix.complete_run(
            request.run_id,
            state.output,
            token_usage=ctx.usage.as_dict(),
            cost_cents=ctx.usage.cost_cents,
        )
        log.info(
            "run_completed",
            run_id=request.run_id,
            tokens=ctx.usage.as_dict()["total_tokens"],
            cost_cents=ctx.usage.cost_cents,
        )

    except asyncio.CancelledError:
        state.status = RunStatus.CANCELED
        await phoenix.update_run_status(request.run_id, state.status.value)
        raise
    except Exception as exc:  # noqa: BLE001 — report any failure to the API
        state.status = RunStatus.FAILED
        state.error = str(exc)
        await phoenix.fail_run(request.run_id, state.error)
        log.error("run_failed", run_id=request.run_id, error=state.error)

    return state


async def _execute_deep(
    request: RunRequest,
    state: RunState,
    ctx: RunContext,
    phoenix: PhoenixClient,
    toolbox: McpToolbox,
    mcp_tools: list,
) -> RunState:
    """Runs the mission on the deepagents engine and reports the outcome."""
    from app.agents.mission_kind import (
        PRODUCER_KINDS,
        detect_mission_kind,
        language_for_request,
        producer_tool_succeeded,
        required_tool_for_kind,
    )

    try:
        output = await deep_runner.execute(
            request, ctx, state, phoenix, toolbox, mcp_tools, _wait_for_decision
        )

        # Legacy artifact extraction still applies: draft_document /
        # generate_report / transform_image tool outputs become Drive files.
        extra_artifacts = await _save_artifacts(request, state, phoenix)
        artifacts = list(dict.fromkeys([*output.get("artifacts", []), *extra_artifacts]))

        kind = detect_mission_kind(request)
        required = required_tool_for_kind(kind)

        # Website (and other producer) missions: if the deep agent never called
        # the required tool, force it once with the full brief — don't accept
        # a clarification-only close as success.
        if (
            required
            and not any(c.tool == required and not (
                isinstance(c.output, dict) and c.output.get("error")
            ) for c in state.tool_calls)
        ):
            forced = await _force_producer_tool(request, ctx, state, required)
            if forced:
                extra_artifacts = await _save_artifacts(request, state, phoenix)
                artifacts = list(
                    dict.fromkeys([*artifacts, *extra_artifacts, *forced])
                )

        output["artifacts"] = artifacts
        output["mission_kind"] = kind

        executed = [c for c in state.tool_calls if c.approved is not False]
        errors = [
            c for c in executed if isinstance(c.output, dict) and c.output.get("error")
        ]

        has_deliverable = bool(artifacts) or producer_tool_succeeded(state.tool_calls)
        producer = kind in PRODUCER_KINDS

        # Analysis without a source file cannot invent a deliverable — pause and
        # ask the teammate instead of pretending the mission succeeded.
        if (
            kind == "analysis"
            and not has_deliverable
            and not request.attached_files
            and not (request.input or {}).get("drive_item_ids")
        ):
            await _pause_for_user_input(request, phoenix, state, kind=kind)
            return state

        # Agent refused (ethics / content policy) without producing anything —
        # treat as failure so the task leaves in_progress.
        refusal_text = (output.get("summary") or "").strip()
        if not has_deliverable and not state.tool_calls and _is_refusal(refusal_text):
            error_msg = "content_policy: " + refusal_text[:200]
            await _post_refusal_message(request, phoenix, refusal_text)
            state.status = RunStatus.FAILED
            state.error = error_msg
            await phoenix.fail_run(request.run_id, error_msg)
            log.info(
                "deep_run_failed_refusal",
                run_id=request.run_id,
                kind=kind,
            )
            return state

        if (errors and not has_deliverable) or (producer and not has_deliverable):
            lang = language_for_request(request)
            if errors:
                summary = "; ".join(
                    str(c.output.get("error"))[:200] for c in errors[:3]
                )
            else:
                summary = (
                    "Aucun livrable produit — la mission a été clôturée sans fichier."
                    if lang == "fr"
                    else "No deliverable produced — the mission closed without a file."
                )
            await _post_failure_comment(request, phoenix, ctx.usage, errors or [])
            state.status = RunStatus.FAILED
            state.error = summary
            await phoenix.fail_run(request.run_id, summary)
            log.info(
                "deep_run_failed_no_deliverable",
                run_id=request.run_id,
                kind=kind,
                artifacts=len(artifacts),
            )
            return state

        state.status = RunStatus.COMPLETED
        state.output = output
        await phoenix.complete_run(
            request.run_id,
            output,
            token_usage=ctx.usage.as_dict(),
            cost_cents=ctx.usage.cost_cents,
        )
        log.info(
            "deep_run_completed",
            run_id=request.run_id,
            artifacts=len(artifacts),
            consultations=len(output.get("consultations", [])),
            tokens=ctx.usage.as_dict()["total_tokens"],
            cost_cents=ctx.usage.cost_cents,
        )
    except asyncio.CancelledError:
        state.status = RunStatus.CANCELED
        await phoenix.update_run_status(request.run_id, state.status.value)
        raise
    except Exception as exc:  # noqa: BLE001 — report any failure to the API
        state.status = RunStatus.FAILED
        state.error = str(exc)
        await phoenix.fail_run(request.run_id, state.error)
        log.error("deep_run_failed", run_id=request.run_id, error=state.error)

    return state


_REFUSAL_PATTERNS = [
    r"je ne (peux|puis) pas (aider|assister|effectuer|réaliser|faire|compléter|terminer)",
    r"i (can't|cannot|am unable to|won't) (help|assist|complete|do|finish|perform)",
    r"i understand.{0,40}(but|however).{0,20}(cannot|can't|won't)",
    r"content policy",
    r"politique de contenu",
    r"safety (system|policy|guidelines)",
    r"(symboles?|éléments?) .*(historique|nuisible|offens)",
    r"\b(ethically|éthique|éthique?ment)\b",
    r"\b(harmful|nuisible|inappropri[ée]?)\b",
    r"historically harmful",
    r"régimes? historiques?",
]


def _is_refusal(summary: str) -> bool:
    """True when the agent's closing message is a content/ethics refusal."""
    if not summary or not summary.strip():
        return False
    text = summary.strip().lower()
    return any(re.search(pattern, text, re.IGNORECASE) for pattern in _REFUSAL_PATTERNS)


async def _post_refusal_message(
    request: RunRequest, phoenix: PhoenixClient, text: str
) -> None:
    """Posts the agent's refusal to the task thread (chat DM is handled by
    Phoenix handle_failure using the content_policy error body)."""
    body = (text or "").strip()
    if not body:
        return
    # Chat-born missions: Phoenix maybe_report_failure_to_chat posts the
    # content_policy body — avoid a duplicate bubble here.
    if request.input.get("chat_task"):
        return
    try:
        await phoenix.post_task_comment(
            request.workspace_id,
            request.task_id,
            body,
            agent_id=request.agent_id,
        )
    except Exception as exc:  # noqa: BLE001 — messaging is best-effort
        log.warning("refusal_message_post_failed", run_id=request.run_id, error=str(exc))


async def _pause_for_user_input(
    request: RunRequest,
    phoenix: PhoenixClient,
    state: RunState,
    *,
    kind: str,
) -> None:
    """Marks the run waiting and posts the clarifying question (never completes)."""
    from app.agents.mission_kind import language_for_request

    lang = language_for_request(request)
    question = (
        "Pour analyser correctement, j'ai besoin du fichier source — "
        "dépose-le ici ou dans la tâche, puis relance-moi."
        if lang == "fr"
        else (
            "To analyze this properly I need the source file — "
            "drop it here or on the task, then send me again."
        )
    )
    state.status = RunStatus.WAITING_FOR_USER_INPUT
    state.error = None
    await phoenix.update_run_status(
        request.run_id, RunStatus.WAITING_FOR_USER_INPUT.value
    )
    await phoenix.post_task_comment(
        request.workspace_id,
        request.task_id,
        question,
        agent_id=request.agent_id,
    )
    if (request.input or {}).get("chat_task") and request.agent_id:
        try:
            await phoenix.post_agent_chat_message(
                request.workspace_id, request.agent_id, question
            )
        except Exception as exc:  # noqa: BLE001
            log.warning("user_input_chat_post_failed", error=str(exc))
    log.info("deep_run_waiting_for_user_input", run_id=request.run_id, kind=kind)


async def _force_producer_tool(
    request: RunRequest, ctx: RunContext, state: RunState, tool_name: str
) -> list[str]:
    """Runs the required producer tool once when the deep agent skipped it."""
    from app.policies.approval import risk_for_tool
    from app.tools.registry import get_tool

    fn = get_tool(tool_name)
    if fn is None:
        return []

    brief = (
        request.input.get("instruction")
        or request.task_description
        or request.task_title
        or ""
    )
    tool_input: dict = {"brief": brief} if tool_name == "generate_website" else {}
    if tool_name == "draft_document":
        tool_input = {"title": request.task_title or "Document", "brief": brief}
    if tool_name in ("analyze_file", "transform_image", "transcribe_audio", "extract_document_text"):
        files = request.attached_files
        if not files:
            return []
        # Prefer user input over agent output, then the most recent match.
        inputs = [f for f in files if f.source != "agent_output"]
        chosen = (inputs or files)[-1]
        file_url = chosen.download_url or ""
        if tool_name == "analyze_file":
            tool_input = {"file_url": file_url, "question": brief}
        elif tool_name == "transform_image":
            tool_input = {
                "file_url": file_url,
                "instruction": brief,
                "original_filename": chosen.name or "",
            }
        else:
            tool_input = {
                "file_url": file_url,
                "original_filename": chosen.name or "",
            }

    call = ToolCall(tool=tool_name, input=tool_input, risk=risk_for_tool(tool_name))
    try:
        enriched = {**tool_input, "_attached_files": [f.model_dump() for f in request.attached_files]}
        call.output = await fn(enriched, ctx)
        call.approved = None
        state.tool_calls.append(call)
        state.steps.append({"tool": tool_name, "ok": True, "forced": True})
        log.info("producer_tool_forced", run_id=request.run_id, tool=tool_name)
        if isinstance(call.output, dict) and call.output.get("filename"):
            return [call.output["filename"]]
    except Exception as exc:  # noqa: BLE001
        call.output = {"error": str(exc)}
        state.tool_calls.append(call)
        log.warning("producer_tool_force_failed", tool=tool_name, error=str(exc))
    return []


async def _post_failure_comment(request: RunRequest, phoenix, usage, errors: list) -> None:
    """Explains the failure in the task thread, in the agent's voice, and asks
    the user for what would unblock the mission. Never raises."""
    from app import llm
    from app.agents.mission_kind import language_for_request

    details = "\n".join(
        f"- {c.tool}: {c.output.get('error')}"
        for c in (errors or [])[:3]
        if isinstance(getattr(c, "output", None), dict)
    )
    lang = language_for_request(request)
    if errors and isinstance(getattr(errors[0], "output", None), dict):
        first_error = errors[0].output.get("error") or "unknown error"
    else:
        first_error = (
            "aucun livrable produit"
            if lang == "fr"
            else "no deliverable was produced"
        )

    text = (
        f"Je n'ai pas pu terminer cette mission : {first_error}. "
        "Réponds ici avec plus de détails ou un autre fichier, puis relance-moi."
        if lang == "fr"
        else (
            f"I couldn't finish this mission: {first_error}. "
            "Reply here with more details or attach another file, then relaunch me."
        )
    )

    if llm.is_configured():
        try:
            text = await llm.chat(
                system=(
                    "You are an AI agent teammate. Your attempt at the mission just failed. "
                    "Write a short comment (2-3 sentences, first person, no markdown, in the "
                    "same language as the task) explaining simply and non-technically what "
                    "blocked you, and asking the user for exactly what you need to continue "
                    "(another file format, a clarification, a new attachment…). Be warm."
                ),
                user=(
                    f"Task: {request.task_title}\n"
                    f"Description: {request.task_description}\n"
                    f"Tool failures:\n{details or first_error}"
                ),
                usage=usage,
                max_tokens=220,
            )
        except Exception as exc:  # noqa: BLE001 — the template above is the fallback
            log.warning("failure_comment_llm_failed", error=str(exc))

    try:
        # Prefer the chat thread when the mission was launched from DM.
        if request.input.get("chat_task") and request.agent_id:
            await phoenix.post_agent_chat_message(
                request.workspace_id, request.agent_id, text.strip()
            )
        else:
            await phoenix.post_task_comment(
                request.workspace_id, request.task_id, text.strip(), agent_id=request.agent_id
            )
    except Exception as exc:  # noqa: BLE001
        log.warning("failure_comment_post_failed", run_id=request.run_id, error=str(exc))


def _describe_action(tool_name: str, tool_input: dict) -> str:
    """Human-readable summary of the gated action, shown in the approval UI."""
    detail = (
        tool_input.get("instruction")
        or tool_input.get("subject")
        or tool_input.get("message")
        or tool_input.get("prompt")
    )
    base = f"The agent wants to run {tool_name}"
    return f"{base}: {detail}" if isinstance(detail, str) and detail else base


def _safe_filename(name: str) -> str:
    slug = re.sub(r"[^\w\- ]+", "", name, flags=re.UNICODE).strip().replace(" ", "-")
    return (slug or "output")[:80]


async def _save_artifacts(request: RunRequest, state: RunState, phoenix: PhoenixClient) -> list[str]:
    """Uploads the documents produced during the run as Drive files linked to
    the task, so users can open the agent's output. Never fails the run."""
    saver = getattr(phoenix, "save_task_output", None)
    if saver is None:
        return []

    artifacts: list[str] = []
    for call in state.tool_calls:
        output = call.output if isinstance(call.output, dict) else None
        if output is None:
            continue

        try:
            if call.tool == "draft_document" and output.get("content"):
                filename = f"{_safe_filename(output.get('title') or request.task_title or 'document')}.md"
                saved = await saver(
                    request.workspace_id,
                    request.task_id,
                    filename,
                    output["content"],
                    mime_type="text/markdown",
                )
                if saved:
                    artifacts.append(filename)
            elif call.tool == "generate_report" and output.get("report"):
                filename = f"{_safe_filename(request.task_title or 'report')}-report.json"
                saved = await saver(
                    request.workspace_id,
                    request.task_id,
                    filename,
                    json.dumps(output["report"], indent=2, ensure_ascii=False),
                    mime_type="application/json",
                )
                if saved:
                    artifacts.append(filename)
            elif call.tool == "transform_image" and output.get("filename"):
                artifacts.append(output["filename"])
            elif call.tool == "generate_website" and output.get("filename"):
                # Already saved by the tool itself — just record the artifact name.
                artifacts.append(output["filename"])
            elif call.tool == "transcribe_audio" and output.get("transcript"):
                clean = _safe_filename(request.task_title or "transcript")
                artifacts.append(f"{clean}-transcript.txt")
            elif call.tool == "analyze_file" and output.get("analysis"):
                filename = f"{_safe_filename(request.task_title or 'analysis')}.md"
                saved = await saver(
                    request.workspace_id,
                    request.task_id,
                    filename,
                    f"# Analysis\n\n{output['analysis']}",
                    mime_type="text/markdown",
                )
                if saved:
                    artifacts.append(filename)
        except Exception as exc:  # noqa: BLE001 — artifacts are best-effort
            log.warning("artifact_save_failed", run_id=request.run_id, tool=call.tool, error=str(exc))

    return artifacts


async def _wait_for_decision(run_id: str) -> ResumeRequest:
    event = asyncio.Event()
    _RESUME_EVENTS[run_id] = event
    await event.wait()
    _RESUME_EVENTS.pop(run_id, None)
    return _RESUME_DECISIONS.pop(run_id)


def resume_run(request: ResumeRequest) -> bool:
    event = _RESUME_EVENTS.get(request.run_id)
    if event is None:
        return False
    _RESUME_DECISIONS[request.run_id] = request
    event.set()
    return True
