"""Agent-to-agent consultation.

Gives the running deep agent a `consult_colleague` tool: it can ask another
AI employee of the workspace for input when that colleague's specialty would
genuinely enrich the deliverable. The exchange is posted in the task thread
as two comments — the question signed by the working agent, the answer signed
by the colleague — so the user literally sees their AI employees confer.
"""

from typing import Any

import structlog

from app import llm
from app.schemas import Colleague, RunRequest
from app.tools.registry import RunContext

log = structlog.get_logger()

# A run may consult at most this many times — consultation is a scalpel, not
# a group chat.
MAX_CONSULTS_PER_RUN = 3

_COLLEAGUE_SYSTEM = """You are {name}, an AI employee ({role}, {department} department).
Your skills: {skills}.

A colleague, {asker}, is working on the mission "{task}" and asks for your
professional input. Answer as yourself, in first person, in the SAME LANGUAGE
as the question: concrete, specific, actionable — the kind of answer a sharp
specialist gives a teammate. 2-6 sentences, no markdown headers, no fluff.

{knowledge_block}"""


def find_colleague(colleagues: list[Colleague], name_or_id: str) -> Colleague | None:
    needle = (name_or_id or "").strip().lower()
    if not needle:
        return None
    for colleague in colleagues:
        if colleague.id == name_or_id or (colleague.name or "").lower() == needle:
            return colleague
    # Loose match: first colleague whose name contains the needle.
    for colleague in colleagues:
        if needle in (colleague.name or "").lower():
            return colleague
    return None


async def _colleague_knowledge(
    ctx: RunContext, colleague: Colleague, question: str
) -> str:
    """Retrieves the colleague's own vectorized knowledge relevant to the
    question, so its answer reflects what it actually learned on the job."""
    if not llm.is_configured() or ctx.phoenix is None:
        return ""
    try:
        [embedding] = await llm.embed([question], usage=ctx.usage)
        results = await ctx.phoenix.search_knowledge(
            ctx.workspace_id,
            embedding,
            question,
            limit=4,
            project_id=ctx.project_id,
            agent_id=colleague.id,
        )
    except Exception as exc:  # noqa: BLE001 — knowledge is a bonus, not a blocker
        log.warning("colleague_knowledge_failed", colleague=colleague.id, error=str(exc))
        return ""

    chunks = [r.get("content", "") for r in results if r.get("content")]
    if not chunks:
        return ""
    joined = "\n---\n".join(chunks[:4])
    return f"Relevant notes from your own experience:\n{joined}"


async def consult(
    request: RunRequest,
    ctx: RunContext,
    colleague_name: str,
    question: str,
    consults_done: list[dict[str, Any]],
) -> str:
    """Runs one consultation round and posts both sides in the task thread."""
    if len(consults_done) >= MAX_CONSULTS_PER_RUN:
        return (
            "You already consulted colleagues the maximum number of times for "
            "this mission — proceed with what you have."
        )

    colleague = find_colleague(request.colleagues, colleague_name)
    if colleague is None:
        available = ", ".join(c.name for c in request.colleagues) or "(none)"
        return f"No colleague named '{colleague_name}'. Available colleagues: {available}."

    asker_name = request.agent.get("display_name") or "an AI agent"

    # The question, visible in the thread, signed by the working agent.
    if ctx.phoenix is not None:
        await ctx.phoenix.post_task_comment(
            request.workspace_id,
            request.task_id,
            f"@{colleague.name} — {question}",
            agent_id=request.agent_id,
        )

    knowledge_block = await _colleague_knowledge(ctx, colleague, question)

    system = _COLLEAGUE_SYSTEM.format(
        name=colleague.name,
        role=colleague.role_title or "Generalist",
        department=colleague.department or "—",
        skills=", ".join(colleague.skills) or "generalist",
        asker=asker_name,
        task=request.task_title or "Untitled",
        knowledge_block=knowledge_block,
    )

    try:
        answer = await llm.chat(
            system=system,
            user=question,
            usage=ctx.usage,
            max_tokens=700,
            quality="smart",
        )
    except Exception as exc:  # noqa: BLE001
        log.warning("colleague_answer_failed", colleague=colleague.id, error=str(exc))
        return f"{colleague.name} is unavailable right now — proceed with your own judgment."

    answer = answer.strip()
    if not answer:
        return f"{colleague.name} had nothing to add — proceed."

    # The answer, visible in the thread, signed by the colleague.
    if ctx.phoenix is not None:
        await ctx.phoenix.post_task_comment(
            request.workspace_id,
            request.task_id,
            answer,
            agent_id=colleague.id,
        )

    consults_done.append({"colleague": colleague.name, "question": question})
    log.info("colleague_consulted", colleague=colleague.id, run_id=request.run_id)
    return f"{colleague.name} answered:\n{answer}"
