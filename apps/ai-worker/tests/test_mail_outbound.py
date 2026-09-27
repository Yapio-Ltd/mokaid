import base64
import email
import smtplib
import ssl
from email.policy import default

import httpx
import pytest

from app.mail import outbound


def account(provider="gmail"):
    return {
        "provider": provider,
        "email_address": "sender@example.com",
        "credentials": {
            "access_token": "private-token",
            "scope": "https://www.googleapis.com/auth/gmail.modify",
        },
    }


def message(**updates):
    return {
        "to": ["to@example.com"],
        "cc": ["cc@example.com"],
        "bcc": ["hidden@example.com"],
        "subject": "Bonjour été",
        "body_text": "Hello <script>alert(1)</script>",
        "message_id": "<outbox-uuid@mokaid.com>",
        "attachments": [],
        **updates,
    }


def mock_http(monkeypatch, handler):
    original = httpx.AsyncClient

    def client(**kwargs):
        assert kwargs["follow_redirects"] is False
        return original(**kwargs, transport=httpx.MockTransport(handler))

    monkeypatch.setattr(outbound.httpx, "AsyncClient", client)


async def test_gmail_actual_send_endpoint_fixed_sender_mime_reply_and_attachments(monkeypatch):
    calls = []

    def handler(request):
        import json

        calls.append(request)
        assert str(request.url) == "https://gmail.googleapis.com/gmail/v1/users/me/messages/send"
        assert request.method == "POST"
        body = json.loads(request.content)
        assert body["threadId"] == "thread-1"
        parsed = email.message_from_bytes(base64.urlsafe_b64decode(body["raw"]), policy=default)
        assert parsed["From"] == "sender@example.com"
        assert parsed["Bcc"] == "hidden@example.com"
        assert parsed["In-Reply-To"] == "<original@example.com>"
        assert parsed["References"] == "<root@example.com> <original@example.com>"
        assert "<script>" not in parsed.get_body(("html",)).get_content()
        assert "&lt;script&gt;" in parsed.get_body(("html",)).get_content()
        attachment = next(parsed.iter_attachments())
        assert attachment.get_filename() == "note.txt"
        assert attachment.get_payload(decode=True) == b"attachment"
        return httpx.Response(200, json={"id": "google-1", "threadId": "thread-1"})

    mock_http(monkeypatch, handler)
    payload = message(
        thread_id="thread-1",
        in_reply_to="<original@example.com>",
        references=["<root@example.com>"],
        attachments=[
            {
                "filename": "note.txt",
                "content_type": "text/plain",
                "content_base64": base64.b64encode(b"attachment").decode(),
            }
        ],
    )
    payload["from"] = "forged@example.com"
    payload["body_html"] = "<script>evil</script>"
    result = await outbound.send(account(), payload)
    assert result == {"status": "sent", "provider_message_id": "google-1", "thread_id": "thread-1"}
    assert len(calls) == 1


@pytest.mark.parametrize(
    "status,expected,error",
    [
        (401, "failed", "authentication_required"),
        (403, "failed", "permission_required"),
        (400, "failed", "provider_rejected"),
        (429, "failed", "provider_rejected"),
        (500, "unknown", "delivery_unknown"),
        (302, "unknown", "delivery_unknown"),
    ],
)
async def test_provider_error_sanitized_no_retry_or_redirect(monkeypatch, status, expected, error):
    calls = []

    def handler(request):
        calls.append(request)
        return httpx.Response(
            status, headers={"location": "http://127.0.0.1/secret"}, text="private-token echoed"
        )

    mock_http(monkeypatch, handler)
    result = await outbound.send(account(), message())
    assert result == {"status": expected, "error": error}
    assert len(calls) == 1


async def test_lost_provider_response_is_unknown_and_never_retried(monkeypatch):
    calls = []

    def handler(request):
        calls.append(request)
        raise httpx.ReadTimeout("private-token must never leak")

    mock_http(monkeypatch, handler)
    assert await outbound.send(account(), message()) == {
        "status": "unknown",
        "error": "delivery_unknown",
    }
    assert len(calls) == 1


async def test_graph_requires_existing_send_scope_and_acceptance_is_recorded(monkeypatch):
    graph = account("microsoft")
    assert await outbound.send(graph, message()) == {
        "status": "failed",
        "error": "permission_required",
    }
    graph["credentials"]["scope"] = "Mail.Read Mail.Send"

    def handler(request):
        assert str(request.url) == "https://graph.microsoft.com/v1.0/me/sendMail"
        assert request.headers["content-type"] == "text/plain"
        parsed = email.message_from_bytes(base64.b64decode(request.content), policy=default)
        assert parsed["From"] == "sender@example.com"
        return httpx.Response(202)

    mock_http(monkeypatch, handler)
    assert await outbound.send(graph, message()) == {"status": "sent"}


