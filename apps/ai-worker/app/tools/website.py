"""Website / landing page generation.

Two-phase pipeline for deliverables that look designed, not generated:
1. An art-direction pass picks a design system (palette, type pairing,
   layout pattern, style) matched to the industry and brief.
2. A build pass produces one self-contained HTML file (inline CSS/JS,
   Google Fonts, SVG icons) following that design system.

The result is saved to the task's Drive outputs so the user can preview,
download or deploy it as-is.
"""

import re
from typing import Any

import structlog

from app import llm
from app.tools.registry import RunContext, tool

log = structlog.get_logger()

_ART_DIRECTION_SYSTEM = """You are an award-winning art director. Given a
website brief, define the design system for a landing / ecommerce page.
Respond with a JSON object:
{
  "style": string,            // e.g. "editorial craft", "warm modern", "brutalism", "soft UI", "bento grid"
  "pattern": string,          // e.g. "hero-centric", "shop-first", "conversion-optimized"
  "palette": {"primary": hex, "secondary": hex, "cta": hex, "background": hex, "surface": hex, "text": hex, "text_muted": hex},
  "fonts": {"heading": string, "body": string},  // Google Fonts — expressive pairing with intent
  "mood": string,             // 3-5 words
  "sections": [string]        // ordered page sections tailored to the brief
}

Rules:
- Match the palette and style to the INDUSTRY (a spa is not a fintech; a
  wood-furniture shop is not a SaaS dashboard).
- FORBIDDEN clichés unless the brief explicitly asks: purple-to-indigo
  gradients on white/dark, Inter/Roboto/Arial/system stacks, warm cream
  (#F4F1EA-ish) + terracotta + high-contrast serif broadsheet, neon glow,
  rounded-full pill clusters, multi-layer shadows, emoji icons.
- Text contrast on background must be at least 4.5:1 (WCAG AA).
- Hero is full-bleed / edge-to-edge visual plane — brand is a hero-level
  signal; one headline, one short supporting line, one CTA group.
- For ecommerce / boutique / catalogue briefs: include product grid, product
  detail cues, clear CTA, and a cart UI affordance (visual only).
- Sections must sell without clutter: no stat strips, no floating badges on
  the hero, no decorative card grids that add no interaction.
"""

_BUILDER_SYSTEM = """You are an elite frontend engineer and designer. Build a
COMPLETE, self-contained landing (or shop showcase) page as a single HTML
file. Follow the given design system exactly.

Hard requirements:
- One file only: inline <style> and <script>, no build step, no external
  assets except Google Fonts (via <link>) and inline SVG icons
  (Lucide/Heroicons style paths). NEVER use emoji as icons. No <img> pointing
  to files that don't exist — use inline SVG illustrations or CSS shapes.
- Composition: the first viewport reads as ONE composition (not a dashboard).
  Full-bleed hero as the dominant visual plane. Brand/name at hero level.
  No cards in the hero. No detached labels/badges/stickers overlaid on hero media.
- Responsive: mobile-first, breakpoints ~375/768/1024/1440px. Never scroll
  horizontally.
- Typography: load the two Google Fonts given (expressive — never Inter,
  Roboto, Arial, or bare system-ui as the display face). Clear scale: large
  confident hero headline, body 16-18px, generous line-height.
- Spacing: 8px base; sections breathe (96px+ vertical rhythm on desktop).
- Motion: 2–3 intentional micro-interactions only (200–300ms transitions,
  gentle hover, one subtle scroll-reveal). Respect prefers-reduced-motion.
- Accessibility: semantic landmarks, alt/aria, visible focus, WCAG AA contrast,
  cursor-pointer on clickables.
- Content: real persuasive copy in the brief's language — no lorem ipsum.
  For ecommerce: real product names/prices/blurbs, grid + CTA + cart UI cue.
- FORBIDDEN looks: purple gradient themes, cream+terracotta broadsheet,
  dense newspaper columns with hairline rules, glow spam, pill clusters.

Output ONLY the HTML document, starting with <!doctype html>. No markdown,
no code fences, no commentary."""


