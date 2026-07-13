"""Multi-provider LLM wrapper with 3-tier cost routing.

Provider priority (text):
  1. DeepSeek — cheapest, used for "fast" quality when configured (chat
     replies, triage, extraction, summaries).  V4-Flash output is ~$0.28/M
     vs Claude Haiku ~$5/M.
  2. Anthropic (Claude) — high quality, used for "smart" quality (mission
     planning, customer-visible deliverables) and as "fast" fallback when
     DeepSeek is not configured.
  3. OpenAI — last resort text fallback; always used for embeddings, images
     and audio (no DeepSeek/Anthropic equivalent).

DeepSeek exposes an OpenAI-compatible API so the existing AsyncOpenAI SDK
works with a different base_url — no new dependency needed.
"""

import json
import re
from collections.abc import AsyncIterator
from typing import Any, Literal

import structlog
from anthropic import AsyncAnthropic
from openai import AsyncOpenAI

from app.config import get_settings

log = structlog.get_logger()

EMBEDDING_MODEL = "text-embedding-3-small"
EMBEDDING_DIMENSIONS = 1536

Quality = Literal["fast", "smart"]

# USD per 1M tokens — used for run cost accounting.
_PRICES: dict[str, dict[str, float]] = {
    "gpt-4o-mini": {"input": 0.15, "output": 0.60},
    "gpt-4o": {"input": 2.50, "output": 10.00},
    "gpt-4.1-mini": {"input": 0.40, "output": 1.60},
    "dall-e-3": {"input": 0.0, "output": 0.0},
    "claude-haiku-4-5": {"input": 1.00, "output": 5.00},
    "claude-sonnet-5": {"input": 3.00, "output": 15.00},
    "deepseek-v4-flash": {"input": 0.14, "output": 0.28},
    "deepseek-v4-pro": {"input": 0.435, "output": 0.87},
    EMBEDDING_MODEL: {"input": 0.02, "output": 0.0},
}

_client: AsyncOpenAI | None = None
_anthropic: AsyncAnthropic | None = None
_deepseek: AsyncOpenAI | None = None


def is_configured() -> bool:
    settings = get_settings()
    return bool(settings.deepseek_api_key or settings.anthropic_api_key or settings.openai_api_key)


def _get_client() -> AsyncOpenAI:
    global _client
    if _client is None:
        _client = AsyncOpenAI(api_key=get_settings().openai_api_key)
    return _client


def _get_anthropic() -> AsyncAnthropic:
    global _anthropic
    if _anthropic is None:
        _anthropic = AsyncAnthropic(api_key=get_settings().anthropic_api_key)
    return _anthropic


def _get_deepseek() -> AsyncOpenAI:
    global _deepseek
    if _deepseek is None:
        settings = get_settings()
        _deepseek = AsyncOpenAI(
            api_key=settings.deepseek_api_key,
            base_url=settings.deepseek_base_url,
        )
    return _deepseek


def _use_deepseek() -> bool:
    return bool(get_settings().deepseek_api_key)


def _use_anthropic() -> bool:
    return bool(get_settings().anthropic_api_key)


def _deepseek_model(quality: Quality) -> str:
    settings = get_settings()
    return settings.deepseek_smart_model if quality == "smart" else settings.deepseek_fast_model


def _anthropic_model(quality: Quality) -> str:
    settings = get_settings()
    return settings.anthropic_smart_model if quality == "smart" else settings.anthropic_fast_model


async def _anthropic_chat(
    system: str,
    user: str,
    usage: "UsageTracker | None",
    max_tokens: int,
    quality: Quality,
) -> str:
    model = _anthropic_model(quality)
    response = await _get_anthropic().messages.create(
        model=model,
        max_tokens=max_tokens,
        system=system,
        messages=[{"role": "user", "content": user}],
    )
    if usage:
        usage.add(model, response.usage.input_tokens, response.usage.output_tokens)
    return "".join(block.text for block in response.content if block.type == "text")


