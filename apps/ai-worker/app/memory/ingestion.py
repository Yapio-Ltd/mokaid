"""Document ingestion pipeline.

fetch text (inline, or downloaded + extracted from a presigned file URL) ->
structure-aware chunking (LangChain RecursiveCharacterTextSplitter, markdown
separators first) -> contextual enrichment (document title prefixed to each
chunk before embedding) -> embed (OpenAI text-embedding-3-small, 1536 dims) ->
POST chunks back to the Phoenix API which stores them in pgvector and marks
the knowledge item as indexed.

Requires OPENAI_API_KEY for embeddings. Without it the item is marked failed
in Phoenix so it never stays stuck in `indexing`.
"""

from typing import Any

import httpx
import structlog

from app import llm
from app.clients.phoenix import PhoenixClient
from app.memory import extractors
from app.memory.graph_extract import extract_graph

log = structlog.get_logger()

CHUNK_SIZE = 1200
CHUNK_OVERLAP = 150
EMBED_BATCH_SIZE = 64

# Split along document structure first (markdown headings, paragraphs,
# sentences) so chunks align with semantic boundaries instead of cutting
# mid-sentence. Our extractors emit markdown headings for DOCX/XLSX/PPTX.
_SEPARATORS = [
    "\n## ",
    "\n### ",
    "\n\n",
    "\n",
    ". ",
    "? ",
    "! ",
    "; ",
    ", ",
    " ",
    "",
]


def chunk_text(text: str, size: int = CHUNK_SIZE, overlap: int = CHUNK_OVERLAP) -> list[str]:
    """Structure-aware chunking via LangChain's recursive splitter."""
    if not text:
        return []

    from langchain_text_splitters import RecursiveCharacterTextSplitter

    splitter = RecursiveCharacterTextSplitter(
        chunk_size=size,
        chunk_overlap=overlap,
        separators=_SEPARATORS,
        keep_separator=True,
    )
    return [chunk for chunk in splitter.split_text(text) if chunk.strip()]


def contextualize(chunks: list[str], title: str | None) -> list[str]:
    """Prefix each chunk with its document title before embedding.

    Retrieval quality improves markedly when the embedding carries the
    document context ("[Document: Q3 accounts] | revenue table…") instead of
    an anonymous fragment.
    """
    clean_title = (title or "").strip()
    if not clean_title:
        return chunks
    prefix = f"[Document: {clean_title[:120]}]\n"
    return [prefix + chunk for chunk in chunks]


async def _download(url: str) -> bytes:
    async with httpx.AsyncClient(timeout=60, follow_redirects=True) as client:
        resp = await client.get(url)
        resp.raise_for_status()
        return resp.content


async def _resolve_text(payload: dict[str, Any]) -> tuple[str, str | None]:
    """Return (text, error). Inline text wins; otherwise download the file
    from its presigned URL and extract text with the format parsers."""
    text = (payload.get("text") or "").strip()
    if text:
        return text, None

    file_url = (payload.get("file_url") or "").strip()
    if not file_url:
        return "", None

    filename = payload.get("filename") or payload.get("original_filename") or ""
    mime_type = payload.get("mime_type")

    try:
        data = await _download(file_url)
    except Exception as exc:
        log.warning("ingest_download_failed", error=str(exc))
        return "", f"download failed: {exc}"

    result = extractors.extract_bytes(data, filename=filename, mime_type=mime_type)
    if result is None:
        log.warning("ingest_extraction_failed", filename=filename, mime_type=mime_type)
        return "", f"unsupported or unreadable format: {filename or mime_type or 'unknown'}"

    log.info(
        "ingest_extracted",
        filename=filename,
        format=result.format,
        chars=len(result.text),
    )
    return result.text, None


