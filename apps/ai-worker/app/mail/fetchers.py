"""Provider fetchers: Gmail REST, Microsoft Graph delta, IMAP.

Each fetcher takes the account payload from Phoenix (credentials + sync
cursors) and returns `(messages, new_sync_state)` where messages use the
normalized shape from `normalize.py`. Fetchers are incremental: the cursor
in `sync_state` marks where the previous sync stopped.
"""

import asyncio
import base64
import email
import imaplib
import ipaddress
import re
import socket
import ssl
from typing import Any

import httpx
import structlog

from app.mail import normalize

log = structlog.get_logger()

GMAIL_BASE = "https://gmail.googleapis.com/gmail/v1/users/me"
GRAPH_BASE = "https://graph.microsoft.com/v1.0"

# Bound each sync so a huge backlog cannot wedge the worker.
INITIAL_LIMIT = 25
INCREMENTAL_LIMIT = 100


class AuthError(Exception):
    """Provider rejected the credentials (expired/revoked token)."""


def _bearer(credentials: dict[str, Any]) -> dict[str, str]:
    return {"authorization": f"Bearer {credentials.get('access_token', '')}"}


# ---------- Gmail ----------


async def fetch_gmail(
    credentials: dict[str, Any], sync_state: dict[str, Any]
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    headers = _bearer(credentials)
    new_state = dict(sync_state)
    history_id = sync_state.get("history_id")

    async with httpx.AsyncClient(timeout=30) as client:
        if history_id:
            params = {
                "startHistoryId": history_id,
                "historyTypes": "messageAdded",
                "labelId": "INBOX",
                "maxResults": INCREMENTAL_LIMIT,
            }
            if sync_state.get("history_page_token"):
                params["pageToken"] = sync_state["history_page_token"]
            response = await client.get(f"{GMAIL_BASE}/history", headers=headers, params=params)
            if response.status_code == 401:
                raise AuthError("Gmail authorization expired. Reconnect this mailbox.")
            if response.status_code == 404:
                history_id = None
            else:
                response.raise_for_status()
                body = response.json()
                ids = [
                    added["message"]["id"]
                    for entry in body.get("history", [])
                    for added in entry.get("messagesAdded", [])
                    if added.get("message", {}).get("id")
                ]
                message_ids = list(dict.fromkeys(ids))
                if body.get("nextPageToken"):
                    # Keep the starting history cursor until every page is saved.
                    new_state["history_page_token"] = body["nextPageToken"]
                else:
                    new_state.pop("history_page_token", None)
                    if body.get("historyId"):
                        new_state["history_id"] = str(body["historyId"])

        if not history_id:
            # Snapshot the cursor BEFORE listing messages: arrivals during the
            # initial fetch must be replayed by the next incremental request.
            snapshot_history = await _gmail_profile_history_id(client, headers)
            message_ids = await _gmail_recent_ids(client, headers)
            new_state.pop("history_page_token", None)
            if snapshot_history:
                new_state["history_id"] = snapshot_history

        messages = []
        for message_id in message_ids:
            message = await _gmail_fetch_message(client, headers, message_id)
            if message:
                messages.append(message)

    return messages, new_state


async def _gmail_recent_ids(client: httpx.AsyncClient, headers: dict) -> list[str]:
    response = await client.get(
        f"{GMAIL_BASE}/messages",
        headers=headers,
        params={"maxResults": INITIAL_LIMIT, "labelIds": "INBOX"},
    )
    if response.status_code == 401:
        raise AuthError("gmail token rejected")
    response.raise_for_status()
    return [m["id"] for m in response.json().get("messages", [])]


async def _gmail_profile_history_id(client: httpx.AsyncClient, headers: dict) -> str | None:
    response = await client.get(f"{GMAIL_BASE}/profile", headers=headers)
    if response.status_code == 401:
        raise AuthError("Gmail authorization expired. Reconnect this mailbox.")
    response.raise_for_status()
    return str(response.json().get("historyId") or "") or None


async def _gmail_fetch_message(
    client: httpx.AsyncClient, headers: dict, message_id: str
) -> dict[str, Any] | None:
    response = await client.get(
        f"{GMAIL_BASE}/messages/{message_id}", headers=headers, params={"format": "full"}
    )
    if response.status_code == 401:
        raise AuthError("gmail token rejected")
    if response.status_code == 404:
        return None  # Deleted between listing and fetch.
    response.raise_for_status()  # Never advance the cursor past a transient failure.

    body = response.json()
    payload = body.get("payload", {})
    header_map = {h.get("name", "").lower(): h.get("value", "") for h in payload.get("headers", [])}

    body_text, has_attachments = _gmail_body(payload)
    from_name, from_email = normalize.parse_address(header_map.get("from"))

    received_at = None
    if body.get("internalDate"):
        from datetime import UTC, datetime

        received_at = datetime.fromtimestamp(int(body["internalDate"]) / 1000, tz=UTC).isoformat()

    return {
        "provider_message_id": body["id"],
        "thread_id": body.get("threadId"),
        "from_name": from_name,
        "from_email": from_email,
        "to_emails": normalize.parse_address_list(header_map.get("to")),
        "cc_emails": normalize.parse_address_list(header_map.get("cc")),
        "subject": header_map.get("subject", ""),
        "snippet": normalize.snippet_of(body.get("snippet") or body_text),
        "body_text": normalize.clip(body_text),
        "folder": "inbox",
        "labels": body.get("labelIds", []),
        "has_attachments": has_attachments,
        "received_at": received_at,
    }


def _gmail_body(payload: dict[str, Any]) -> tuple[str, bool]:
    plain: list[str] = []
    html: list[str] = []
    has_attachments = False

    def walk(part: dict[str, Any]) -> None:
        nonlocal has_attachments
        if part.get("filename"):
            has_attachments = True
        data = part.get("body", {}).get("data")
        mime = part.get("mimeType", "")
        if data:
            try:
                decoded = base64.urlsafe_b64decode(data + "==").decode("utf-8", errors="replace")
            except Exception:
                decoded = ""
            if mime == "text/plain":
                plain.append(decoded)
            elif mime == "text/html":
                html.append(decoded)
        for child in part.get("parts", []):
            walk(child)

    walk(payload)

    if plain:
        return "\n".join(plain), has_attachments
    if html:
        return normalize.html_to_text("\n".join(html)), has_attachments
    return "", has_attachments


# ---------- Microsoft Graph ----------


async def fetch_graph(
    credentials: dict[str, Any], sync_state: dict[str, Any]
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    headers = {**_bearer(credentials), "Prefer": 'IdType="ImmutableId"'}
    new_state = dict(sync_state)
    url = sync_state.get("next_link") or sync_state.get("delta_link") or (
        f"{GRAPH_BASE}/me/mailFolders/inbox/messages/delta?$top={INITIAL_LIMIT}"
    )
    messages: list[dict[str, Any]] = []

    async with httpx.AsyncClient(timeout=30) as client:
        for _round in range(10):
            if not url.startswith(GRAPH_BASE + "/"):
                raise ValueError("Invalid Microsoft sync cursor")
            response = await client.get(url, headers=headers)
            if response.status_code == 401:
                raise AuthError("Microsoft authorization expired. Reconnect this mailbox.")
            if response.status_code == 410:
                new_state.pop("delta_link", None)
                new_state.pop("next_link", None)
                return [], new_state
            response.raise_for_status()
            body = response.json()
            # Finish the entire page before saving its continuation. Truncating
            # a page would permanently skip the remaining messages.
            for item in body.get("value", []):
                if not item.get("@removed") and item.get("id"):
                    messages.append(_graph_to_normalized(item))

            if body.get("@odata.deltaLink"):
                new_state["delta_link"] = body["@odata.deltaLink"]
                new_state.pop("next_link", None)
                break
            if body.get("@odata.nextLink"):
                url = body["@odata.nextLink"]
                new_state["next_link"] = url
                if len(messages) >= INCREMENTAL_LIMIT:
                    break
            else:
                raise ConnectionError("Microsoft returned no continuation cursor")

    return messages, new_state


def _graph_to_normalized(item: dict[str, Any]) -> dict[str, Any]:
    sender = item.get("from", {}).get("emailAddress", {})
    body = item.get("body", {}) or {}
    content = body.get("content", "") or ""
    body_text = normalize.html_to_text(content) if body.get("contentType") == "html" else content

    def addresses(key: str) -> list[str]:
        return [
            entry.get("emailAddress", {}).get("address", "").lower()
            for entry in item.get(key, [])
            if entry.get("emailAddress", {}).get("address")
        ]

    return {
        "provider_message_id": item["id"],
        "thread_id": item.get("conversationId"),
        "from_name": sender.get("name", ""),
        "from_email": (sender.get("address") or "").lower(),
        "to_emails": addresses("toRecipients"),
        "cc_emails": addresses("ccRecipients"),
        "subject": item.get("subject", ""),
        "snippet": normalize.snippet_of(item.get("bodyPreview") or body_text),
        "body_text": normalize.clip(body_text),
        "folder": "inbox",
        "labels": item.get("categories", []),
        "has_attachments": bool(item.get("hasAttachments")),
        "received_at": item.get("receivedDateTime"),
    }


# ---------- IMAP ----------


async def fetch_imap(
    credentials: dict[str, Any],
    settings: dict[str, Any],
    sync_state: dict[str, Any],
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    """IMAP has no async client in stdlib; run the blocking sync in a thread."""
    return await asyncio.to_thread(_fetch_imap_blocking, credentials, settings, sync_state)


def _public_socket(host: str, port: int, timeout: float) -> socket.socket:
    addresses = socket.getaddrinfo(host, port, type=socket.SOCK_STREAM)
    if not addresses or any(not ipaddress.ip_address(item[4][0]).is_global for item in addresses):
        raise ConnectionError("IMAP server must have a public internet address")
    last_error = None
    for family, socktype, proto, _, address in addresses:
        connection = socket.socket(family, socktype, proto)
        connection.settimeout(timeout)
        try:
            connection.connect(address)
            return connection
        except OSError as exc:
            connection.close()
            last_error = exc
    raise ConnectionError("Could not reach the IMAP server") from last_error


class _VerifiedIMAP4(imaplib.IMAP4):
    def _create_socket(self, timeout):
        return _public_socket(self.host, self.port, timeout)


class _VerifiedIMAP4SSL(imaplib.IMAP4_SSL):
    def _create_socket(self, timeout):
        connection = _public_socket(self.host, self.port, timeout)
        try:
            return self.ssl_context.wrap_socket(connection, server_hostname=self.host)
        except Exception:
            connection.close()
            raise


def _connect_imap(settings: dict[str, Any]):
    host = settings.get("imap_host", "")
    security = settings.get("imap_security")
    if not security:
        security = "starttls" if settings.get("imap_ssl") in (False, "false") else "tls"
    port = int(settings.get("imap_port") or (143 if security == "starttls" else 993))
    context = ssl.create_default_context()
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    if security == "tls":
        return _VerifiedIMAP4SSL(host, port, ssl_context=context, timeout=30)
    if security != "starttls":
        raise ValueError("IMAP requires TLS or STARTTLS")
    connection = _VerifiedIMAP4(host, port, timeout=30)
    try:
        connection.starttls(ssl_context=context)
    except Exception:
        connection.shutdown()
        raise
    return connection


def _fetch_imap_blocking(
    credentials: dict[str, Any],
    settings: dict[str, Any],
    sync_state: dict[str, Any],
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    try:
        connection = _connect_imap(settings)
    except ssl.SSLCertVerificationError as exc:
        raise ConnectionError("The IMAP server certificate could not be verified") from exc
    except Exception as exc:
        raise ConnectionError("Could not establish a secure IMAP connection. Check host, port and TLS settings.") from exc

    try:
        try:
            connection.login(credentials.get("username", ""), credentials.get("password", ""))
        except imaplib.IMAP4.error as exc:
            # Server responses can echo login input: never persist them in UI/logs.
            raise AuthError("IMAP login rejected. Reconnect using the correct username and app password.") from exc

        status, _ = connection.select("INBOX", readonly=True)
        if status != "OK":
            raise ConnectionError("IMAP server did not allow read access to INBOX")

        uid_next, uid_validity = _imap_status(connection)
        last_uid = int(sync_state.get("uid_next") or 0)
        previous_validity = sync_state.get("uid_validity")
        if previous_validity and str(previous_validity) != str(uid_validity):
            last_uid = 0

        if last_uid <= 0:
            uids = _imap_recent_uids(connection, INITIAL_LIMIT)
        else:
            status, search_data = connection.uid("SEARCH", None, f"UID {last_uid}:*")
            if status != "OK":
                raise ConnectionError("IMAP message search failed")
            uids = (search_data[0] or b"").split()
            uids = sorted((u for u in uids if int(u) >= last_uid), key=int)[:INCREMENTAL_LIMIT]

        messages = []
        next_cursor = last_uid
        for uid in uids:
            status, fetch_data = connection.uid("FETCH", uid, "(BODY.PEEK[])")
            if status != "OK":
                raise ConnectionError("IMAP message download failed")
            raw = next((part[1] for part in fetch_data or [] if isinstance(part, tuple)), None)
            next_cursor = int(uid) + 1
            if not raw:
                continue  # Message deleted since SEARCH; safely move past its UID.
            parsed = email.message_from_bytes(raw)
            uid_str = uid.decode() if isinstance(uid, bytes) else str(uid)
            # UIDs are unique only within a UIDVALIDITY epoch. Preserve legacy
            # IDs until a reset so existing accounts do not duplicate all mail.
            epoch_ids = sync_state.get("uid_epoch_ids", not bool(sync_state.get("uid_next")))
            if previous_validity and str(previous_validity) != str(uid_validity):
                epoch_ids = True
            provider_id = f"{uid_validity}:{uid_str}" if epoch_ids else uid_str
            messages.append(normalize.mime_to_normalized(parsed, provider_id))

        new_state = dict(sync_state)
        # Advance only past the last fetched UID, never the server's UIDNEXT
        # when a bounded batch has left newer messages waiting.
        new_state["uid_next"] = next_cursor if uids else (uid_next or last_uid)
        new_state["uid_validity"] = uid_validity
        new_state["uid_epoch_ids"] = (
            sync_state.get("uid_epoch_ids", not bool(sync_state.get("uid_next")))
            or bool(previous_validity and str(previous_validity) != str(uid_validity))
        )
        return messages, new_state
    except imaplib.IMAP4.error as exc:
        # Any server response may echo submitted credentials, even after login.
        # Keep protocol details out of the persisted account error and logs.
        raise ConnectionError("The IMAP server interrupted synchronization. Try again.") from exc
    finally:
        try:
            connection.logout()
        except Exception:
            pass


def _imap_status(connection) -> tuple[int, int]:
    status, data = connection.status("INBOX", "(UIDNEXT UIDVALIDITY)")
    if status != "OK" or not data or not data[0]:
        raise ConnectionError("IMAP mailbox status unavailable")
    text = data[0].decode() if isinstance(data[0], bytes) else str(data[0])
    uidnext = re.search(r"\bUIDNEXT\s+(\d+)", text, re.IGNORECASE)
    validity = re.search(r"\bUIDVALIDITY\s+(\d+)", text, re.IGNORECASE)
    if not uidnext or not validity:
        raise ConnectionError("IMAP server did not provide stable message identifiers")
    return int(uidnext[1]), int(validity[1])


def _imap_recent_uids(connection, limit: int) -> list[bytes]:
    status, data = connection.uid("SEARCH", None, "ALL")
    if status != "OK":
        raise ConnectionError("IMAP message search failed")
    uids = (data[0] or b"").split()
    return sorted(uids, key=int)[-limit:]
