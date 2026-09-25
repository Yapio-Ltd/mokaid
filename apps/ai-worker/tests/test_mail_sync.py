"""Mail transport and cursor regressions: no dropped mail or unverified TLS."""

import imaplib
import ssl
from unittest.mock import AsyncMock, Mock

import httpx
import pytest
import respx

from app.mail import fetchers, sync


class FakeImap:
    def __init__(self, uids, *, validity=7, uidnext=None, fail_fetch=None):
        self.uids = uids
        self.validity = validity
        self.uidnext = uidnext or (max(uids, default=0) + 1)
        self.fail_fetch = fail_fetch
        self.calls = []

    def login(self, user, password):
        self.calls.append(("login", user))
        return "OK", []

    def select(self, mailbox, readonly):
        assert readonly is True
        return "OK", [b"1"]

    def status(self, mailbox, fields):
        return "OK", [f'"INBOX" (UIDNEXT {self.uidnext} UIDVALIDITY {self.validity})'.encode()]

    def uid(self, command, *args):
        self.calls.append((command, *args))
        if command == "SEARCH":
            return "OK", [b" ".join(str(uid).encode() for uid in self.uids)]
        if int(args[0]) == self.fail_fetch:
            return "NO", []
        return "OK", [(b"FETCH", b"Subject: Hello\r\nFrom: a@example.com\r\n\r\nbody")]

    def logout(self):
        self.calls.append(("logout",))


def test_imap_batch_cursor_does_not_skip_remaining_messages(monkeypatch):
    connection = FakeImap(list(range(1, 151)))
    monkeypatch.setattr(fetchers, "_connect_imap", lambda _: connection)
    messages, state = fetchers._fetch_imap_blocking({}, {}, {"uid_next": 1, "uid_validity": 7})
    assert len(messages) == 100
    assert state["uid_next"] == 101
    messages, state = fetchers._fetch_imap_blocking({}, {}, state)
    assert len(messages) == 50
    assert state["uid_next"] == 151
    assert all(call[2] == "(BODY.PEEK[])" for call in connection.calls if call[0] == "FETCH")


def test_uidvalidity_reset_restarts_and_disambiguates_ids(monkeypatch):
    connection = FakeImap([1, 2, 3], validity=8)
    monkeypatch.setattr(fetchers, "_connect_imap", lambda _: connection)
    messages, state = fetchers._fetch_imap_blocking({}, {}, {"uid_next": 999, "uid_validity": 7})
    assert state["uid_next"] == 4
    assert state["uid_validity"] == 8
    assert messages[0]["provider_message_id"] == "8:1"


def test_failed_imap_fetch_does_not_return_a_new_cursor(monkeypatch):
    connection = FakeImap([1, 2], fail_fetch=2)
    monkeypatch.setattr(fetchers, "_connect_imap", lambda _: connection)
    with pytest.raises(ConnectionError, match="download failed"):
        fetchers._fetch_imap_blocking({}, {}, {"uid_next": 1, "uid_validity": 7})
    assert connection.calls[-1] == ("logout",)


@pytest.mark.parametrize("operation", ["select", "status", "uid"])
def test_post_login_protocol_errors_do_not_expose_credentials(monkeypatch, operation):
    connection = FakeImap([1])
    secret = "private-app-password"
    setattr(connection, operation, Mock(side_effect=imaplib.IMAP4.error(f"server echoed {secret}")))
    monkeypatch.setattr(fetchers, "_connect_imap", lambda _: connection)
    with pytest.raises(ConnectionError) as error:
        fetchers._fetch_imap_blocking({"username": "me", "password": secret}, {}, {})
    assert secret not in str(error.value)
    assert "interrupted synchronization" in str(error.value)


@pytest.mark.parametrize("security", ["tls", "starttls"])
def test_imap_verifies_certificate_and_hostname(monkeypatch, security):
    implicit = Mock()
    explicit = Mock()
    monkeypatch.setattr(fetchers, "_VerifiedIMAP4SSL", implicit)
    monkeypatch.setattr(fetchers, "_VerifiedIMAP4", explicit)
    fetchers._connect_imap({"imap_host": "imap.example.com", "imap_security": security})
    if security == "tls":
        context = implicit.call_args.kwargs["ssl_context"]
        assert implicit.call_args.args == ("imap.example.com", 993)
    else:
        context = explicit.return_value.starttls.call_args.kwargs["ssl_context"]
        assert explicit.call_args.args == ("imap.example.com", 143)
    assert context.check_hostname is True
    assert context.verify_mode == ssl.CERT_REQUIRED
    assert context.minimum_version >= ssl.TLSVersion.TLSv1_2