def _slugify(name: str) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", (name or "landing-page").lower()).strip("-")
    return slug or "landing-page"


def _strip_fences(html: str) -> str:
    text = html.strip()
    fenced = re.search(r"```(?:html)?\s*(.*)```", text, re.DOTALL)
    if fenced:
        text = fenced.group(1).strip()
    start = text.lower().find("<!doctype")
    if start == -1:
        start = text.lower().find("<html")
    return text[start:] if start > 0 else text


def _ensure_closed(html: str) -> str:
    """Closes the structural tags if generation stopped mid-document, so the
    page renders. Best-effort — a fully-generated page passes through as-is."""
    lower = html.lower()
    additions = ""
    # If an open <style> or <script> was left dangling, close it first so the
    # rest of the page isn't swallowed by the browser's parser.
    if lower.rfind("<style") > lower.rfind("</style>"):
        additions += "\n</style>"
    if lower.rfind("<script") > lower.rfind("</script>"):
        additions += "\n</script>"
    if "<body" in lower and "</body>" not in lower:
        additions += "\n</body>"
    if "<html" in lower and "</html>" not in lower:
        additions += "\n</html>"
    return html + additions if additions else html


@tool("generate_website")
async def generate_website(params: dict[str, Any], ctx: RunContext) -> Any:
    """Generates a production-ready landing page / one-page website (HTML)."""
    brief = (
        params.get("brief")
        or params.get("instructions")
        or ctx.task_description
        or ctx.task_title
        or ""
    )
    brand = params.get("brand_name") or params.get("brand") or ""
    style_hint = params.get("style") or ""

    if not brief:
        return {"error": "No brief provided for the website."}

    if not llm.is_configured():
        return {"error": "LLM not configured.", "note": "offline fallback"}

    # Phase 1 — art direction (design system matched to the industry). Enough
    # headroom that the JSON is never cut off mid-object.
    design = await llm.chat_json(
        system=_ART_DIRECTION_SYSTEM,
        user=(
            f"Brief:\n{brief}\n\n"
            + (f"Brand name: {brand}\n" if brand else "")
            + (f"Style requested by the user (respect it): {style_hint}\n" if style_hint else "")
        ),
        usage=ctx.usage,
        max_tokens=1500,
        quality="smart",
    )

    # Phase 2 — build the page against the design system. Use the long-form
    # generator so a full page is never cut off by the length limit.
    html = await llm.generate_long(
        system=_BUILDER_SYSTEM,
        user=(
            f"Brief:\n{brief}\n\n"
            + (f"Brand name: {brand}\n" if brand else "")
            + f"Design system to follow exactly:\n{design}\n"
        ),
        usage=ctx.usage,
        max_tokens=24000,
        quality="smart",
    )

    html = _strip_fences(html or "")
    if "<html" not in html.lower():
        return {"error": "Website generation produced no valid HTML."}

    # Safety net: if the page still came back unclosed (rare), close the open
    # structural tags so it renders instead of showing a blank page.
    html = _ensure_closed(html)

    filename = f"{_slugify(brand or ctx.task_title or 'landing-page')}.html"

    if ctx.phoenix:
        saved = await ctx.phoenix.save_task_output(
            ctx.workspace_id,
            ctx.task_id,
            filename,
            html,
            mime_type="text/html",
        )
        if saved:
            log.info("website_generated", filename=filename, size=len(html))
            return {
                "filename": filename,
                "drive_item_id": saved.get("id") or saved.get("drive_item_id"),
                "mime_type": "text/html",
                "size_bytes": len(html),
                "style": design.get("style"),
                "pattern": design.get("pattern"),
                "mood": design.get("mood"),
                "sections": design.get("sections"),
                "note": "Self-contained HTML — open it in a browser or deploy as-is.",
            }

    return {"error": "Could not save the generated website."}
