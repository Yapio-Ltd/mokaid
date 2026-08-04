"""Site delivery choice: HTML vitrine vs full React/Next/TypeScript codebase.

Pauses the run for a human decision (approval gate) so the user feels they
have a professional choice before generation starts.
"""

from __future__ import annotations

import re
from typing import Any

from app.schemas import RunRequest
from app.tools.registry import RunContext, tool

_SITE_SIGNAL_RE = re.compile(
    r"\b("
    r"site|website|web\s?app|landing|page\s?web|vitrine|boutique|ecommerce|"
    r"e-?commerce|shop|store|catalogue|catalog|next\.?js|react|typescript|"
    r"codebase|github|crm|erp"
    r")\b",
    re.IGNORECASE,
)

_HTML_EXPLICIT_RE = re.compile(
    r"\b(html|vitrine|landing\s?page|one[- ]?pager|page\s+unique|statique)\b",
    re.IGNORECASE,
)

_WEBAPP_EXPLICIT_RE = re.compile(
    r"\b("
    r"react|next\.?js|typescript|codebase|github|full[- ]?stack|"
    r"application|webapp|web\s?app|crm|erp|deploy"
    r")\b",
    re.IGNORECASE,
)

_WEBAPP_RECOMMEND_RE = re.compile(
    r"\b("
    r"ecommerce|e-?commerce|boutique|shop|store|catalogue|catalog|"
    r"multi[- ]?page|entier|complet|full|dashboard|admin|panier|checkout|"
    r"produits?|collection"
    r")\b",
    re.IGNORECASE,
)


def is_site_request(text: str) -> bool:
    return bool(text and _SITE_SIGNAL_RE.search(text))


def explicit_delivery(text: str) -> str | None:
    """Return 'html' / 'webapp' when the prompt already decides, else None."""
    if not text:
        return None
    # Explicit stack wins over "html" mention inside a Next ask.
    if _WEBAPP_EXPLICIT_RE.search(text) and not re.search(
        r"\b(juste|only|simple)\s+(html|vitrine)\b", text, re.IGNORECASE
    ):
        # "landing html" without react → html; "react landing" → webapp
        if re.search(r"\b(react|next\.?js|typescript|codebase|github|crm|erp)\b", text, re.I):
            return "webapp"
        if re.search(r"\b(application|webapp|web\s?app|full[- ]?stack|deploy)\b", text, re.I):
            return "webapp"
    if re.search(r"\b(vitrine\s+html|html\s+simple|juste\s+(un\s+)?html|only\s+html)\b", text, re.I):
        return "html"
    if _HTML_EXPLICIT_RE.search(text) and not _WEBAPP_RECOMMEND_RE.search(text):
        if not re.search(r"\b(ecommerce|boutique|shop|entier|complet)\b", text, re.I):
            return "html"
    return None


def recommend_delivery(text: str) -> str:
    """Agent recommendation used to highlight the preferred card."""
    decided = explicit_delivery(text)
    if decided:
        return decided
    if text and _WEBAPP_RECOMMEND_RE.search(text):
        return "webapp"
    if text and re.search(r"\b(landing|vitrine|one[- ]?pager)\b", text, re.I):
        return "html"
    # Ambiguous "site" alone → prefer codebase (higher perceived level).
    return "webapp"


def delivery_from_request(request: RunRequest) -> str | None:
    inp = request.input or {}
    for key in ("delivery", "site_delivery", "site_format"):
        val = inp.get(key)
        if isinstance(val, str) and val.strip().lower() in ("html", "webapp"):
            return val.strip().lower()
    text = " ".join(
        filter(
            None,
            [
                request.task_title or "",
                request.task_description or "",
                str(inp.get("instruction") or ""),
            ],
        )
    )
    return explicit_delivery(text)


def needs_delivery_choice(request: RunRequest) -> bool:
    """True when we must pause for HTML vs codebase before generating."""
    if delivery_from_request(request) is not None:
        return False
    text = " ".join(
        filter(
            None,
            [
                request.task_title or "",
                request.task_description or "",
                str((request.input or {}).get("instruction") or ""),
            ],
        )
    )
    return is_site_request(text)


def choice_payload(brief: str, *, lang: str = "en") -> dict[str, Any]:
    recommended = recommend_delivery(brief)
    if lang == "fr":
        options = [
            {
                "id": "html",
                "label": "Simple vitrine HTML",
                "blurb": "Une page soignée, prévisualisable tout de suite — idéal pour une landing ou une vitrine.",
            },
            {
                "id": "webapp",
                "label": "Codebase complet (React + Next.js + TypeScript)",
                "blurb": "Projet multi-fichiers prêt pour GitHub, npm run dev et déploiement Vercel/Render.",
            },
        ]
        reason = (
            "Boutique / multi-pages → codebase recommandé."
            if recommended == "webapp"
            else "Landing / vitrine → HTML recommandé."
        )
    else:
        options = [
            {
                "id": "html",
                "label": "Simple HTML showcase",
                "blurb": "A polished single page you can preview instantly — ideal for a landing or brochure site.",
            },
            {
                "id": "webapp",
                "label": "Full codebase (React + Next.js + TypeScript)",
                "blurb": "Multi-file project ready for GitHub, npm run dev, and Vercel/Render deploy.",
            },
        ]
        reason = (
            "Shop / multi-page → codebase recommended."
            if recommended == "webapp"
            else "Landing / brochure → HTML recommended."
        )
    return {
        "kind": "site_delivery_choice",
        "recommended": recommended,
        "options": options,
        "reason": reason,
        "brief": (brief or "")[:800],
    }


@tool("choose_site_delivery")
async def choose_site_delivery(params: dict[str, Any], ctx: RunContext) -> Any:
    """Ask the human how to deliver the site: HTML showcase vs full Next.js codebase.

    This tool is always gated — the UI shows two choice cards. After the human
    picks, `delivery` is set to `html` or `webapp` and generation continues.
    """
    delivery = (params.get("delivery") or "").strip().lower()
    if delivery not in ("html", "webapp"):
        # Should not happen after a proper choice — fall back to recommendation.
        brief = params.get("brief") or ctx.task_description or ctx.task_title or ""
        delivery = recommend_delivery(brief)

    return {
        "delivery": delivery,
        "chosen": True,
        "tool_for_delivery": "generate_webapp" if delivery == "webapp" else "generate_website",
        "note": (
            "Full React/Next/TypeScript codebase will be generated next."
            if delivery == "webapp"
            else "Premium HTML showcase will be generated next."
        ),
    }
