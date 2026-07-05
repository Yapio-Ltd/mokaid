"""Document ingestion pipeline.

fetch text -> chunk -> embed (OpenAI text-embedding-3-small, 1536 dims) ->
POST chunks back to the Phoenix API which stores them in pgvector and marks
the knowledge item as indexed. Without an OpenAI key the pipeline still
chunks (embeddings skipped) so dev/tests work offline.
"""

from typing import Any

import structlog

from app import llm
from app.clients.phoenix import PhoenixClient

log = structlog.get_logger()

CHUNK_SIZE = 1200
CHUNK_OVERLAP = 150
EMBED_BATCH_SIZE = 64


def chunk_text(text: str, size: int = CHUNK_SIZE, overlap: int = CHUNK_OVERLAP) -> list[str]:
    if not text:
        return []
    chunks: list[str] = []
    start = 0
    while start < len(text):
        end = min(start + size, len(text))
        chunks.append(text[start:end])
        if end == len(text):
            break
        start = end - overlap
    return chunks


async def ingest_document(
    payload: dict[str, Any], phoenix: PhoenixClient | None = None
) -> dict[str, Any]:
    """Ingest a knowledge item. Returns chunk/embedding stats."""
    item_id = payload.get("knowledge_item_id")
    workspace_id = payload.get("workspace_id")
    text = payload.get("text", "")

    chunks = chunk_text(text)
    log.info("document_chunked", item_id=item_id, chunks=len(chunks))

    if not chunks:
        return {
            "knowledge_item_id": item_id,
            "chunk_count": 0,
            "embedded": False,
            "status": "chunked",
        }

    if not llm.is_configured():
        return {
            "knowledge_item_id": item_id,
            "chunk_count": len(chunks),
            "embedded": False,
            "status": "chunked",
        }

    embeddings: list[list[float]] = []
    for start in range(0, len(chunks), EMBED_BATCH_SIZE):
        batch = chunks[start : start + EMBED_BATCH_SIZE]
        embeddings.extend(await llm.embed(batch))

    log.info("document_embedded", item_id=item_id, vectors=len(embeddings))

    stored = False
    if item_id and workspace_id:
        phoenix = phoenix or PhoenixClient()
        stored = await phoenix.post_knowledge_chunks(
            item_id,
            workspace_id,
            [
                {"content": content, "embedding": vector}
                for content, vector in zip(chunks, embeddings, strict=True)
            ],
        )

    return {
        "knowledge_item_id": item_id,
        "chunk_count": len(chunks),
        "embedded": True,
        "stored": stored,
        "status": "indexed" if stored else "embedded",
    }
