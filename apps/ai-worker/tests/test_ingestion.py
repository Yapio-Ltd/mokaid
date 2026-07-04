from app.memory.ingestion import chunk_text, ingest_document


def test_chunk_text_empty():
    assert chunk_text("") == []


def test_chunk_text_overlap():
    text = "a" * 3000
    chunks = chunk_text(text, size=1200, overlap=150)
    assert len(chunks) == 3
    assert chunks[0][-150:] == chunks[1][:150]


async def test_ingest_document_returns_stats():
    result = await ingest_document({"knowledge_item_id": "k-1", "text": "hello " * 500})
    assert result["knowledge_item_id"] == "k-1"
    assert result["chunk_count"] > 0
    assert result["status"] == "chunked"