async def ingest_document(
    payload: dict[str, Any], phoenix: PhoenixClient | None = None
) -> dict[str, Any]:
    """Ingest a knowledge item. Returns chunk/embedding stats."""
    item_id = payload.get("knowledge_item_id")
    workspace_id = payload.get("workspace_id")

    text, error = await _resolve_text(payload)
    if error:
        if item_id and workspace_id:
            phoenix = phoenix or PhoenixClient()
            await phoenix.mark_knowledge_failed(item_id, workspace_id, error)
        return {
            "knowledge_item_id": item_id,
            "chunk_count": 0,
            "embedded": False,
            "status": "failed",
            "error": error,
        }

    chunks = chunk_text(text)
    log.info("document_chunked", item_id=item_id, chunks=len(chunks))

    phoenix = phoenix or (PhoenixClient() if item_id and workspace_id else None)

    if not chunks:
        # Empty body — mark indexed with zero chunks so status does not stick.
        if phoenix is not None:
            await phoenix.post_knowledge_chunks(item_id, workspace_id, [])
        return {
            "knowledge_item_id": item_id,
            "chunk_count": 0,
            "embedded": False,
            "status": "indexed",
        }

    if not llm.embeddings_configured():
        error = "embeddings unavailable: OPENAI_API_KEY is required for knowledge indexing"
        log.warning("ingest_embeddings_unavailable", item_id=item_id)
        if phoenix is not None:
            await phoenix.mark_knowledge_failed(item_id, workspace_id, error)
        return {
            "knowledge_item_id": item_id,
            "chunk_count": len(chunks),
            "embedded": False,
            "status": "failed",
            "error": error,
        }

    embed_inputs = contextualize(chunks, payload.get("title"))
    usage = llm.UsageTracker()

    async def report_usage() -> None:
        """Meters embedding/graph LLM cost, even on partial failure."""
        if phoenix is not None and workspace_id:
            await phoenix.report_usage(
                workspace_id,
                "knowledge_ingest",
                usage.cost_cents,
                token_usage=usage.as_dict(),
            )

    try:
        embeddings: list[list[float]] = []
        for start in range(0, len(embed_inputs), EMBED_BATCH_SIZE):
            batch = embed_inputs[start : start + EMBED_BATCH_SIZE]
            embeddings.extend(await llm.embed(batch, usage=usage))

        if len(embeddings) != len(chunks):
            raise RuntimeError(
                f"embedding count mismatch: got {len(embeddings)} for {len(chunks)} chunks"
            )
    except Exception as exc:
        error = f"embedding failed: {exc}"
        log.error("ingest_embed_failed", item_id=item_id, error=str(exc))
        await report_usage()
        if phoenix is not None:
            await phoenix.mark_knowledge_failed(item_id, workspace_id, error)
        return {
            "knowledge_item_id": item_id,
            "chunk_count": len(chunks),
            "embedded": False,
            "status": "failed",
            "error": error,
        }

    log.info("document_embedded", item_id=item_id, vectors=len(embeddings))

    graph: dict[str, Any] | None = None
    try:
        graph = await extract_graph(text, title=payload.get("title"), chunks=chunks, usage=usage)
        log.info(
            "document_graph_extracted",
            item_id=item_id,
            nodes=len(graph.get("nodes") or []),
            edges=len(graph.get("edges") or []),
        )
    except Exception as exc:
        log.warning("document_graph_failed", item_id=item_id, error=str(exc))
        graph = None

    await report_usage()

    stored = False
    if phoenix is not None:
        stored = await phoenix.post_knowledge_chunks(
            item_id,
            workspace_id,
            [
                {"content": content, "embedding": vector}
                for content, vector in zip(chunks, embeddings, strict=True)
            ],
            graph=graph,
        )
        if not stored:
            error = "failed to store embedded chunks in Phoenix"
            await phoenix.mark_knowledge_failed(item_id, workspace_id, error)
            return {
                "knowledge_item_id": item_id,
                "chunk_count": len(chunks),
                "embedded": True,
                "stored": False,
                "status": "failed",
                "error": error,
            }

    return {
        "knowledge_item_id": item_id,
        "chunk_count": len(chunks),
        "embedded": True,
        "stored": stored,
        "graph_nodes": len((graph or {}).get("nodes") or []),
        "status": "indexed" if stored else "embedded",
    }
