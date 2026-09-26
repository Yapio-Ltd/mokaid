"""Web search tool — live internet lookup for research missions.

Uses Tavily when TAVILY_API_KEY is set (best quality for agents), otherwise
DuckDuckGo (ddgs) so local/dev works without a paid key.
"""

from __future__ import annotations

from typing import Any

import structlog

from app.config import get_settings
from app.tools.registry import RunContext, tool

log = structlog.get_logger()


@tool("web_search")
async def web_search(params: dict[str, Any], ctx: RunContext) -> Any:
    """Search the public web for current information. Returns titles, URLs and
    short snippets. Always use this before answering research / lookup /
    "who is" / company questions — never invent facts or sources."""
    query = (params.get("query") or "").strip()
    if not query:
        query = (ctx.task_title or ctx.task_description or "").strip()
    if not query:
        return {"results": [], "error": "empty query", "query": query}

    try:
        max_results = int(params.get("max_results") or 5)
    except (TypeError, ValueError):
        max_results = 5
    max_results = max(1, min(max_results, 10))

    try:
        settings = get_settings()
        if settings.tavily_api_key:
            ctx.usage.cost_usd += settings.tavily_search_cost_usd
        results = await _search(query, max_results)
    except Exception as exc:  # noqa: BLE001
        log.warning("web_search_failed", query=query[:120], error=str(exc))
        return {
            "results": [],
            "query": query,
            "error": f"web search unavailable: {exc}",
        }

    return {
        "query": query,
        "provider": results.get("provider"),
        "results": results.get("results") or [],
    }


async def _search(query: str, max_results: int) -> dict[str, Any]:
    settings = get_settings()
    if settings.tavily_api_key:
        try:
            return await _search_tavily(query, max_results, settings.tavily_api_key)
        except Exception as exc:  # noqa: BLE001
            log.warning("tavily_failed_fallback_ddg", error=str(exc))

    return await _search_duckduckgo(query, max_results)


async def _search_tavily(query: str, max_results: int, api_key: str) -> dict[str, Any]:
    import httpx

    async with httpx.AsyncClient(timeout=30) as client:
        resp = await client.post(
            "https://api.tavily.com/search",
            json={
                "api_key": api_key,
                "query": query,
                "max_results": max_results,
                "include_answer": False,
                "search_depth": "basic",
            },
        )
        resp.raise_for_status()
        data = resp.json()

    results = []
    for item in data.get("results") or []:
        results.append(
            {
                "title": item.get("title") or "",
                "url": item.get("url") or "",
                "snippet": item.get("content") or item.get("snippet") or "",
            }
        )
    return {"provider": "tavily", "results": results}


async def _search_duckduckgo(query: str, max_results: int) -> dict[str, Any]:
    """Run DuckDuckGo text search off the event loop (sync client)."""
    import asyncio

    def _run() -> list[dict[str, str]]:
        try:
            from ddgs import DDGS
        except ImportError:
            from duckduckgo_search import DDGS  # type: ignore[no-redef]

        rows: list[dict[str, str]] = []
        with DDGS() as ddgs:
            for hit in ddgs.text(query, max_results=max_results):
                rows.append(
                    {
                        "title": hit.get("title") or "",
                        "url": hit.get("href") or hit.get("link") or "",
                        "snippet": hit.get("body") or hit.get("snippet") or "",
                    }
                )
        return rows

    results = await asyncio.to_thread(_run)
    return {"provider": "duckduckgo", "results": results}


def format_results_for_llm(payload: dict[str, Any]) -> str:
    """Compact text block for injecting search hits into a chat prompt."""
    results = payload.get("results") or []
    if not results:
        err = payload.get("error") or "no results"
        return f"(web search returned nothing: {err})"
    lines = []
    for i, row in enumerate(results, 1):
        title = (row.get("title") or "").strip()
        url = (row.get("url") or "").strip()
        snippet = (row.get("snippet") or "").strip()
        lines.append(f"{i}. {title}\n   {url}\n   {snippet}")
    return "\n".join(lines)
