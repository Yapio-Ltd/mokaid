"""One provider submission per API outbox claim. Never retry an ambiguous send.

The API authorizes the account and owns durable idempotency. This module validates
again, builds MIME itself and never accepts an arbitrary sender, URL or HTML body.
"""

import asyncio
import base64
import binascii
import html
import re
import smtplib
import ssl
from email.message import EmailMessage
from email.policy import SMTP
from email.utils import formatdate
from typing import Any

import httpx

from app.mail.fetchers import _public_socket

MAX_ATTACHMENT_BYTES = 5 * 1024 * 1024
EMAIL = re.compile(
    r"[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?\.[A-Za-z]{2,63}\Z"
)
MESSAGE_ID = re.compile(r"<[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9.-]+>\Z")
TIMEOUT = 25


class InvalidMessage(ValueError):
    pass


def _header(value: Any, limit: int = 998) -> str:
    if (
        not isinstance(value, str)
        or len(value.encode("utf-8")) > limit
        or any(ord(c) < 32 or ord(c) == 127 for c in value)
    ):
        raise InvalidMessage("Invalid header")
    return value


def _address(value: Any) -> str:
    if not EMAIL.fullmatch(_header(value, 254)):
        raise InvalidMessage("Invalid address")
    return value


def _mime(account: dict, message: dict, *, include_bcc: bool = False) -> tuple[bytes, list[str]]:
    sender = _address(account.get("email_address"))
    recipients = []
    result = EmailMessage(policy=SMTP)
    result["From"] = sender
    for field in ("to", "cc", "bcc"):
        addresses = message.get(field, [])
        if not isinstance(addresses, list) or len(addresses) > 100:
            raise InvalidMessage("Invalid recipients")
        addresses = [_address(value) for value in addresses]
        recipients.extend(addresses)
        if addresses and (field != "bcc" or include_bcc):
            result[field.title()] = ", ".join(addresses)
    if not 1 <= len(recipients) <= 100:
        raise InvalidMessage("Invalid recipients")
    result["Subject"] = _header(message.get("subject", ""))
    result["Date"] = formatdate(localtime=False, usegmt=True)
    identifier = _header(message.get("message_id"), 254)
    if not MESSAGE_ID.fullmatch(identifier):
        raise InvalidMessage("Invalid message ID")
    result["Message-ID"] = identifier
    reply = message.get("in_reply_to")
    references = message.get("references", [])
    if not isinstance(references, list) or len(references) > 100:
        raise InvalidMessage("Invalid references")
    if reply:
        references = list(dict.fromkeys([*references, reply]))[-100:]
        if not MESSAGE_ID.fullmatch(_header(reply, 254)):
            raise InvalidMessage("Invalid reply")
        result["In-Reply-To"] = reply
    if references:
        if any(not MESSAGE_ID.fullmatch(_header(value, 254)) for value in references):
            raise InvalidMessage("Invalid references")
        result["References"] = " ".join(references)
    text = message.get("body_text")
    if not isinstance(text, str) or len(text.encode("utf-8")) > 200_000 or "\x00" in text:
        raise InvalidMessage("Invalid body")
    result.set_content(text)
    result.add_alternative(
        '<html><body><div style="white-space:pre-wrap">'
        + html.escape(text)
        + "</div></body></html>",
        subtype="html",
    )
    attachments = message.get("attachments", [])
    if not isinstance(attachments, list) or len(attachments) > 10:
        raise InvalidMessage("Invalid attachments")
    size = 0
    for item in attachments:
        if not isinstance(item, dict):
            raise InvalidMessage("Invalid attachment")
        filename = _header(item.get("filename"), 255)
        content_type = _header(item.get("content_type"), 255)
        encoded = item.get("content_base64")
        if (
            not filename
            or "/" in filename
            or "\\" in filename
            or not re.fullmatch(r"[A-Za-z0-9.+-]+/[A-Za-z0-9.+-]+", content_type)
        ):
            raise InvalidMessage("Invalid attachment")
        if not isinstance(encoded, str) or len(encoded) > 7_000_000:
            raise InvalidMessage("Invalid attachment")
        try:
            data = base64.b64decode(encoded, validate=True)
        except (ValueError, binascii.Error) as exc:
            raise InvalidMessage("Invalid attachment") from exc
        size += len(data)
        if size > MAX_ATTACHMENT_BYTES:
            raise InvalidMessage("Attachments too large")
        main, sub = content_type.split("/", 1)
        result.add_attachment(data, maintype=main, subtype=sub, filename=filename)
    return result.as_bytes(), list(dict.fromkeys(recipients))


class _PinnedSMTP(smtplib.SMTP):
    def _get_socket(self, host, port, timeout):
        return _public_socket(host, port, timeout)


class _PinnedSMTPSSL(smtplib.SMTP_SSL):
    def _get_socket(self, host, port, timeout):
        connection = _public_socket(host, port, timeout)
        try:
            return self.context.wrap_socket(connection, server_hostname=host)
        except Exception:
            connection.close()
            raise


def _failed(error: str) -> dict:
    return {"status": "failed", "error": error}


def _unknown() -> dict:
    return {"status": "unknown", "error": "delivery_unknown"}


