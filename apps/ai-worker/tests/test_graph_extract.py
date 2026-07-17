"""Tests for offline knowledge-graph extraction."""

import pytest

from app.memory.graph_extract import extract_graph


@pytest.mark.asyncio
async def test_heuristic_extract_without_llm():
    text = (
        "Acme Corp refund policy allows Refunds within Thirty Days. "
        "Acme Corp customers must contact Support Team."
    )
    graph = await extract_graph(text, title="Refund Policy", chunks=[text])
    assert graph["nodes"]
    assert any(n["label"] == "Refund Policy" for n in graph["nodes"])
    assert graph["edges"] or len(graph["nodes"]) >= 1
    assert isinstance(graph["chunk_links"], list)


@pytest.mark.asyncio
async def test_empty_text():
    graph = await extract_graph("", title=None)
    assert graph == {"nodes": [], "edges": [], "chunk_links": []}
