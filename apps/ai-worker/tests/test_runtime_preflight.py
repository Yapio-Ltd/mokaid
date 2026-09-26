"""Preflight must never create a provider session or reveal credentials."""

import json
from types import SimpleNamespace
from unittest.mock import AsyncMock

from app.agents.preflight import SDK_VERSION, check_readiness
from app.config import Settings


def config(**overrides):
    return Settings(_env_file=None, **{"database_url": "postgresql://user:db-secret@localhost/test",
        "openai_api_key": "api-secret", "openai_agents_webhook_secret": "webhook-secret",
        "worker_auth_token": "worker-secret", **overrides})


def client():
    artifacts = SimpleNamespace(list=AsyncMock(), with_streaming_response=SimpleNamespace(content=AsyncMock()))
    sessions = SimpleNamespace(create=AsyncMock(), retrieve=AsyncMock(), delete=AsyncMock(), list=AsyncMock(),
        events=SimpleNamespace(create=AsyncMock()), items=SimpleNamespace(list=AsyncMock()),
        turns=SimpleNamespace(list=AsyncMock()), artifacts=artifacts)
    return SimpleNamespace(beta=SimpleNamespace(agents=SimpleNamespace(sessions=sessions)),
                           models=SimpleNamespace(retrieve=AsyncMock()), webhooks=SimpleNamespace(unwrap=lambda: None))


async def test_offline_preflight_never_calls_remote_and_does_not_enable_feature():
    sdk = client()
    report = await check_readiness(settings=config(), client=sdk, sdk_version=SDK_VERSION)
    assert report["ready"] and not report["deployment_enabled"] and not report["activation_changed"]
    assert report["mode"] == "offline" and not report["model_execution_verified"]
    sdk.beta.agents.sessions.list.assert_not_called()
    sdk.beta.agents.sessions.create.assert_not_called()
    sdk.models.retrieve.assert_not_called()
    assert all(secret not in json.dumps(report) for secret in ("db-secret", "api-secret", "webhook-secret", "worker-secret"))


async def test_missing_durable_configuration_and_unknown_prices_block_readiness():
    report = await check_readiness(settings=config(database_url="", openai_agents_standard_model="unverified-model",
                                                    openai_agents_webhook_secret=""), client=client(), sdk_version="older")
    failed = {check["name"] for check in report["checks"] if check["status"] == "fail"}
    assert {"durable_database", "priced_models", "webhook_secret", "sdk_version"} <= failed
    assert not report["ready"]


async def test_sdk_missing_agents_surface_is_explicit():
    sdk = client()
    sdk.beta.agents.sessions.artifacts = None
    report = await check_readiness(settings=config(), client=sdk, sdk_version=SDK_VERSION)
    assert not report["ready"]
    assert any(check["name"] == "agents_sdk_surface" and check["status"] == "fail" for check in report["checks"])


async def test_remote_mode_reads_access_without_creating_or_deleting_sessions():
    sdk = client()
    report = await check_readiness(settings=config(), client=sdk, sdk_version=SDK_VERSION, remote=True)
    assert report["ready"] and report["mode"] == "remote_read_only"
    sdk.beta.agents.sessions.list.assert_awaited_once_with(limit=1)
    assert sdk.models.retrieve.await_count == 2
    sdk.beta.agents.sessions.create.assert_not_called()
    sdk.beta.agents.sessions.delete.assert_not_called()
    sdk.beta.agents.sessions.events.create.assert_not_called()


async def test_remote_denial_does_not_expose_error_body_or_invent_readiness():
    sdk = client()
    sdk.beta.agents.sessions.list.side_effect = PermissionError("api-secret belongs to secret-workspace")
    report = await check_readiness(settings=config(), client=sdk, sdk_version=SDK_VERSION, remote=True)
    assert not report["ready"]
    assert "api-secret" not in json.dumps(report)
    assert "secret-workspace" not in json.dumps(report)
    sdk.models.retrieve.assert_not_called()
