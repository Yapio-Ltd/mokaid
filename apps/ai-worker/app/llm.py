"""OpenAI client wrapper: chat completions, JSON output and embeddings.

Every helper degrades gracefully when no API key is configured so the
worker keeps functioning (deterministic fallbacks) in offline dev/tests.
"""

import json
from typing import Any

import structlog
from openai import AsyncOpenAI

from app.config import get_settings

log = structlog.get_logger()

EMBEDDING_MODEL = "text-embedding-3-small"
EMBEDDING_DIMENSIONS = 1536

# USD per 1M tokens — used for run cost accounting.
_PRICES: dict[str, dict[str, float]] = {
    "gpt-4o-mini": {"input": 0.15, "output": 0.60},
    "gpt-4o": {"input": 2.50, "output": 10.00},
    "gpt-4.1-mini": {"input": 0.40, "output": 1.60},
    EMBEDDING_MODEL: {"input": 0.02, "output": 0.0},
}

_client: AsyncOpenAI | None = None


def is_configured() -> bool:
    return bool(get_settings().openai_api_key)


def _get_client() -> AsyncOpenAI:
    global _client
    if _client is None:
        _client = AsyncOpenAI(api_key=get_settings().openai_api_key)
    return _client


class UsageTracker:
    """Accumulates token usage and cost across all LLM calls of a run."""

    def __init__(self) -> None:
        self.prompt_tokens = 0
        self.completion_tokens = 0
        self.cost_usd = 0.0

    def add(self, model: str, prompt_tokens: int, completion_tokens: int) -> None:
        self.prompt_tokens += prompt_tokens
        self.completion_tokens += completion_tokens
        prices = _PRICES.get(model, _PRICES["gpt-4o-mini"])
        self.cost_usd += (
            prompt_tokens * prices["input"] + completion_tokens * prices["output"]
        ) / 1_000_000

    @property
    def cost_cents(self) -> int:
        return round(self.cost_usd * 100)

    def as_dict(self) -> dict[str, int]:
        return {
            "prompt_tokens": self.prompt_tokens,
            "completion_tokens": self.completion_tokens,
            "total_tokens": self.prompt_tokens + self.completion_tokens,
        }


async def chat(
    system: str,
    user: str,
    usage: UsageTracker | None = None,
    max_tokens: int = 1500,
) -> str:
    """Single-turn chat completion. Returns the assistant text."""
    model = get_settings().openai_model
    response = await _get_client().chat.completions.create(
        model=model,
        messages=[
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ],
        max_tokens=max_tokens,
    )
    if usage and response.usage:
        usage.add(model, response.usage.prompt_tokens, response.usage.completion_tokens)
    return response.choices[0].message.content or ""


async def chat_json(
    system: str,
    user: str,
    usage: UsageTracker | None = None,
    max_tokens: int = 1500,
) -> dict[str, Any]:
    """Chat completion constrained to a JSON object response."""
    model = get_settings().openai_model
    response = await _get_client().chat.completions.create(
        model=model,
        messages=[
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ],
        response_format={"type": "json_object"},
        max_tokens=max_tokens,
    )
    if usage and response.usage:
        usage.add(model, response.usage.prompt_tokens, response.usage.completion_tokens)
    content = response.choices[0].message.content or "{}"
    try:
        return json.loads(content)
    except json.JSONDecodeError:
        log.warning("llm_json_parse_failed", content=content[:200])
        return {}


async def embed(texts: list[str], usage: UsageTracker | None = None) -> list[list[float]]:
    """Embeds a batch of texts with text-embedding-3-small (1536 dims)."""
    if not texts:
        return []
    response = await _get_client().embeddings.create(model=EMBEDDING_MODEL, input=texts)
    if usage and response.usage:
        usage.add(EMBEDDING_MODEL, response.usage.prompt_tokens, 0)
    return [item.embedding for item in response.data]
