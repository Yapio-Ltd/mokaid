"""Confirm stopped provider execution before accounting or session replacement.

A successful cancel POST acknowledges an input event, not a terminal turn.
The caller must retain the reservation and retry when confirmation is absent.
"""

from __future__ import annotations

import asyncio
import time
from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from typing import Any

SESSION_STOPPED = frozenset({"idle", "failed"})
TURN_TERMINAL = frozenset({"completed", "failed", "cancelled"})


@dataclass(frozen=True)
class CancellationResult:
    session: dict[str, Any]
    turns: list[dict[str, Any]]


class CancellationUnconfirmed(RuntimeError):
    """Cancellation is pending; do not settle, delete, or start a replacement."""

    def __init__(
        self,
        session_id: str,
        *,
        session: dict[str, Any] | None = None,
        turns: list[dict[str, Any]] | None = None,
        error_type: str | None = None,
    ) -> None:
        super().__init__(
            "Provider cancellation is not confirmed; preserve the reservation and retry."
        )
        self.session_id = session_id
        self.session = session
        self.turns = turns
        self.error_type = error_type


async def cancel_and_confirm(
    adapter: Any,
    session_id: str,
    *,
    observe: Callable[[], Awaitable[tuple[dict[str, Any], Any]]] | None = None,
    timeout_seconds: float = 20,
    poll_seconds: float = 0.25,
) -> CancellationResult:
    """Cancel and poll canonical session/turn resources within one deadline.

    The optional observer is normally ``engine.observe`` and durably captures
    current usage/evidence. No missing/unknown status is considered terminal.
    Every turn is checked, including subagents and turns queued behind the
    active one. A newly active turn triggers another explicit cancel event.
    No mutation other than cancel is sent to the provider.
    """
    if not session_id or timeout_seconds <= 0 or poll_seconds < 0:
        raise ValueError("Cancellation requires a session ID and positive deadline")
    last_session: dict[str, Any] | None = None
    last_turns: list[dict[str, Any]] | None = None
    last_error: str | None = None
    last_cancel = 0.0

    async def send_cancel() -> None:
        nonlocal last_cancel, last_error
        last_cancel = time.monotonic()
        try:
            await adapter.cancel(session_id)
        except Exception as exc:
            # The response can be lost after acceptance. Only a later canonical
            # stopped state can establish success; the error body is not logged.
            last_error = type(exc).__name__

    try:
        async with asyncio.timeout(timeout_seconds):
            await send_cancel()
            while True:
                try:
                    if observe is not None:
                        last_session, _ = await observe()
                    else:
                        last_session = await adapter.retrieve(session_id)
                    last_turns = await adapter.turns(session_id)
                    if not isinstance(last_session, dict) or not isinstance(last_turns, list):
                        raise ValueError("Invalid provider cancellation snapshot")
                    if (
                        last_session.get("status") in SESSION_STOPPED
                        and not last_session.get("required_actions")
                        and all(
                            isinstance(turn, dict) and turn.get("status") in TURN_TERMINAL
                            for turn in last_turns
                        )
                    ):
                        return CancellationResult(last_session, last_turns)
                    # Cancel targets the active turn, so a queued successor may
                    # require its own event. A lost cancel must also be safe to
                    # retry. Reissue at most once per second until confirmed.
                    if time.monotonic() - last_cancel >= 1:
                        await send_cancel()
                except Exception as exc:
                    last_error = type(exc).__name__
                await asyncio.sleep(poll_seconds)
    except TimeoutError as exc:
        raise CancellationUnconfirmed(
            session_id, session=last_session, turns=last_turns, error_type=last_error
        ) from exc
