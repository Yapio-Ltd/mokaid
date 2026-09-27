"""HTTP gateway contracts: no provider traffic or real messages."""

from types import SimpleNamespace
from unittest.mock import AsyncMock

import httpx
import pytest

from app import main


@pytest.fixture
async def client(monkeypatch):
    monkeypatch.setattr(
        main, "get_settings", lambda: SimpleNamespace(worker_auth_token="mail-test-secret")
    )
    async with httpx.AsyncClient(
        transport=httpx.ASGITransport(app=main.app), base_url="http://worker"
    ) as connection:
        yield connection


@pytest.mark.parametrize(
    "path", ["/mail/send", "/mail/message/action", "/mail/attachment", "/mail/message/detail"]
)
@pytest.mark.parametrize("authorization", [None, "Bearer wrong-service"])
async def test_mail_gateway_requires_service_auth_before_provider_access(
    client, path, authorization
):
    response = await client.post(
        path,
        json={"account": {"credentials": {"access_token": "must-not-be-returned"}}},
        headers={"authorization": authorization} if authorization else {},
    )
    assert response.status_code == 401
    assert response.json() == {"detail": "invalid worker token"}
    assert "must-not-be-returned" not in response.text


async def test_send_gateway_waits_for_provider_outcome(client, monkeypatch):
    from app.mail import outbound

    send = AsyncMock(return_value={"status": "unknown", "error": "delivery_unconfirmed"})
    monkeypatch.setattr(outbound, "send", send)
    body = {"account": {"id": "mailbox"}, "message": {"subject": "fixture"}}
    response = await client.post(
        "/mail/send", json=body, headers={"authorization": "Bearer mail-test-secret"}
    )
    assert response.status_code == 200
    assert response.json() == {"status": "unknown", "error": "delivery_unconfirmed"}
    send.assert_awaited_once_with(body["account"], body["message"])


@pytest.mark.parametrize(
    ("path", "operation"),
    [
        ("/mail/message/action", "message_action"),
        ("/mail/attachment", "download_attachment"),
        ("/mail/message/detail", "hydrate_message"),
    ],
)
async def test_read_and_action_gateway_returns_scoped_operation_result(
    client, monkeypatch, path, operation
):
    from app.mail import operations

    action = AsyncMock(return_value={"status": "ok"})
    monkeypatch.setattr(operations, operation, action)
    body = {"account": {"id": "mailbox"}, "message_id": "message"}
    response = await client.post(
        path, json=body, headers={"authorization": "Bearer mail-test-secret"}
    )
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}
    action.assert_awaited_once_with(body)