def test_starttls_failure_closes_connection_without_login(monkeypatch):
    explicit = Mock()
    explicit.return_value.starttls.side_effect = ssl.SSLError("certificate rejected")
    monkeypatch.setattr(fetchers, "_VerifiedIMAP4", explicit)
    with pytest.raises(ConnectionError):
        fetchers._fetch_imap_blocking(
            {"username": "me", "password": "secret"}, {"imap_security": "starttls"}, {}
        )
    explicit.return_value.login.assert_not_called()
    explicit.return_value.shutdown.assert_called_once()


def test_private_dns_destinations_are_blocked_before_socket_connect(monkeypatch):
    monkeypatch.setattr(fetchers.socket, "getaddrinfo", lambda *a, **kw: [(2, 1, 6, "", ("169.254.169.254", 993))])
    with pytest.raises(ConnectionError, match="public internet address"):
        fetchers._public_socket("mail.attacker.example", 993, 30)


@pytest.mark.asyncio
@respx.mock
async def test_gmail_history_continues_pages_without_advancing_final_cursor():
    history = respx.get(f"{fetchers.GMAIL_BASE}/history").mock(return_value=httpx.Response(200, json={
        "historyId": "900", "nextPageToken": "next-page", "history": [{"messagesAdded": [
            {"message": {"id": "m1", "threadId": "thread"}}
        ]}]
    }))
    respx.get(f"{fetchers.GMAIL_BASE}/messages/m1").respond(200, json={"id": "m1"})
    messages, state = await fetchers.fetch_gmail({}, {"history_id": "100"})
    assert len(messages) == 1
    assert history.calls[0].request.url.params["labelId"] == "INBOX"
    assert state == {"history_id": "100", "history_page_token": "next-page"}
    history.respond(200, json={"historyId": "900", "history": []})
    _, state = await fetchers.fetch_gmail({}, state)
    assert state == {"history_id": "900"}
    assert history.calls[-1].request.url.params["pageToken"] == "next-page"


@pytest.mark.asyncio
@respx.mock
async def test_gmail_initial_cursor_is_captured_before_message_listing():
    profile = respx.get(f"{fetchers.GMAIL_BASE}/profile").respond(200, json={"historyId": "100"})
    listing = respx.get(f"{fetchers.GMAIL_BASE}/messages").respond(200, json={"messages": []})
    _, state = await fetchers.fetch_gmail({}, {})
    assert respx.calls[0].request.url == profile.calls[0].request.url
    assert listing.called
    assert state["history_id"] == "100"


@pytest.mark.asyncio
@respx.mock
async def test_gmail_message_failure_does_not_drop_the_message():
    respx.get(f"{fetchers.GMAIL_BASE}/history").respond(200, json={"historyId": "900", "history": [
        {"messagesAdded": [{"message": {"id": "m1", "threadId": "thread"}}]}
    ]})
    respx.get(f"{fetchers.GMAIL_BASE}/messages/m1").respond(503)
    with pytest.raises(httpx.HTTPStatusError):
        await fetchers.fetch_gmail({}, {"history_id": "100"})


@pytest.mark.asyncio
@respx.mock
async def test_graph_saves_next_link_at_batch_boundary():
    next_url = f"{fetchers.GRAPH_BASE}/me/mailFolders/inbox/messages/delta?skip=next"
    respx.get(f"{fetchers.GRAPH_BASE}/me/mailFolders/inbox/messages/delta").respond(200, json={
        "value": [{"id": str(i)} for i in range(101)], "@odata.nextLink": next_url
    })
    messages, state = await fetchers.fetch_graph({}, {})
    assert len(messages) == 101
    assert state["next_link"] == next_url


@pytest.mark.asyncio
async def test_failed_ingestion_never_advances_cursor(monkeypatch):
    phoenix = Mock()
    phoenix.ingest_mail_messages = AsyncMock(return_value=False)
    phoenix.update_mail_sync_state = AsyncMock(return_value=True)
    monkeypatch.setattr(sync, "PhoenixClient", lambda: phoenix)
    monkeypatch.setattr(sync, "_fetch", AsyncMock(return_value=([{"subject": "Hello"}], {"uid_next": 42})))
    monkeypatch.setattr(sync.analyze, "analyze_messages", AsyncMock())
    result = await sync.sync_account({"account": {"id": "account-id"}})
    assert result == {"error": "ingestion_failed"}
    phoenix.update_mail_sync_state.assert_not_called()


@pytest.mark.asyncio
async def test_failed_cursor_persistence_is_not_reported_as_success(monkeypatch):
    phoenix = Mock()
    phoenix.update_mail_sync_state = AsyncMock(return_value=False)
    monkeypatch.setattr(sync, "PhoenixClient", lambda: phoenix)
    monkeypatch.setattr(sync, "_fetch", AsyncMock(return_value=([], {"uid_next": 42})))
    result = await sync.sync_account({"account": {"id": "account-id"}})
    assert result == {"error": "sync_state_failed"}
