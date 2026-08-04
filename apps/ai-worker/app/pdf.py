"""Markdown → styled PDF rendering for deliverables.

Documents and analyses ship as PDF by default: it opens instantly in the
web app's immersive viewer and looks finished, unlike raw markdown. Uses
PyMuPDF's Story engine (already a dependency) — no headless browser needed.
"""

from __future__ import annotations

import html as html_mod
import io
import re

import structlog

log = structlog.get_logger()

_CSS = """
body { font-family: sans-serif; font-size: 10.5pt; line-height: 1.55; color: #1c2333; }
h1 { font-size: 21pt; color: #101526; margin: 0 0 6pt 0; line-height: 1.2; }
h2 { font-size: 14.5pt; color: #101526; margin: 16pt 0 5pt 0; }
h3 { font-size: 12pt; color: #1c2333; margin: 12pt 0 4pt 0; }
h4 { font-size: 10.5pt; color: #1c2333; margin: 10pt 0 3pt 0; }
p { margin: 0 0 7pt 0; }
ul, ol { margin: 0 0 8pt 0; }
li { margin: 0 0 3pt 0; }
blockquote { margin: 6pt 0 8pt 10pt; color: #4a5268; }
code { font-family: monospace; font-size: 9pt; color: #37415c; }
pre { font-family: monospace; font-size: 8.5pt; color: #37415c; margin: 6pt 0 9pt 0; }
hr { margin: 10pt 0; }
a { color: #3b5bdb; }
table { font-size: 9.5pt; margin: 6pt 0 9pt 0; }
th { color: #101526; }
.mk-meta { font-size: 9pt; color: #6a7188; margin: 0 0 18pt 0; }
"""

_INLINE_RULES = [
    (re.compile(r"`([^`]+)`"), r"<code>\1</code>"),
    (re.compile(r"\*\*([^*]+)\*\*"), r"<b>\1</b>"),
    (re.compile(r"__([^_]+)__"), r"<b>\1</b>"),
    (re.compile(r"\*([^*\n]+)\*"), r"<i>\1</i>"),
    (re.compile(r"\[([^\]]+)\]\((https?://[^)\s]+)\)"), r'<a href="\2">\1</a>'),
]


def _inline(text: str) -> str:
    out = html_mod.escape(text, quote=False)
    for pattern, repl in _INLINE_RULES:
        out = pattern.sub(repl, out)
    return out


def markdown_to_html(md: str) -> str:
    """Small, dependency-free markdown → HTML converter covering the shapes
    LLM-written documents actually use: headings, lists, fenced code,
    blockquotes, tables, hr, inline bold/italic/code/links."""
    lines = (md or "").replace("\r\n", "\n").split("\n")
    out: list[str] = []
    paragraph: list[str] = []
    list_stack: list[str] = []  # "ul" / "ol"
    in_code = False
    code_lines: list[str] = []
    table_rows: list[str] = []

    def flush_paragraph() -> None:
        if paragraph:
            out.append(f"<p>{_inline(' '.join(paragraph))}</p>")
            paragraph.clear()

    def close_lists() -> None:
        while list_stack:
            out.append(f"</{list_stack.pop()}>")

    def flush_table() -> None:
        if table_rows:
            out.append("<table>" + "".join(table_rows) + "</table>")
            table_rows.clear()

    for raw in lines:
        line = raw.rstrip()

        if in_code:
            if line.strip().startswith("```"):
                code = html_mod.escape("\n".join(code_lines))
                out.append(f"<pre>{code}</pre>")
                code_lines.clear()
                in_code = False
            else:
                code_lines.append(raw)
            continue

        stripped = line.strip()

        if stripped.startswith("```"):
            flush_paragraph()
            close_lists()
            flush_table()
            in_code = True
            continue

        if not stripped:
            flush_paragraph()
            close_lists()
            flush_table()
            continue

        # Table rows: | a | b |  (separator rows |---| are skipped)
        if stripped.startswith("|") and stripped.endswith("|"):
            flush_paragraph()
            close_lists()
            cells = [c.strip() for c in stripped.strip("|").split("|")]
            if all(re.fullmatch(r":?-{2,}:?", c) for c in cells if c):
                continue
            tag = "th" if not table_rows else "td"
            table_rows.append(
                "<tr>" + "".join(f"<{tag}>{_inline(c)}</{tag}>" for c in cells) + "</tr>"
            )
            continue
        flush_table()

        heading = re.match(r"^(#{1,4})\s+(.*)$", stripped)
        if heading:
            flush_paragraph()
            close_lists()
            level = len(heading.group(1))
            out.append(f"<h{level}>{_inline(heading.group(2))}</h{level}>")
            continue

        if re.fullmatch(r"(-{3,}|\*{3,}|_{3,})", stripped):
            flush_paragraph()
            close_lists()
            out.append("<hr/>")
            continue

        if stripped.startswith(">"):
            flush_paragraph()
            close_lists()
            out.append(f"<blockquote>{_inline(stripped.lstrip('> '))}</blockquote>")
            continue

        bullet = re.match(r"^[-*+]\s+(.*)$", stripped)
        ordered = re.match(r"^\d+[.)]\s+(.*)$", stripped)
        if bullet or ordered:
            flush_paragraph()
            kind = "ul" if bullet else "ol"
            if not list_stack or list_stack[-1] != kind:
                close_lists()
                list_stack.append(kind)
                out.append(f"<{kind}>")
            content = (bullet or ordered).group(1)
            out.append(f"<li>{_inline(content)}</li>")
            continue

        paragraph.append(stripped)

    flush_paragraph()
    close_lists()
    flush_table()
    return "\n".join(out)


def html_to_pdf_bytes(body_html: str) -> bytes:
    """Lays the HTML out on A4 pages with PyMuPDF Story."""
    import fitz

    story = fitz.Story(html=f"<body>{body_html}</body>", user_css=_CSS)
    buf = io.BytesIO()
    writer = fitz.DocumentWriter(buf)
    mediabox = fitz.paper_rect("a4")
    where = mediabox + (46, 48, -46, -52)

    more = 1
    while more:
        device = writer.begin_page(mediabox)
        more, _ = story.place(where)
        story.draw(device)
        writer.end_page()
    writer.close()
    return buf.getvalue()


def markdown_to_pdf_bytes(md: str, title: str | None = None, subtitle: str | None = None) -> bytes:
    """Renders a markdown document as a finished PDF deliverable."""
    body = markdown_to_html(md)
    # Prepend a title block unless the document already opens with an H1.
    if title and not body.lstrip().startswith("<h1>"):
        meta = f'<p class="mk-meta">{_inline(subtitle)}</p>' if subtitle else ""
        body = f"<h1>{_inline(title)}</h1>{meta}{body}"
    return html_to_pdf_bytes(body)