async def generate_long(
    system: str,
    user: str,
    usage: "UsageTracker | None" = None,
    max_tokens: int = 16000,
    quality: Quality = "smart",
    max_rounds: int = 4,
) -> str:
    """Generates long-form content (e.g. a full HTML page), continuing across
    turns when the model hits `max_tokens` so the result is never truncated.

    Continuation is driven by follow-up user turns (assistant prefill is not
    supported on current Claude models). Falls back to a single `chat` call on
    the OpenAI path (no continuation there — max_tokens is set high enough)."""
    if not _use_anthropic():
        return await chat(system, user, usage=usage, max_tokens=max_tokens, quality=quality)

    model = _anthropic_model(quality)
    client = _get_anthropic()
    messages: list[dict[str, Any]] = [{"role": "user", "content": user}]
    pieces: list[str] = []

    for _ in range(max_rounds):
        # Streaming is required for large max_tokens (the SDK refuses a
        # non-streaming call that could exceed the 10-minute timeout).
        async with client.messages.stream(
            model=model,
            max_tokens=max_tokens,
            system=system,
            messages=messages,
        ) as stream:
            response = await stream.get_final_message()

        if usage:
            usage.add(model, response.usage.input_tokens, response.usage.output_tokens)

        chunk = "".join(block.text for block in response.content if block.type == "text")
        pieces.append(chunk)

        if response.stop_reason != "max_tokens":
            break

        # Truncated — ask it to continue seamlessly. We echo what we have so
        # far as an assistant turn and instruct a raw continuation (no repeat,
        # no preamble). This is a normal multi-turn message, not a prefill.
        so_far = "".join(pieces)
        messages = [
            {"role": "user", "content": user},
            {"role": "assistant", "content": so_far[-4000:]},
            {
                "role": "user",
                "content": (
                    "You were cut off by the length limit. Continue the output from "
                    "EXACTLY where you stopped — output only the remaining raw content, "
                    "no repetition, no preamble, no code fences."
                ),
            },
        ]

    return "".join(pieces)


def _extract_json(content: str) -> dict[str, Any]:
    """Parses a JSON object out of model text (tolerates code fences)."""
    text = content.strip()
    fenced = re.search(r"```(?:json)?\s*(\{.*\})\s*```", text, re.DOTALL)
    if fenced:
        text = fenced.group(1)
    elif not text.startswith("{"):
        brace = re.search(r"\{.*\}", text, re.DOTALL)
        if brace:
            text = brace.group(0)
    try:
        parsed = json.loads(text)
        return parsed if isinstance(parsed, dict) else {}
    except json.JSONDecodeError:
        log.warning("llm_json_parse_failed", content=content[:200])
        return {}


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


