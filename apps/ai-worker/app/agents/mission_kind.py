"""Mission kind classification — drives producer guardrails.

A "producer" mission must leave at least one Drive artifact. Clarification-only
closings are not success. Research missions answer in chat (web_search) and
do not require a file.
"""

from __future__ import annotations

import re
from typing import Any

from app.schemas import RunRequest

# Tools whose successful output counts as a real deliverable.
PRODUCER_TOOLS = frozenset(
    {
        "generate_website",
        "generate_webapp",
        "draft_document",
        "generate_report",
        "transform_image",
        "transcribe_audio",
        "analyze_file",
        "extract_document_text",
        "export_pdf",
    }
)

# Mission kinds that must produce a file (or fail / wait).
# research is intentionally excluded — chat answer + web_search is enough.
PRODUCER_KINDS = frozenset({"website", "webapp", "document", "image", "analysis"})

_RESEARCH_RE = re.compile(
    r"\b("
    r"recherche|rechercher?|research|look\s*up|fouille|enquête|enquete|"
    r"who\s+is|who's|find\s+(?:info|out|information)|"
    r"dis[- ]moi\s+ce\s+que\s+tu\s+trouves|"
    r"what\s+(?:do\s+you\s+know|can\s+you\s+find)|"
    r"infos?\s+sur|renseigne[- ]toi|"
    # Explicit web / score / news asks (incl. French typos like "gagner").
    r"cherche(?:\s+sur)?|search\s+(?:for|the\s+web)|"
    r"regarde(?:\s+sur)?(?:\s+l[e']?\s*)?(?:internet|web|en\s+ligne)|"
    r"check(?:\s+(?:online|the\s+web|on\s+the\s+internet))?|"
    r"sur\s+(?:internet|le\s+web|le\s+net)|"
    r"qui\s+a\s+gagn[ée]r?|who\s+won|"
    r"quel\s+(?:est|a\s+[ée]t[ée])\s+le\s+(?:score|r[ée]sultat)|"
    r"what(?:'s|\s+is|\s+was)\s+the\s+score|"
    r"r[ée]sultat\s+du\s+match|match\s+result|"
    r"actualit[ée]s?|latest\s+news"
    r")\b",
    re.IGNORECASE,
)

# Short confirmations / nudges that continue a pending lookup.
_RESEARCH_FOLLOWUP_RE = re.compile(
    r"^\s*("
    r"oui\b.*|"
    r"yes\b.*|"
    r"ok(?:ay)?\b.*|"
    r"vas[- ]y\b.*|"
    r"go\s+(?:ahead|for\s+it)\b.*|"
    r"s['’]il\s+te\s+pla[iî]t\b.*|"
    r"please\b.*|"
    r"regarde\b.*|"
    r"look(?:\s+it\s+up)?\b.*|"
    r"check(?:\s+it)?\b.*|"
    r"alors\s*\??|"
    r"et\s*alors\s*\??|"
    r"so\s*\??|"
    r"well\s*\??|"
    r"tu\s+as\s+trouv[ée]?\s*\??|"
    r"did\s+you\s+find\b.*"
    r")\s*$",
    re.IGNORECASE,
)

# Agent previously offered (or stalled on) a live web check.
_AGENT_LOOKUP_OFFER_RE = re.compile(
    r"("
    r"internet|sur\s+le\s+web|en\s+ligne|online|"
    r"jeter\s+un\s+[oœ]il|checker?|vérifier|verifier|"
    r"look\s+(?:it\s+up|online)|check\s+(?:online|the\s+web)|"
    r"pas\s+à\s+jour|not\s+up\s+to\s+date|"
    r"n['’]ai\s+pas\s+acc[eè]s|no\s+(?:direct\s+)?(?:internet|web)\s+access|"
    r"scores?\s+sportifs|sports?\s+scores?"
    r")",
    re.IGNORECASE,
)

_EXPLICIT_REPORT_RE = re.compile(
    r"\b("
    r"rédige|redige|écris|ecris|write|draft|crée\s+(?:un|le)\s+(?:rapport|doc)|"
    r"create\s+(?:a\s+)?(?:report|doc)|génère\s+(?:un\s+)?rapport|"
    r"generate\s+(?:a\s+)?report|rapport\s+(?:écrit|markdown|pdf)|"
    r"written\s+report"
    r")\b",
    re.IGNORECASE,
)


def looks_like_research(text: str) -> bool:
    """True when the ask is primarily an info lookup on the public web."""
    if not text or not _RESEARCH_RE.search(text):
        return False
    # Explicit written report / deck still counts as research intent for kind,
    # but callers may still route to task+document.
    return True


