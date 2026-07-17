"""Semantic entity/relation extraction for the workspace knowledge graph.

Produces a Graphify-inspired payload:

    {
      "nodes": [{"key", "label", "kind"}],
      "edges": [{"source", "target", "relation", "confidence"}],
      "chunk_links": [{"node_key", "chunk_index"}]
    }

Runs only when an LLM is configured; otherwise returns a heuristic fallback
from capitalized phrases so offline tests still exercise the pipeline.
"""

from __future__ import annotations

import re
from typing import Any

import structlog

from app import llm

log = structlog.get_logger()

_EXTRACT_SYSTEM = """You extract a knowledge graph from a document.
Return ONLY valid JSON with this shape:
{
  "nodes": [{"key": "slug", "label": "Human Name", "kind": "concept|entity|person|org|product|process|document|term"}],
  "edges": [{"source": "slug", "target": "slug", "relation": "related_to|part_of|uses|owns|defines|references", "confidence": "EXTRACTED|INFERRED|AMBIGUOUS"}]
}
Rules:
- Max 25 nodes, max 40 edges.
- Keys are lowercase kebab-case slugs.
- Prefer EXTRACTED when the relation is explicit in the text.
- Focus on durable business concepts, not filler words.
"""


def _slug(text: str) -> str:
    s = re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")
    return (s or "node")[:80]


async def extract_graph(
    text: str,
    title: str | None = None,
    chunks: list[str] | None = None,
    usage: llm.UsageTracker | None = None,
) -> dict[str, Any]:
    """Extract nodes/edges from document text."""
    body = (text or "").strip()
    if not body:
        return {"nodes": [], "edges": [], "chunk_links": []}

    if llm.is_configured():
        excerpt = body[:12_000]
        user = f"Document title: {title or 'Untitled'}\n\n{excerpt}"
        try:
            raw = await llm.chat_json(
                system=_EXTRACT_SYSTEM,
                user=user,
                usage=usage,
                max_tokens=2000,
            )
            payload = _normalize(raw if isinstance(raw, dict) else {})
        except Exception as exc:
            log.warning("graph_extract_llm_failed", error=str(exc))
            payload = _heuristic_extract(body, title)
    else:
        payload = _heuristic_extract(body, title)

    payload["chunk_links"] = _link_chunks(payload["nodes"], chunks or [])
    return payload


def _normalize(raw: dict[str, Any]) -> dict[str, Any]:
    nodes_in = list(raw.get("nodes") or [])[:25]
    edges_in = list(raw.get("edges") or [])[:40]
    nodes: list[dict[str, Any]] = []
    keys: set[str] = set()

    for node in nodes_in:
        if not isinstance(node, dict):
            continue
        label = str(node.get("label") or node.get("key") or "").strip()
        if not label:
            continue
        key = _slug(str(node.get("key") or label))
        if key in keys:
            continue
        keys.add(key)
        kind = str(node.get("kind") or "concept").lower()
        if kind not in {
            "concept",
            "entity",
            "person",
            "org",
            "product",
            "process",
            "document",
            "term",
        }:
            kind = "concept"
        nodes.append({"key": key, "label": label[:200], "kind": kind})

    edges: list[dict[str, Any]] = []
    for edge in edges_in:
        if not isinstance(edge, dict):
            continue
        source = _slug(str(edge.get("source") or ""))
        target = _slug(str(edge.get("target") or ""))
        if source not in keys or target not in keys or source == target:
            continue
        confidence = str(edge.get("confidence") or "INFERRED").upper()
        if confidence not in {"EXTRACTED", "INFERRED", "AMBIGUOUS"}:
            confidence = "INFERRED"
        edges.append(
            {
                "source": source,
                "target": target,
                "relation": str(edge.get("relation") or "related_to")[:64],
                "confidence": confidence,
            }
        )

    return {"nodes": nodes, "edges": edges, "chunk_links": []}


def _heuristic_extract(text: str, title: str | None) -> dict[str, Any]:
    """Offline fallback: title + frequent capitalized multi-word phrases."""
    nodes: list[dict[str, Any]] = []
    keys: set[str] = set()

    if title:
        key = _slug(title)
        nodes.append({"key": key, "label": title[:200], "kind": "document"})
        keys.add(key)

    phrases = re.findall(r"\b([A-Z][a-z]+(?:\s+[A-Z][a-z]+){0,3})\b", text[:8000])
    counts: dict[str, int] = {}
    for phrase in phrases:
        if len(phrase) < 3:
            continue
        counts[phrase] = counts.get(phrase, 0) + 1

    for phrase, _count in sorted(counts.items(), key=lambda kv: -kv[1])[:15]:
        key = _slug(phrase)
        if key in keys:
            continue
        keys.add(key)
        nodes.append({"key": key, "label": phrase, "kind": "concept"})

    edges: list[dict[str, Any]] = []
    if title and len(nodes) > 1:
        doc_key = _slug(title)
        for node in nodes[1:8]:
            edges.append(
                {
                    "source": doc_key,
                    "target": node["key"],
                    "relation": "defines",
                    "confidence": "INFERRED",
                }
            )

    return {"nodes": nodes, "edges": edges, "chunk_links": []}


def _link_chunks(nodes: list[dict[str, Any]], chunks: list[str]) -> list[dict[str, Any]]:
    links: list[dict[str, Any]] = []
    for node in nodes:
        label = (node.get("label") or "").lower()
        if not label:
            continue
        for index, chunk in enumerate(chunks):
            if label in chunk.lower():
                links.append({"node_key": node["key"], "chunk_index": index})
                break
    return links[:80]