async def _deepseek_chat(
    system: str,
    user: str,
    usage: UsageTracker | None,
    max_tokens: int,
    quality: Quality,
) -> str:
    model = _deepseek_model(quality)
    response = await _get_deepseek().chat.completions.create(
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


async def chat(
    system: str,
    user: str,
    usage: UsageTracker | None = None,
    max_tokens: int = 1500,
    quality: Quality = "fast",
) -> str:
    """Single-turn chat completion. Returns the assistant text.

    Routing: fast → DeepSeek (cheapest) → Anthropic → OpenAI.
             smart → Anthropic (highest quality) → DeepSeek → OpenAI.
    """
    if quality == "fast" and _use_deepseek():
        try:
            return await _deepseek_chat(system, user, usage, max_tokens, quality)
        except Exception as exc:
            log.warning("deepseek_chat_failed_fallback", error=str(exc))

    if _use_anthropic():
        return await _anthropic_chat(system, user, usage, max_tokens, quality)

    if quality == "smart" and _use_deepseek():
        return await _deepseek_chat(system, user, usage, max_tokens, quality)

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


async def _openai_compat_stream(
    client: AsyncOpenAI,
    model: str,
    system: str,
    user: str,
    usage: UsageTracker | None,
    max_tokens: int,
) -> AsyncIterator[str]:
    """Shared streaming impl for OpenAI-compatible APIs (OpenAI + DeepSeek)."""
    prompt_tokens = 0
    completion_tokens = 0
    stream = await client.chat.completions.create(
        model=model,
        messages=[
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ],
        max_tokens=max_tokens,
        stream=True,
        stream_options={"include_usage": True},
    )
    async for chunk in stream:
        if chunk.usage is not None:
            prompt_tokens = chunk.usage.prompt_tokens
            completion_tokens = chunk.usage.completion_tokens
        if chunk.choices and chunk.choices[0].delta.content:
            yield chunk.choices[0].delta.content
    if usage:
        usage.add(model, prompt_tokens, completion_tokens)


async def chat_stream(
    system: str,
    user: str,
    usage: UsageTracker | None = None,
    max_tokens: int = 1500,
    quality: Quality = "fast",
) -> AsyncIterator[str]:
    """Single-turn chat completion, streamed as text deltas. Used for chat
    replies so the UI can render tokens as they are produced.

    Routing mirrors ``chat``: fast→DeepSeek, smart→Anthropic."""
    if quality == "fast" and _use_deepseek():
        model = _deepseek_model(quality)
        async for delta in _openai_compat_stream(
            _get_deepseek(), model, system, user, usage, max_tokens
        ):
            yield delta
        return

    if _use_anthropic():
        model = _anthropic_model(quality)
        async with _get_anthropic().messages.stream(
            model=model,
            max_tokens=max_tokens,
            system=system,
            messages=[{"role": "user", "content": user}],
        ) as stream:
            async for delta in stream.text_stream:
                if delta:
                    yield delta
            response = await stream.get_final_message()
        if usage:
            usage.add(model, response.usage.input_tokens, response.usage.output_tokens)
        return

    model = get_settings().openai_model
    async for delta in _openai_compat_stream(
        _get_client(), model, system, user, usage, max_tokens
    ):
        yield delta


async def _openai_compat_json(
    client: AsyncOpenAI,
    model: str,
    system: str,
    user: str,
    usage: UsageTracker | None,
    max_tokens: int,
) -> dict[str, Any]:
    """JSON-mode completion via any OpenAI-compatible API."""
    response = await client.chat.completions.create(
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


async def chat_json(
    system: str,
    user: str,
    usage: UsageTracker | None = None,
    max_tokens: int = 1500,
    quality: Quality = "fast",
) -> dict[str, Any]:
    """Chat completion constrained to a JSON object response.

    Always uses Anthropic/OpenAI — DeepSeek rejects response_format /
    structured output, so routing "fast" there breaks decision points
    (chat vs task, dispatcher, image planning, memory consolidation).
    """
    if _use_anthropic():
        content = await _anthropic_chat(
            system + "\n\nRespond with a single valid JSON object and nothing else.",
            user,
            usage,
            max_tokens,
            quality,
        )
        return _extract_json(content or "{}")

    return await _openai_compat_json(
        _get_client(), get_settings().openai_model, system, user, usage, max_tokens
    )


async def chat_structured(
    system: str,
    user: str,
    schema: type,
    usage: UsageTracker | None = None,
    max_tokens: int = 1500,
    quality: Quality = "fast",
) -> Any:
    """Strongly-typed structured output (Pydantic) via LangChain's
    `with_structured_output` — provider-enforced tool calling instead of
    parsing JSON out of free text. Raises when parsing fails so callers can
    fall back explicitly.

    Anthropic/OpenAI only — DeepSeek does not support the response_format
    used by with_structured_output.
    """
    settings = get_settings()

    if _use_anthropic():
        from langchain_anthropic import ChatAnthropic

        model_name = _anthropic_model(quality)
        model = ChatAnthropic(
            model=model_name,
            api_key=settings.anthropic_api_key,
            max_tokens=max_tokens,
        )
    else:
        from langchain_openai import ChatOpenAI

        model_name = settings.openai_model
        model = ChatOpenAI(
            model=model_name,
            api_key=settings.openai_api_key,
            use_responses_api=False,
        )

    structured = model.with_structured_output(schema, include_raw=True)
    result = await structured.ainvoke([("system", system), ("human", user)])

    raw = result.get("raw")
    if usage and raw is not None and getattr(raw, "usage_metadata", None):
        meta = raw.usage_metadata
        usage.add(
            model_name,
            int(meta.get("input_tokens", 0)),
            int(meta.get("output_tokens", 0)),
        )

    parsed = result.get("parsed")
    if parsed is None:
        raise ValueError(f"structured output parse failed: {result.get('parsing_error')}")
    return parsed


async def vision(
    system: str,
    user_text: str,
    image_url: str,
    usage: UsageTracker | None = None,
    max_tokens: int = 1500,
) -> str:
    """GPT-4o vision: analyze an image with a text prompt."""
    if not get_settings().openai_api_key:
        return ""
    model = "gpt-4o"
    response = await _get_client().chat.completions.create(
        model=model,
        messages=[
            {"role": "system", "content": system},
            {"role": "user", "content": [
                {"type": "text", "text": user_text},
                {"type": "image_url", "image_url": {"url": image_url, "detail": "high"}},
            ]},
        ],
        max_tokens=max_tokens,
    )
    if usage and response.usage:
        usage.add(model, response.usage.prompt_tokens, response.usage.completion_tokens)
    return response.choices[0].message.content or ""


async def generate_image(
    prompt: str,
    usage: UsageTracker | None = None,
    size: str = "1024x1024",
) -> bytes | None:
    """Text-to-image generation with the configured image model. Returns the
    image bytes or None. (`response_format` no longer exists on this API —
    current models return b64_json, older ones a URL.)"""
    import base64

    models = [get_settings().openai_image_model, "dall-e-3"]

    for model in dict.fromkeys(models):
        try:
            response = await _get_client().images.generate(
                model=model,
                prompt=prompt,
                n=1,
                size=size,
            )
            data = response.data[0]
            if data.b64_json:
                return base64.b64decode(data.b64_json)
            if data.url:
                import httpx

                async with httpx.AsyncClient(timeout=60, follow_redirects=True) as client:
                    resp = await client.get(data.url)
                    resp.raise_for_status()
                    return resp.content
        except Exception as exc:
            log.warning("image_generation_failed", model=model, error=str(exc))

    return None


async def edit_image(
    image_bytes: bytes,
    prompt: str,
    usage: UsageTracker | None = None,
    mime_type: str = "image/png",
) -> bytes | None:
    """AI image editing: transforms the ORIGINAL image per the prompt,
    preserving its composition. Uses the configured image model
    (gpt-image-2 by default) and falls back to gpt-image-1 when the account
    doesn't have access. Returns PNG bytes or None."""
    import base64
    import io

    ext = (mime_type.split("/") + ["png"])[1]
    models = [get_settings().openai_image_model, "gpt-image-1"]

    for model in dict.fromkeys(models):
        try:
            response = await _get_client().images.edit(
                model=model,
                image=(f"image.{ext}", io.BytesIO(image_bytes), mime_type),
                prompt=prompt,
            )
            b64 = response.data[0].b64_json
            if b64:
                return base64.b64decode(b64)
        except Exception as exc:
            log.warning("image_edit_failed", model=model, error=str(exc))

    return None


async def transcribe_audio_data(
    audio_bytes: bytes,
    filename: str = "audio.mp3",
    usage: UsageTracker | None = None,
) -> str:
    """Whisper transcription from raw audio bytes."""
    import io

    response = await _get_client().audio.transcriptions.create(
        model="whisper-1",
        file=(filename, io.BytesIO(audio_bytes)),
    )
    return response.text


async def embed(texts: list[str], usage: UsageTracker | None = None) -> list[list[float]]:
    """Embeds a batch of texts with text-embedding-3-small (1536 dims)."""
    if not texts or not get_settings().openai_api_key:
        return []
    response = await _get_client().embeddings.create(model=EMBEDDING_MODEL, input=texts)
    if usage and response.usage:
        usage.add(EMBEDDING_MODEL, response.usage.prompt_tokens, 0)
    return [item.embedding for item in response.data]
