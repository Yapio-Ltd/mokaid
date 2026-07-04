"""Document ingestion pipeline skeleton.

Full pipeline: fetch from S3 -> extract text -> chunk -> embed (OpenAI) ->
POST chunks back to the Phoenix API which stores them in pgvector.
Extraction/embedding are stubbed until provider keys are configured.
"""

from typing import Any

import structlog

log = structlog.get_logger()

CHUNK_SIZE = 1200
CHUNK_OVERLAP = 150


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


async def ingest_document(payload: dict[str, Any]) -> dict[str, Any]:
    """Ingest a knowledge item. Returns chunk stats for the API callback."""
    item_id = payload.get("knowledge_item_id")
    text = payload.get("text", "")

    chunks = chunk_text(text)
    log.info("document_chunked", item_id=item_id, chunks=len(chunks))

    # Embedding stub: real implementation calls OpenAI embeddings in batches
    # and posts vectors to POST /api/worker/knowledge/:id/chunks.
    return {
        "knowledge_item_id": item_id,
        "chunk_count": len(chunks),
        "embedded": False,
        "status": "chunked",
    }
