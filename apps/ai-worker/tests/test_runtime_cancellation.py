"""Actual SDK shape and cancellation races, entirely on fake transports."""

import asyncio
import json
from unittest.mock import AsyncMock

import httpx
import pytest
from openai import AsyncOpenAI

from app.agents.openai_runtime import OpenAIAgentsAdapter
from app.agents.runtime_cancellation import CancellationUnconfirmed, cancel_and_confirm


class Adapter:
    def __init__(self, sessions, turns):
        self.snapshots = iter(sessions)
        self.turn_snapshots = iter(turns)
        self.session = sessions[-1]
        self.turn_list = turns[-1]
        self.cancel = AsyncMock()
        self.observations = 0

    async def retrieve(self, session_id):
        self.observations += 1
        self.session = next(self.snapshots, self.session)
        return self.session

    async def turns(self, session_id):
        self.turn_list = next(self.turn_snapshots, self.turn_list)
        return self.turn_list


async def test_cancel_ack_waits_for_real_turn_termination_and_uses_final_usage():
    adapter = Adapter([{"status": "in_progress", "usage": {"input_tokens": 1}},
                       {"status": "idle", "usage": {"input_tokens": 8}}],
                      [[{"id": "turn", "status": "in_progress"}], [{"id": "turn", "status": "cancelled"}]])
    observed = []

    async def observe():
        state = await adapter.retrieve("session")
        observed.append(state)
        return state, []

    result = await cancel_and_confirm(adapter, "session", observe=observe, poll_seconds=0)
    assert adapter.observations == 2 and len(observed) == 2
    assert result.session["usage"]["input_tokens"] == 8
    assert result.turns[0]["status"] == "cancelled"


@pytest.mark.parametrize("session,turns", [
    ({"status": "in_progress"}, [{"status": "cancelled"}]),
    ({"status": "requires_action"}, [{"status": "waiting"}]),
    ({"status": "idle"}, [{"status": "queued"}]),
    ({"status": "idle"}, [{"status": "in_progress", "subagent_id": "child"}]),
    ({"status": "idle"}, [{"id": "missing-status"}]),
    ({"status": "completed"}, [{"status": "completed"}]),
    ({"status": "idle", "required_actions": [{"type": "function_call"}]}, []),
])
async def test_uncertain_or_active_resources_never_confirm(session, turns):
    adapter = Adapter([session], [turns])
    with pytest.raises(CancellationUnconfirmed) as error:
        await cancel_and_confirm(adapter, "session", timeout_seconds=0.01, poll_seconds=0.002)
    assert error.value.session == session


async def test_lost_cancel_response_can_be_confirmed_by_canonical_resources():
    adapter = Adapter([{"status": "idle"}], [[{"status": "cancelled"}]])
    adapter.cancel.side_effect = RuntimeError("secret-provider-response")
    result = await cancel_and_confirm(adapter, "session")
    assert result.session["status"] == "idle"


async def test_whole_sequence_has_a_deadline_even_if_provider_hangs():
    adapter = Adapter([{"status": "idle"}], [[]])

    async def hang(*args):
        await asyncio.Event().wait()

    adapter.cancel.side_effect = hang
    with pytest.raises(CancellationUnconfirmed):
        await cancel_and_confirm(adapter, "session", timeout_seconds=0.01)


async def test_worker_shutdown_cancellation_is_not_swallowed():
    adapter = Adapter([{"status": "idle"}], [[]])
    adapter.cancel.side_effect = asyncio.CancelledError
    with pytest.raises(asyncio.CancelledError):
        await cancel_and_confirm(adapter, "session")


async def test_real_sdk_posts_expected_cancel_event_and_reads_session_and_turns_only():
    calls = []

    def handler(request):
        calls.append(request)
        assert request.headers["OpenAI-Beta"] == "agents=v1"
        if request.method == "POST":
            assert request.url.path.endswith("/agents/sessions/session/events")
            assert json.loads(request.content) == {"events": [{"type": "agent.session.input.cancel"}]}
            return httpx.Response(200, json={"data": []})
        if request.url.path.endswith("/turns"):
            return httpx.Response(200, json={"data": [{"id": "turn", "status": "cancelled", "object": "agent.session.turn"}], "has_more": False})
        return httpx.Response(200, json={"id": "session", "object": "agent.session", "status": "idle", "required_actions": []})

    client = AsyncOpenAI(api_key="offline-test", http_client=httpx.AsyncClient(transport=httpx.MockTransport(handler)))
    adapter = OpenAIAgentsAdapter(client)
    try:
        result = await cancel_and_confirm(adapter, "session")
        assert result.turns[0]["status"] == "cancelled"
        assert [request.method for request in calls] == ["POST", "GET", "GET"]
    finally:
        await adapter.close()
