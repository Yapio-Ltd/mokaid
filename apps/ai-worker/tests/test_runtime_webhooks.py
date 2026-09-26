"""Real SDK signature verification with locally signed fixtures, no API calls."""

import base64
import hashlib
import hmac
import json
import time
from types import SimpleNamespace
from unittest.mock import AsyncMock

import httpx
import pytest

from app import main, runtime_dispatch
from app.runtime_store import MemoryStore, StoreUnavailable

SECRET = b"local-test-webhook-secret"


def signed(body: dict, *, timestamp: int | None = None):
    raw = json.dumps(body, separators=(",", ":"))
    ts = str(timestamp if timestamp is not None else int(time.time()))
    webhook_id = "fixture-delivery-id"
    signature = base64.b64encode(hmac.new(SECRET, f"{webhook_id}.{ts}.{raw}".encode(), hashlib.sha256).digest()).decode()
    return raw, {"webhook-id": webhook_id, "webhook-timestamp": ts, "webhook-signature": f"v1,{signature}", "content-type": "application/json"}


@pytest.fixture
async def webhook_store(monkeypatch):
    store = MemoryStore()
    await store.accept_run({"run_id": "r", "workspace_id": "real-workspace", "task_id": "t", "input": {}})
    await store.save_execution("r", session_id="session")
    monkeypatch.setattr(main, "get_settings", lambda: SimpleNamespace(
        openai_agents_enabled=True,
        openai_agents_webhook_secret="whsec_" + base64.b64encode(SECRET).decode(),
        openai_api_key="", worker_auth_token="test-token",
    ))
    monkeypatch.setattr(main, "get_store", AsyncMock(return_value=store))
    return store


@pytest.fixture
async def client():
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=main.app), base_url="http://worker") as client:
        yield client


async def test_verified_event_is_deduplicated_and_ownership_ignores_metadata(client, webhook_store):
    body, headers = signed({"id": "event", "type": "agent.session.completed", "data": {
        "session_id": "session", "run_id": "foreign", "workspace_id": "foreign",
    }})
    first = await client.post("/webhooks/openai/agents", content=body, headers=headers)
    second = await client.post("/webhooks/openai/agents", content=body, headers=headers)
    assert first.status_code == 202 and not first.json()["duplicate"]
    assert second.status_code == 202 and second.json()["duplicate"]
    rows = await webhook_store.list_events("r")
    assert len(rows) == 1
    assert rows[0]["workspace_id"] == "real-workspace"
    assert not await webhook_store.list_events("foreign")


@pytest.mark.parametrize("stale", [False, True])
async def test_invalid_or_expired_signature_does_not_persist(client, webhook_store, stale):
    body, headers = signed({"id": "event", "type": "agent.session.completed", "data": {"session_id": "session"}},
                           timestamp=int(time.time()) - 1000 if stale else None)
    if not stale:
        body = body.replace("event", "tampered")
    result = await client.post("/webhooks/openai/agents", content=body, headers=headers)
    assert result.status_code == 400
    assert not await webhook_store.list_events("r")


async def test_unknown_session_is_retryable_without_binding_payload_identity(client, webhook_store):
    body, headers = signed({"id": "event", "type": "agent.session.completed", "data": {"session_id": "unknown", "run_id": "r"}})
    result = await client.post("/webhooks/openai/agents", content=body, headers=headers)
    assert result.status_code == 503
    assert not await webhook_store.find_session("unknown")
    assert not await webhook_store.list_events("r")


async def test_valid_webhook_is_not_acknowledged_when_storage_fails(client, webhook_store, monkeypatch):
    monkeypatch.setattr(webhook_store, "record_event", AsyncMock(side_effect=StoreUnavailable("db down")))
    body, headers = signed({"id": "event", "type": "agent.session.completed", "data": {"session_id": "session"}})
    result = await client.post("/webhooks/openai/agents", content=body, headers=headers)
    assert result.status_code == 503


async def test_http_run_does_not_acknowledge_failed_commit(client, monkeypatch):
    monkeypatch.setattr(main, "get_settings", lambda: SimpleNamespace(worker_auth_token="test-token"))
    monkeypatch.setattr(runtime_dispatch, "accept_run", AsyncMock(side_effect=StoreUnavailable("db down")))
    result = await client.post("/runs", json={"run_id": "r", "workspace_id": "w", "task_id": "t"}, headers={"authorization": "Bearer test-token"})
    assert result.status_code == 503


async def test_http_duplicate_acceptance_is_successful(client, monkeypatch):
    monkeypatch.setattr(main, "get_settings", lambda: SimpleNamespace(worker_auth_token="test-token"))
    monkeypatch.setattr(runtime_dispatch, "accept_run", AsyncMock(return_value=False))
    result = await client.post("/runs", json={"run_id": "r", "workspace_id": "w", "task_id": "t"}, headers={"authorization": "Bearer test-token"})
    assert result.status_code == 202
    assert result.json()["duplicate"] is True