@pytest.mark.parametrize(
    "patch",
    [
        {"subject": "Hello\r\nBcc: injected@example.com"},
        {"to": ["a@example.com\nX-Test: bad"]},
        {"to": ["Name <a@example.com>"]},
        {"message_id": "bad\r\nX: bad"},
        {"in_reply_to": "bad"},
        {"references": ["bad\r\n"]},
        {"body_text": "a" * 200_001},
        {"attachments": [{}]},
        {
            "attachments": [
                {"filename": "../x", "content_type": "text/plain", "content_base64": "eA=="}
            ]
        },
        {"attachments": [{"filename": "x", "content_type": "text/plain", "content_base64": "%%%"}]},
        {
            "attachments": [
                {
                    "filename": "x",
                    "content_type": "text/plain",
                    "content_base64": base64.b64encode(b"x" * (5 * 1024 * 1024 + 1)).decode(),
                }
            ]
        },
    ],
)
async def test_invalid_input_rejected_before_any_transport(monkeypatch, patch):
    def no_network(**kwargs):
        pytest.fail("must not create HTTP transport")

    monkeypatch.setattr(outbound.httpx, "AsyncClient", no_network)
    assert await outbound.send(account(), message(**patch)) == {
        "status": "failed",
        "error": "invalid_message",
    }


class SMTPFake:
    events = []
    data_error = None
    reject_recipient = False
    tls_error = False
    quit_error = False

    def __init__(self, host, port, **kwargs):
        self.events.append(("connect", host, port, kwargs))

    def ehlo(self):
        self.events.append(("ehlo",))

    def starttls(self, context):
        self.events.append(("starttls", context))
        if self.tls_error:
            raise ssl.SSLError("private error")

    def login(self, username, password):
        self.events.append(("login", username, password))

    def mail(self, sender):
        self.events.append(("mail", sender))
        return 250, b"ok"

    def rcpt(self, recipient):
        self.events.append(("rcpt", recipient))
        return (550, b"rejected") if self.reject_recipient else (250, b"ok")

    def rset(self):
        self.events.append(("rset",))

    def data(self, raw):
        self.events.append(("data", raw))
        if self.data_error:
            raise self.data_error
        return 250, b"ok"

    def quit(self):
        self.events.append(("quit",))
        if self.quit_error:
            raise smtplib.SMTPServerDisconnected("already accepted")

    def close(self):
        self.events.append(("close",))


@pytest.fixture
def smtp(monkeypatch):
    SMTPFake.events = []
    SMTPFake.data_error = None
    SMTPFake.reject_recipient = False
    SMTPFake.tls_error = False
    SMTPFake.quit_error = False
    monkeypatch.setattr(outbound, "_PinnedSMTP", SMTPFake)
    monkeypatch.setattr(outbound, "_PinnedSMTPSSL", SMTPFake)
    result = account("imap")
    result["settings"] = {
        "smtp_host": "smtp.example.com",
        "smtp_port": 587,
        "smtp_security": "starttls",
    }
    result["credentials"] = {
        "username": "incoming",
        "password": "incoming-pw",
        "smtp_username": "outgoing",
        "smtp_password": "outgoing-pw",
    }
    return result


async def test_smtp_tls_before_login_separate_credentials_and_hidden_bcc(smtp):
    assert await outbound.send(smtp, message()) == {"status": "sent"}
    events = SMTPFake.events
    assert [event[0] for event in events].index("starttls") < [event[0] for event in events].index(
        "login"
    )
    assert ("login", "outgoing", "outgoing-pw") in events
    assert ("rcpt", "hidden@example.com") in events
    raw = next(event[1] for event in events if event[0] == "data")
    parsed = email.message_from_bytes(raw, policy=default)
    assert parsed["Bcc"] is None
    context = next(event[1] for event in events if event[0] == "starttls")
    assert context.check_hostname
    assert context.verify_mode == ssl.CERT_REQUIRED
    assert context.minimum_version == ssl.TLSVersion.TLSv1_2


async def test_starttls_rejection_never_sends_password(smtp):
    SMTPFake.tls_error = True
    assert await outbound.send(smtp, message()) == {"status": "failed", "error": "smtp_tls_failed"}
    assert not any(event[0] in ("login", "mail", "data") for event in SMTPFake.events)


async def test_any_recipient_rejected_aborts_before_data(smtp):
    SMTPFake.reject_recipient = True
    assert await outbound.send(smtp, message()) == {
        "status": "failed",
        "error": "recipients_rejected",
    }
    assert ("rset",) in SMTPFake.events
    assert not any(event[0] == "data" for event in SMTPFake.events)


async def test_data_connection_loss_is_unknown(smtp):
    SMTPFake.data_error = smtplib.SMTPServerDisconnected("accepted but lost")
    assert await outbound.send(smtp, message()) == {
        "status": "unknown",
        "error": "delivery_unknown",
    }
    assert sum(event[0] == "data" for event in SMTPFake.events) == 1


async def test_definite_data_rejection_is_failed(smtp):
    SMTPFake.data_error = smtplib.SMTPDataError(554, b"rejected")
    assert await outbound.send(smtp, message()) == {
        "status": "failed",
        "error": "provider_rejected",
    }


async def test_quit_failure_cannot_downgrade_accepted_message(smtp):
    SMTPFake.quit_error = True
    assert await outbound.send(smtp, message()) == {"status": "sent"}


def test_pinned_tls_socket_preserves_hostname_verification(monkeypatch):
    calls = []
    connection = object()
    monkeypatch.setattr(
        outbound,
        "_public_socket",
        lambda host, port, timeout: calls.append((host, port, timeout)) or connection,
    )

    class Context:
        def wrap_socket(self, actual, server_hostname):
            assert actual is connection
            assert server_hostname == "smtp.example.com"
            return "secure"

    instance = object.__new__(outbound._PinnedSMTPSSL)
    instance.context = Context()
    assert instance._get_socket("smtp.example.com", 465, 25) == "secure"
    assert calls == [("smtp.example.com", 465, 25)]