def _smtp(account: dict, raw: bytes, recipients: list[str]) -> dict:
    settings = account.get("settings", {})
    credentials = account.get("credentials", {})
    host = settings.get("smtp_host")
    if not host:
        return _failed("smtp_not_configured")
    mode = settings.get("smtp_security") or (
        "starttls"
        if settings.get("smtp_ssl") in (False, "false", "0")
        or settings.get("smtp_port") in (587, "587")
        else "tls"
    )
    if mode not in ("tls", "starttls"):
        return _failed("smtp_tls_failed")
    username = (
        credentials.get("smtp_username") or credentials.get("username") or account["email_address"]
    )
    password = credentials.get("smtp_password") or credentials.get("password")
    if (
        not isinstance(username, str)
        or not isinstance(password, str)
        or not username
        or not password
    ):
        return _failed("authentication_required")
    context = ssl.create_default_context()
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    connection = None
    data_started = False
    accepted = False
    try:
        port = int(settings.get("smtp_port") or (465 if mode == "tls" else 587))
        if (
            not isinstance(host, str)
            or not re.fullmatch(r"[A-Za-z0-9.-]+", host)
            or not 1 <= port <= 65535
        ):
            return _failed("smtp_connection_failed")
        if mode == "tls":
            connection = _PinnedSMTPSSL(host, port, timeout=TIMEOUT, context=context)
        else:
            connection = _PinnedSMTP(host, port, timeout=TIMEOUT)
            connection.ehlo()
            # smtplib refuses unsupported STARTTLS; credentials follow only after verification.
            connection.starttls(context=context)
        connection.ehlo()
        connection.login(username, password)
        code, _ = connection.mail(account["email_address"])
        if code != 250:
            return _failed("provider_rejected")
        for address in recipients:
            code, _ = connection.rcpt(address)
            if code not in (250, 251):
                connection.rset()
                return _failed("recipients_rejected")
        # The server may accept DATA then drop the connection before its reply.
        data_started = True
        code, _ = connection.data(raw)
        if code != 250:
            return _failed("provider_rejected")
        accepted = True
        return {"status": "sent"}
    except smtplib.SMTPDataError:
        return _failed("provider_rejected")
    except smtplib.SMTPAuthenticationError:
        return _failed("authentication_required")
    except (ssl.SSLError, smtplib.SMTPNotSupportedError):
        return _unknown() if data_started else _failed("smtp_tls_failed")
    except (OSError, smtplib.SMTPException, ValueError, TypeError):
        return _unknown() if data_started else _failed("smtp_connection_failed")
    finally:
        if connection is not None:
            # QUIT failure cannot undo acceptance, and must never trigger another send.
            try:
                if accepted:
                    connection.quit()
                else:
                    connection.close()
            except (OSError, smtplib.SMTPException):
                try:
                    connection.close()
                except (OSError, smtplib.SMTPException):
                    pass


async def _oauth(account: dict, message: dict, raw: bytes) -> dict:
    credentials = account.get("credentials", {})
    token = credentials.get("access_token")
    if not isinstance(token, str) or not token or any(ord(c) < 32 for c in token):
        return _failed("authentication_required")
    scopes = set(str(credentials.get("scope", "")).split())
    headers = {"Authorization": f"Bearer {token}"}
    if account["provider"] == "gmail":
        if not scopes.intersection(
            {
                "https://www.googleapis.com/auth/gmail.modify",
                "https://www.googleapis.com/auth/gmail.send",
                "https://mail.google.com/",
            }
        ):
            return _failed("permission_required")
        url = "https://gmail.googleapis.com/gmail/v1/users/me/messages/send"
        payload = {"raw": base64.urlsafe_b64encode(raw).decode("ascii")}
        if message.get("thread_id"):
            payload["threadId"] = message["thread_id"]
        kwargs = {"json": payload}
    else:
        if not scopes.intersection({"Mail.Send", "https://graph.microsoft.com/Mail.Send"}):
            return _failed("permission_required")
        url = "https://graph.microsoft.com/v1.0/me/sendMail"
        headers["Content-Type"] = "text/plain"
        kwargs = {"content": base64.b64encode(raw)}
    try:
        # HTTP transport default has no retries. Do not follow a redirect with the token.
        async with httpx.AsyncClient(timeout=TIMEOUT, follow_redirects=False) as client:
            response = await client.post(url, headers=headers, **kwargs)
        if response.status_code == 401:
            return _failed("authentication_required")
        if response.status_code == 403:
            return _failed("permission_required")
        if 400 <= response.status_code < 500:
            return _failed("provider_rejected")
        if not 200 <= response.status_code < 300:
            return _unknown()
        if account["provider"] == "gmail":
            try:
                body = response.json()
                return {
                    "status": "sent",
                    "provider_message_id": str(body["id"]),
                    "thread_id": body.get("threadId"),
                }
            except (ValueError, KeyError, TypeError):
                # A successful status is already an acknowledgement even without its metadata.
                return {"status": "sent"}
        return {"status": "sent"}
    except (httpx.HTTPError, ValueError, TypeError):
        return _unknown()


async def send(account: dict[str, Any], message: dict[str, Any]) -> dict[str, Any]:
    """Return sent (accepted by provider), failed (not accepted), or unknown."""
    try:
        provider = account.get("provider")
        if provider not in ("gmail", "microsoft", "imap"):
            return _failed("invalid_message")
        # OAuth APIs derive envelope recipients from MIME; SMTP uses a separate
        # envelope so Bcc is omitted from bytes delivered to recipients.
        raw, recipients = _mime(account, message, include_bcc=provider != "imap")
        if provider == "imap":
            return await asyncio.to_thread(_smtp, account, raw, recipients)
        return await _oauth(account, message, raw)
    except (InvalidMessage, KeyError, TypeError, ValueError, UnicodeError):
        return _failed("invalid_message")
