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

    async with httpx.AsyncClient(timeout=30) as client:
        message_ids, next_history_id = await _gmail_new_message_ids(
            client, headers, sync_state.get("history_id")
        )

        messages = []
        for message_id in message_ids:
            message = await _gmail_fetch_message(client, headers, message_id)
            if message:
                messages.append(message)

        if next_history_id is None:
            next_history_id = await _gmail_profile_history_id(client, headers)

    new_state = dict(sync_state)
    if next_history_id:
        new_state["history_id"] = str(next_history_id)
    return messages, new_state


async def _gmail_new_message_ids(
    client: httpx.AsyncClient, headers: dict, history_id: str | None
) -> tuple[list[str], str | None]:
    if history_id:
        response = await client.get(
            f"{GMAIL_BASE}/history",
            headers=headers,
            params={
                "startHistoryId": history_id,
                "historyTypes": "messageAdded",
                "maxResults": INCREMENTAL_LIMIT,
            },
        )
        if response.status_code == 401:
            raise AuthError("gmail token rejected")
        if response.status_code == 404:
            # historyId too old — fall back to a recent snapshot.
            return await _gmail_recent_ids(client, headers), None
        response.raise_for_status()
        body = response.json()

        ids: list[str] = []
        for entry in body.get("history", []):
            for added in entry.get("messagesAdded", []):
                message = added.get("message", {})
                labels = message.get("labelIds", [])
                if "DRAFT" not in labels and "SENT" not in labels and message.get("id"):
                    ids.append(message["id"])
        # Dedupe, keep order.
        seen: set[str] = set()
        unique = [i for i in ids if not (i in seen or seen.add(i))]
        return unique[:INCREMENTAL_LIMIT], body.get("historyId")

    return await _gmail_recent_ids(client, headers), None


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
    if response.status_code != 200:
        return None
    return str(response.json().get("historyId") or "") or None


async def _gmail_fetch_message(
    client: httpx.AsyncClient, headers: dict, message_id: str
) -> dict[str, Any] | None:
    response = await client.get(
        f"{GMAIL_BASE}/messages/{message_id}", headers=headers, params={"format": "full"}
    )
    if response.status_code == 401:
        raise AuthError("gmail token rejected")
    if response.status_code != 200:
        log.warning("gmail_message_fetch_failed", id=message_id, status=response.status_code)
        return None

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
    delta_link = sync_state.get("delta_link")
    url = delta_link or (f"{GRAPH_BASE}/me/mailFolders/inbox/messages/delta?$top={INITIAL_LIMIT}")

    messages: list[dict[str, Any]] = []
    new_delta_link = None

    async with httpx.AsyncClient(timeout=30) as client:
        for _round in range(10):
            response = await client.get(url, headers=headers)
            if response.status_code == 401:
                raise AuthError("graph token rejected")
            if response.status_code == 410:
                # Delta token expired — restart from scratch next sync.
                state = dict(sync_state)
                state.pop("delta_link", None)
                return [], state
            response.raise_for_status()
            body = response.json()

            for item in body.get("value", []):
                if item.get("@removed") or not item.get("id"):
                    continue
                messages.append(_graph_to_normalized(item))
                if len(messages) >= INCREMENTAL_LIMIT:
                    break

            if body.get("@odata.deltaLink"):
                new_delta_link = body["@odata.deltaLink"]
                break
            if body.get("@odata.nextLink") and len(messages) < INCREMENTAL_LIMIT:
                url = body["@odata.nextLink"]
            else:
                break

    new_state = dict(sync_state)
    if new_delta_link:
        new_state["delta_link"] = new_delta_link
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


def _fetch_imap_blocking(
    credentials: dict[str, Any],
    settings: dict[str, Any],
    sync_state: dict[str, Any],
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    host = settings.get("imap_host", "")
    port = int(settings.get("imap_port") or 993)
    username = credentials.get("username", "")
    password = credentials.get("password", "")

    try:
        connection = imaplib.IMAP4_SSL(host, port, timeout=30)
    except Exception as exc:
        raise ConnectionError(f"imap connect failed: {exc}") from exc

    try:
        try:
            connection.login(username, password)
        except imaplib.IMAP4.error as exc:
            raise AuthError(f"imap login failed: {exc}") from exc

        status, data = connection.select("INBOX", readonly=True)
        if status != "OK":
            raise ConnectionError("imap select INBOX failed")

        uid_next = _imap_uidnext(connection)
        last_uid = int(sync_state.get("uid_next") or 0)

        if last_uid <= 0:
            # First sync: take the most recent messages only.
            uids = _imap_recent_uids(connection, INITIAL_LIMIT)
        else:
            status, search_data = connection.uid("SEARCH", None, f"UID {last_uid}:*")
            uids = (search_data[0] or b"").split() if status == "OK" else []
            # UID n:* always matches at least the last message — filter it.
            uids = [u for u in uids if int(u) >= last_uid][:INCREMENTAL_LIMIT]

        messages = []
        for uid in uids:
            status, fetch_data = connection.uid("FETCH", uid, "(RFC822)")
            if status != "OK" or not fetch_data or fetch_data[0] is None:
                continue
            raw = fetch_data[0][1] if isinstance(fetch_data[0], tuple) else None
            if not raw:
                continue
            parsed = email.message_from_bytes(raw)
            uid_str = uid.decode() if isinstance(uid, bytes) else str(uid)
            messages.append(normalize.mime_to_normalized(parsed, uid_str))

        new_state = dict(sync_state)
        if uid_next:
            new_state["uid_next"] = uid_next
        return messages, new_state
    finally:
        try:
            connection.logout()
        except Exception:
            pass


def _imap_uidnext(connection: imaplib.IMAP4_SSL) -> int | None:
    status, data = connection.status("INBOX", "(UIDNEXT)")
    if status != "OK" or not data:
        return None
    text = data[0].decode() if isinstance(data[0], bytes) else str(data[0])
    if "UIDNEXT" in text:
        try:
            return int(text.split("UIDNEXT")[1].strip(" ()").split()[0])
        except (ValueError, IndexError):
            return None
    return None


def _imap_recent_uids(connection: imaplib.IMAP4_SSL, limit: int) -> list[bytes]:
    status, data = connection.uid("SEARCH", None, "ALL")
    if status != "OK":
        return []
    uids = (data[0] or b"").split()
    return uids[-limit:]
