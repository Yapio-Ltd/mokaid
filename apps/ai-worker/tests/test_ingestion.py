from app import llm
from app.memory import ingestion
from app.memory.ingestion import chunk_text, contextualize, ingest_document
from tests.test_extractors import make_docx, make_xlsx


def test_chunk_text_empty():
    assert chunk_text("") == []


def test_chunk_text_respects_size():
    text = "phrase courte. " * 500
    chunks = chunk_text(text, size=1200, overlap=150)
    assert len(chunks) > 1
    assert all(len(c) <= 1200 for c in chunks)
    # Recursive splitter cuts on sentence boundaries, not mid-word.
    assert all(c.strip() for c in chunks)


def test_chunk_text_splits_on_markdown_headings():
    sections = [f"## Section {i}\n\n" + ("contenu de la section. " * 30) for i in range(5)]
    chunks = chunk_text("\n\n".join(sections), size=800, overlap=100)
    # Structure-aware: heading markers survive at chunk starts.
    heading_starts = [c for c in chunks if c.lstrip().startswith("## Section")]
    assert len(heading_starts) >= 3


def test_contextualize_prefixes_title():
    chunks = ["premier fragment", "second fragment"]
    enriched = contextualize(chunks, "Comptes Q3 2026")
    assert enriched[0].startswith("[Document: Comptes Q3 2026]\n")
    assert enriched[1].endswith("second fragment")
    # No title: unchanged.
    assert contextualize(chunks, None) == chunks
    assert contextualize(chunks, "  ") == chunks


async def test_ingest_document_fails_without_openai_key():
    """Offline: no OPENAI_API_KEY -> mark failed when Phoenix ids are present."""
    phoenix = RecordingPhoenix()
    result = await ingest_document(
        {
            "knowledge_item_id": "k-1",
            "workspace_id": "ws-1",
            "text": "hello " * 500,
        },
        phoenix=phoenix,
    )
    assert result["knowledge_item_id"] == "k-1"
    assert result["chunk_count"] > 0
    assert result["status"] == "failed"
    assert "OPENAI_API_KEY" in (result.get("error") or "")
    assert phoenix.failed and phoenix.failed[0][0] == "k-1"


class RecordingPhoenix:
    def __init__(self) -> None:
        self.failed: list[tuple[str, str]] = []
        self.chunks: list[dict] = []

    async def mark_knowledge_failed(self, item_id, workspace_id, error):
        self.failed.append((item_id, error))
        return True

    async def post_knowledge_chunks(self, item_id, workspace_id, chunks, graph=None):
        self.chunks.append({"item_id": item_id, "chunks": chunks, "graph": graph})
        return True

    async def report_usage(self, workspace_id, source, cost_cents, token_usage=None, agent_id=None):
        return None


async def test_ingest_document_from_file_url_docx(monkeypatch):
    """Binary knowledge item: download from presigned URL, extract, chunk."""
    docx_bytes = make_docx()

    async def fake_download(url: str) -> bytes:
        assert url == "https://s3/presigned/contrat.docx"
        return docx_bytes

    monkeypatch.setattr(ingestion, "_download", fake_download)
    result = await ingest_document(
        {
            "knowledge_item_id": "k-docx",
            "workspace_id": "ws-1",
            "file_url": "https://s3/presigned/contrat.docx",
            "filename": "contrat.docx",
            "title": "Contrat de prestation",
        }
    )
    assert result["status"] == "failed"  # offline: no OPENAI_API_KEY
    assert result["chunk_count"] >= 1


async def test_ingest_document_from_file_url_xlsx(monkeypatch):
    xlsx_bytes = make_xlsx()

    async def fake_download(url: str) -> bytes:
        return xlsx_bytes

    monkeypatch.setattr(ingestion, "_download", fake_download)
    result = await ingest_document(
        {
            "knowledge_item_id": "k-xlsx",
            "workspace_id": "ws-1",
            "file_url": "https://s3/presigned/comptes.xlsx",
            "filename": "comptes.xlsx",
        }
    )
    assert result["status"] == "failed"
    assert result["chunk_count"] >= 1


async def test_ingest_document_marks_failed_on_unreadable_file(monkeypatch):
    async def fake_download(url: str) -> bytes:
        return b"\x89PNG\r\n\x1a\n" + bytes(range(256)) * 4

    monkeypatch.setattr(ingestion, "_download", fake_download)
    phoenix = RecordingPhoenix()
    result = await ingest_document(
        {
            "knowledge_item_id": "k-bad",
            "workspace_id": "ws-1",
            "file_url": "https://s3/presigned/image.png",
            "filename": "image.png",
        },
        phoenix=phoenix,
    )
    assert result["status"] == "failed"
    assert phoenix.failed and phoenix.failed[0][0] == "k-bad"


async def test_ingest_document_marks_failed_on_download_error(monkeypatch):
    async def fake_download(url: str) -> bytes:
        raise RuntimeError("403 Forbidden")

    monkeypatch.setattr(ingestion, "_download", fake_download)
    phoenix = RecordingPhoenix()
    result = await ingest_document(
        {
            "knowledge_item_id": "k-403",
            "workspace_id": "ws-1",
            "file_url": "https://s3/expired",
            "filename": "doc.pdf",
        },
        phoenix=phoenix,
    )
    assert result["status"] == "failed"
    assert "download failed" in result["error"]
    assert phoenix.failed


async def test_ingest_document_embeds_and_stores(monkeypatch):
    """Happy path: OpenAI embeddings + Phoenix chunk store."""

    async def fake_embed(texts, usage=None):
        return [[0.01] * 8 for _ in texts]

    async def fake_extract_graph(*a, **k):
        return {"nodes": [], "edges": []}

    monkeypatch.setattr(llm, "embeddings_configured", lambda: True)
    monkeypatch.setattr(llm, "embed", fake_embed)
    monkeypatch.setattr("app.memory.ingestion.extract_graph", fake_extract_graph)

    phoenix = RecordingPhoenix()
    result = await ingest_document(
        {
            "knowledge_item_id": "k-ok",
            "workspace_id": "ws-1",
            "title": "PR review",
            "text": "Review pull requests carefully. " * 40,
        },
        phoenix=phoenix,
    )
    assert result["status"] == "indexed"
    assert result["embedded"] is True
    assert result["stored"] is True
    assert phoenix.chunks and len(phoenix.chunks[0]["chunks"]) >= 1
    assert phoenix.chunks[0]["chunks"][0]["embedding"]