def looks_like_research_followup(text: str) -> bool:
    """True for short confirmations / nudges after a pending web lookup."""
    if not text:
        return False
    return bool(_RESEARCH_FOLLOWUP_RE.match(text.strip()))


def _teammate_bodies(conversation: list[dict[str, Any]] | None) -> list[str]:
    bodies: list[str] = []
    for entry in conversation or []:
        if not isinstance(entry, dict):
            continue
        author = (entry.get("author") or "").lower()
        if author in ("you", "agent"):
            continue
        body = (entry.get("body") or "").strip()
        if body:
            bodies.append(body)
    return bodies


def _agent_bodies(conversation: list[dict[str, Any]] | None) -> list[str]:
    bodies: list[str] = []
    for entry in conversation or []:
        if not isinstance(entry, dict):
            continue
        author = (entry.get("author") or "").lower()
        if author not in ("you", "agent"):
            continue
        body = (entry.get("body") or "").strip()
        if body:
            bodies.append(body)
    return bodies


def prior_research_query(conversation: list[dict[str, Any]] | None) -> str:
    """Most recent earlier teammate message that looks like a web research ask."""
    bodies = _teammate_bodies(conversation)
    if len(bodies) < 2:
        return ""
    # Skip the latest teammate message; scan older ones newest-first.
    for body in reversed(bodies[:-1]):
        if looks_like_research(body):
            return body
    return ""


def agent_offered_web_lookup(conversation: list[dict[str, Any]] | None) -> bool:
    """True when a recent agent line offered (or apologized about) a web check."""
    for body in reversed(_agent_bodies(conversation)[-3:]):
        if _AGENT_LOOKUP_OFFER_RE.search(body):
            return True
    return False


def resolve_web_research(
    latest: str,
    conversation: list[dict[str, Any]] | None = None,
    *,
    decision_needs_web: bool = False,
    decision_query: str = "",
) -> tuple[bool, str]:
    """Gate + query for same-turn web search.

    Hybrid best practice: structured LLM gate first, then heuristic / multi-turn
    fallbacks so short follow-ups like « oui regarde » still search.
    """
    latest = (latest or "").strip()
    query = (decision_query or "").strip()

    if decision_needs_web:
        return True, query or latest or prior_research_query(conversation)

    if looks_like_research(latest):
        return True, latest

    if looks_like_research_followup(latest):
        prior = prior_research_query(conversation)
        if prior:
            return True, prior
        if agent_offered_web_lookup(conversation):
            # Affirmation after the agent offered to look online — reuse prior ask
            # or the confirmation itself if that is all we have.
            bodies = _teammate_bodies(conversation)
            fallback = ""
            if len(bodies) >= 2:
                fallback = bodies[-2]
            return True, fallback or prior or latest

    return False, ""


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

    # Explicit delivery from the site-format choice gate.
    delivery = (request.input or {}).get("delivery") or (request.input or {}).get(
        "site_delivery"
    )
    if isinstance(delivery, str):
        d = delivery.strip().lower()
        if d == "webapp":
            return "webapp"
        if d == "html":
            return "website"

    if re.search(
        r"\b("
        r"next\.?js|react|typescript|webapp|web app|full.?stack|application|"
        r"crm|erp|site (?:internet |web )?complet|complete (?:website|site)|deploy|"
        r"ecommerce|e-?commerce|boutique|shop|store|catalogue|catalog|"
        r"site entier|entire (?:website|site)"
        r")\b",
        text,
    ):
        return "webapp"

    if re.search(r"\b(site|website|landing|page web|html|vitrine)\b", text):
        return "website"

    # Research before image: "recherche X + logo" must not become transform_image.
    if looks_like_research(text) and not _EXPLICIT_REPORT_RE.search(text):
        return "research"
    if looks_like_research(text) and _EXPLICIT_REPORT_RE.search(text):
        return "document"

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
        "webapp": "generate_webapp",
        "document": "draft_document",
        "image": "transform_image",
        "analysis": "analyze_file",
        # research: web_search is required by prompt, not forced as a producer file
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


def web_search_succeeded(tool_calls: list[Any]) -> bool:
    for call in tool_calls:
        tool = getattr(call, "tool", None) or (call.get("tool") if isinstance(call, dict) else None)
        output = getattr(call, "output", None) or (call.get("output") if isinstance(call, dict) else None)
        if tool != "web_search":
            continue
        if isinstance(output, dict) and not output.get("error") and (output.get("results") is not None):
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
