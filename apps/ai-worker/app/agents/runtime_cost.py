"""Conservative, versioned estimates. These are not the provider's final bill."""

from __future__ import annotations

import math
from dataclasses import dataclass, field
from typing import Any

# Upper published Standard USD / 1M tokens, verified 2026-09-25.
# Session aggregates do not identify each request's context tier/cache writes:
# reserve using long-context cache-write rates, not an invented tier threshold.
# https://developers.openai.com/api/docs/pricing
# Unknown models fail closed instead of being priced as gpt-4o-mini.
PRICING_VERSION = "openai-2026-09-25"
PRICES = {
    "gpt-6-luna": (0.25, 0.02, 0.75),
    "gpt-6-sol": (5.0, 0.4, 15.0),
    "gpt-6-astra": (25.0, 2.0, 75.0),
}


def estimate_cents(model: str, usage: dict[str, Any] | None) -> float | None:
    """Include cache-write upper rates and reasoning already in output tokens."""
    if not usage or model not in PRICES:
        return None
    raw = [usage.get("input_tokens"), usage.get("output_tokens")]
    if any(
        not isinstance(n, (int, float)) or isinstance(n, bool) or not math.isfinite(n) or n < 0
        for n in raw
    ):
        return None
    prompt, output = raw
    cached = (usage.get("input_tokens_details") or {}).get("cached_tokens", 0)
    if (
        not isinstance(cached, (int, float))
        or isinstance(cached, bool)
        or not math.isfinite(cached)
        or not 0 <= cached <= prompt
    ):
        return None
    input_price, cached_price, output_price = PRICES[model]
    return (
        (prompt - cached) * input_price + cached * cached_price + output * output_price
    ) / 10_000


@dataclass
class MissionBudget:
    """One budget for the lead, colleagues, retries and tools; never per child."""

    limit_cents: int
    limit_seconds: int
    usage: dict[str, float | None] = field(default_factory=dict)
    tool_cents: dict[str, float] = field(default_factory=dict)
    active_seconds: dict[str, float] = field(default_factory=dict)

    @property
    def estimated_cents(self) -> float:
        return sum(value or 0 for value in self.usage.values()) + sum(self.tool_cents.values())

    @property
    def known(self) -> bool:
        return bool(self.usage) and all(value is not None for value in self.usage.values())

    @property
    def exhausted(self) -> bool:
        return self.estimated_cents >= self.limit_cents * 0.8

    def ui(self) -> dict[str, int | bool | None]:
        """Expose credits only; provider estimates remain operational data."""
        limit = self.limit_cents * 10
        used = min(limit, math.ceil(self.estimated_cents * 10))
        return {
            "limit_credits": limit,
            "reserved_credits": limit,
            "used_credits": used if self.known else None,
            "remaining_credits": max(0, limit - used) if self.known else None,
            "estimated": True,
            "usage_complete": self.known,
        }
