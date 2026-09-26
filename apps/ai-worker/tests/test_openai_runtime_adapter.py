"""SDK contract tests with an in-process transport; no provider requests."""

import httpx
import pytest
from openai import AsyncOpenAI

from app.agents.openai_runtime import OpenAIAgentsAdapter


def session(session_id, creation_id=None):
    return {"id": session_id, "object": "agent.session", "status": "idle",
            "metadata": {"mokaid_creation_id": creation_id} if creation_id else {}}


async def test_find_session_uses_all_sdk_pages_and_exact_metadata():
    requests = []

    def handler(request):
        requests.append(request)
        assert request.url.path == "/v1/agents/sessions"
        assert request.method == "GET"
        if request.url.params.get("after") == "unrelated":
            return httpx.Response(200, json={"data": [session("expected", "creation-token")], "has_more": False})
        return httpx.Response(200, json={"data": [session("unrelated", "different-token")], "has_more": True})

    client = AsyncOpenAI(api_key="local-test-only", http_client=httpx.AsyncClient(transport=httpx.MockTransport(handler)))
    adapter = OpenAIAgentsAdapter(client)
    try:
        assert (await adapter.find_session("creation-token"))["id"] == "expected"
        assert len(requests) == 2
        assert requests[0].url.params["order"] == "desc"
        assert requests[0].url.params["limit"] == "100"
        assert requests[0].headers["OpenAI-Beta"] == "agents=v1"
    finally:
        await adapter.close()


@pytest.mark.parametrize("records, expected_error", [
    ([session("one", "creation-token"), session("two", "creation-token")], True),
    ([session("other", "foreign-token")], False),
])
async def test_find_session_never_selects_foreign_or_ambiguous_sessions(records, expected_error):
    client = AsyncOpenAI(api_key="local-test-only", http_client=httpx.AsyncClient(
        transport=httpx.MockTransport(lambda _request: httpx.Response(200, json={"data": records, "has_more": False}))))
    adapter = OpenAIAgentsAdapter(client)
    try:
        if expected_error:
            with pytest.raises(ValueError, match="Multiple sessions"):
                await adapter.find_session("creation-token")
        else:
            assert await adapter.find_session("creation-token") is None
    finally:
        await adapter.close()
