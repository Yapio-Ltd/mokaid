"""PDF deliverable rendering."""

from app.pdf import markdown_to_html, markdown_to_pdf_bytes
from app.tools.files import export_pdf
from app.tools.registry import RunContext


def test_markdown_to_html_covers_common_shapes():
    md = (
        "# Titre\n\n"
        "Un paragraphe avec **gras**, *italique* et `code`.\n\n"
        "- point un\n"
        "- point deux\n\n"
        "1. étape\n\n"
        "> citation\n\n"
        "| A | B |\n|---|---|\n| 1 | 2 |\n\n"
        "```\ncode block\n```\n"
    )
    html = markdown_to_html(md)
    assert "<h1>Titre</h1>" in html
    assert "<b>gras</b>" in html
    assert "<i>italique</i>" in html
    assert "<code>code</code>" in html
    assert "<ul>" in html and "<li>point un</li>" in html
    assert "<ol>" in html
    assert "<blockquote>citation</blockquote>" in html
    assert "<table>" in html and "<th>A</th>" in html and "<td>1</td>" in html
    assert "<pre>code block</pre>" in html


def test_markdown_to_html_escapes_raw_html():
    html = markdown_to_html("Hello <script>alert(1)</script>")
    assert "<script>" not in html
    assert "&lt;script&gt;" in html


def test_markdown_to_pdf_produces_valid_pdf():
    pdf = markdown_to_pdf_bytes("# Doc\n\nContenu.", title="Doc")
    assert pdf.startswith(b"%PDF")


async def test_export_pdf_saves_deliverable(phoenix):
    ctx = RunContext(run_id="r-pdf", workspace_id="ws-1", task_id="t1", phoenix=phoenix)
    result = await export_pdf(
        {"title": "Rapport d'audit", "content": "# Rapport\n\nRésultats."}, ctx
    )
    assert result.get("filename", "").endswith(".pdf")
    assert result.get("size_bytes", 0) > 0
    assert any(kind == "output" for kind, _ in phoenix.calls)


async def test_export_pdf_requires_content(phoenix):
    ctx = RunContext(run_id="r-pdf2", workspace_id="ws-1", task_id="t1", phoenix=phoenix)
    result = await export_pdf({"title": "Vide", "content": "  "}, ctx)
    assert "error" in result
