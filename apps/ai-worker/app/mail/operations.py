"""Workspace-bound provider reads, soft moves and flags. Never purge messages."""

import asyncio
import base64
import email
import json
import re
from typing import Any, cast
from urllib.parse import parse_qsl, quote, unquote, urlsplit

import httpx

from app.mail import fetchers, normalize

MAX_ATTACHMENT = 20 * 1024 * 1024
MAX_MIME = 30 * 1024 * 1024


class OperationError(Exception):
    def __init__(self, code: str) -> None:
        self.code = code
        super().__init__(code)


def _bound(payload: dict[str, Any]) -> tuple[dict[str, Any], dict[str, Any]]:
    account, message = payload.get("account") or {}, payload.get("message") or {}
    if (
        not account.get("id")
        or message.get("mail_account_id") != account["id"]
        or message.get("workspace_id") != account.get("workspace_id")
        or not account.get("workspace_id")
    ):
        raise OperationError("invalid_request")
    if account.get("provider") not in {"gmail", "microsoft", "imap"}:
        raise OperationError("invalid_request")
    return account, message


def _id(value: Any) -> str:
    if (
        not isinstance(value, str)
        or not value
        or len(value) > 4096
        or value in {".", ".."}
        or any(ord(c) < 32 for c in value)
    ):
        raise OperationError("invalid_request")
    return quote(value, safe="")


async def _http(
    account: dict[str, Any],
    method: str,
    path: str,
    *,
    body: dict[str, Any] | None = None,
    params: dict[str, Any] | None = None,
    binary: bool = False,
) -> Any:
    base = fetchers.GMAIL_BASE if account["provider"] == "gmail" else fetchers.GRAPH_BASE + "/me"
    token = (account.get("credentials") or {}).get("access_token")
    if not isinstance(token, str) or not token or any(ord(c) < 32 for c in token):
        raise OperationError("auth_failed")
    headers = {"authorization": "Bearer " + token, "Prefer": 'IdType="ImmutableId"'}
    maximum = MAX_ATTACHMENT if binary else MAX_MIME
    async with httpx.AsyncClient(
        timeout=httpx.Timeout(45, connect=10), follow_redirects=False
    ) as client:
        async with client.stream(
            method, base + path, headers=headers, params=params, json=body
        ) as response:
            if response.status_code in {401, 403}:
                raise OperationError("auth_failed")
            if response.status_code == 410:
                raise OperationError("cursor_expired")
            if response.status_code == 404:
                raise OperationError("not_found")
            if not 200 <= response.status_code < 300:
                raise OperationError("provider_unavailable")
            data = bytearray()
            async for chunk in response.aiter_bytes():
                data.extend(chunk)
                if len(data) > maximum:
                    raise OperationError("attachment_too_large")
    if binary:
        return bytes(data)
    return json.loads(data) if data else {}


async def _hydrate(account: dict[str, Any], message: dict[str, Any]) -> dict[str, Any]:
    if account["provider"] == "gmail":
        data = await _http(
            account,
            "GET",
            "/messages/" + _id(message["provider_message_id"]),
            params={"format": "full"},
        )
        return cast(dict[str, Any], fetchers.gmail_to_normalized(data))
    if account["provider"] == "microsoft":
        path = "/messages/" + _id(message["provider_message_id"])
        data = await _http(
            account,
            "GET",
            path,
            params={
                "$select": "id,conversationId,from,toRecipients,ccRecipients,subject,body,bodyPreview,categories,hasAttachments,receivedDateTime,isRead,flag,parentFolderId,internetMessageId,internetMessageHeaders"
            },
        )
        data["attachments"] = await graph_attachment_metadata(
            account, message["provider_message_id"]
        )
        data["_folder"] = message.get("folder", "inbox")
        return cast(dict[str, Any], fetchers._graph_to_normalized(data))
    return await asyncio.to_thread(_imap_hydrate, account, message)


async def graph_attachment_metadata(
    account: dict[str, Any], message_id: str
) -> list[dict[str, Any]]:
    path = "/messages/" + _id(message_id) + "/attachments"
    params: dict[str, Any] = {"$select": "id,name,contentType,size,isInline", "$top": 100}
    result: list[dict[str, Any]] = []
    for _page in range(10):
        data = await _http(account, "GET", path, params=params)
        result.extend(data.get("value", []))
        continuation = data.get("@odata.nextLink")
        if not continuation:
            return result
        parsed = urlsplit(continuation)
        expected_path = "/v1.0/me" + path
        if (
            parsed.scheme != "https"
            or parsed.netloc != "graph.microsoft.com"
            or unquote(parsed.path) != unquote(expected_path)
            or parsed.fragment
        ):
            raise OperationError("provider_unavailable")
        params = dict(parse_qsl(parsed.query))
    # Never mark a partial attachment manifest as completely hydrated.
    raise OperationError("provider_unavailable")


async def hydrate_message(payload: dict[str, Any]) -> dict[str, Any]:
    try:
        account, message = _bound(payload)
        return {"message": await _hydrate(account, message)}
    except OperationError as exc:
        return {"error": exc.code}
    except Exception:
        return {"error": "provider_unavailable"}


async def download_attachment(payload: dict[str, Any]) -> dict[str, Any]:
    try:
        account, message = _bound(payload)
        attachment = payload.get("attachment") or {}
        size = attachment.get("size")
        if not isinstance(size, int) or size < 0 or size > MAX_ATTACHMENT:
            raise OperationError("attachment_too_large")
        if account["provider"] == "gmail":
            if attachment.get("provider_id"):
                data = await _http(
                    account,
                    "GET",
                    "/messages/"
                    + _id(message["provider_message_id"])
                    + "/attachments/"
                    + _id(attachment["provider_id"]),
                )
                content = base64.urlsafe_b64decode(data.get("data", "") + "==")
            else:
                data = await _http(
                    account,
                    "GET",
                    "/messages/" + _id(message["provider_message_id"]),
                    params={"format": "full"},
                )
                parts = [data.get("payload", {})]
                content = None
                while parts:
                    part = parts.pop()
                    if part.get("partId") == attachment.get("part_id") and part.get(
                        "filename"
                    ) == attachment.get("filename"):
                        content = base64.urlsafe_b64decode(
                            part.get("body", {}).get("data", "") + "=="
                        )
                        break
                    parts.extend(part.get("parts", []))
                if content is None:
                    raise OperationError("not_found")
        elif account["provider"] == "microsoft":
            content = await _http(
                account,
                "GET",
                "/messages/"
                + _id(message["provider_message_id"])
                + "/attachments/"
                + _id(attachment["provider_id"])
                + "/$value",
                binary=True,
            )
        else:
            content = await asyncio.to_thread(_imap_attachment, account, message, attachment)
        if not isinstance(content, bytes):
            raise OperationError("provider_unavailable")
        if len(content) > MAX_ATTACHMENT:
            raise OperationError("attachment_too_large")
        return {"content_base64": base64.b64encode(content).decode("ascii")}
    except OperationError as exc:
        return {"error": exc.code}
    except Exception:
        return {"error": "provider_unavailable"}


async def message_action(payload: dict[str, Any]) -> dict[str, Any]:
    try:
        account, message = _bound(payload)
        action, value = payload.get("action"), payload.get("value", True)
        if action not in {"read", "star", "archive", "spam", "trash"} or not isinstance(
            value, bool
        ):
            raise OperationError("invalid_request")
        if account["provider"] == "gmail":
            changes = await _gmail_action(account, message, action, value)
        elif account["provider"] == "microsoft":
            changes = await _graph_action(account, message, action, value)
        else:
            changes = await asyncio.to_thread(_imap_action, account, message, action, value)
        return {"changes": changes}
    except OperationError as exc:
        return {"error": exc.code}
    except Exception:
        return {"error": "provider_unavailable"}


async def _gmail_action(
    account: dict[str, Any], message: dict[str, Any], action: str, value: bool
) -> dict[str, Any]:
    path = "/messages/" + _id(message["provider_message_id"])
    if action == "trash":
        data = await _http(account, "POST", path + ("/trash" if value else "/untrash"), body={})
    else:
        add: list[str] = []
        remove: list[str] = []
        if action == "read":
            (remove if value else add).append("UNREAD")
        elif action == "star":
            (add if value else remove).append("STARRED")
        elif action == "archive":
            (remove if value else add).append("INBOX")
        elif action == "spam":
            (add if value else remove).append("SPAM")
            (remove if value else add).append("INBOX")
        data = await _http(
            account, "POST", path + "/modify", body={"addLabelIds": add, "removeLabelIds": remove}
        )
    labels = data.get("labelIds")
    if not isinstance(labels, list):
        data = await _http(account, "GET", path, params={"format": "minimal"})
        labels = data.get("labelIds", [])
    return {
        "labels": labels,
        "folder": fetchers.gmail_folder(labels),
        "is_read": "UNREAD" not in labels,
        "is_starred": "STARRED" in labels,
    }


async def _graph_action(
    account: dict[str, Any], message: dict[str, Any], action: str, value: bool
) -> dict[str, Any]:
    path = "/messages/" + _id(message["provider_message_id"])
    if action == "read":
        await _http(account, "PATCH", path, body={"isRead": value})
        return {"is_read": value}
    if action == "star":
        await _http(
            account,
            "PATCH",
            path,
            body={"flag": {"flagStatus": "flagged" if value else "notFlagged"}},
        )
        return {"is_starred": value}
    destination = (
        {"archive": "archive", "spam": "junkemail", "trash": "deleteditems"}[action]
        if value
        else "inbox"
    )
    data = await _http(account, "POST", path + "/move", body={"destinationId": destination})
    return {
        "provider_message_id": data.get("id", message["provider_message_id"]),
        "folder": action if value else "inbox",
        "provider_metadata": {
            **message.get("provider_metadata", {}),
            "graph_folder_id": data.get("parentFolderId"),
        },
    }


def _imap_open(account: dict[str, Any]) -> Any:
    connection = fetchers._connect_imap(account.get("settings") or {})
    credentials = account.get("credentials") or {}
    try:
        connection.login(credentials.get("username", ""), credentials.get("password", ""))
    except Exception:
        _logout(connection)
        raise OperationError("auth_failed") from None
    return connection


def _mailbox(value: str) -> str:
    if (
        not isinstance(value, str)
        or not value
        or len(value) > 1024
        or any(ord(c) < 32 for c in value)
    ):
        raise OperationError("invalid_request")
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def _imap_location(
    connection: Any, message: dict[str, Any], readonly: bool = True
) -> tuple[str, str, str]:
    metadata = message.get("provider_metadata") or {}
    folder = metadata.get("imap_folder") or "INBOX"
    status, _ = connection.select(_mailbox(folder), readonly=readonly)
    if status != "OK":
        raise OperationError("not_found")
    status, lines = connection.status(_mailbox(folder), "(UIDVALIDITY)")
    found = re.search(
        rb"UIDVALIDITY\s+(\d+)", b" ".join(line for line in lines or [] if isinstance(line, bytes))
    )
    if status != "OK" or not found:
        raise OperationError("provider_unavailable")
    validity = found[1].decode()
    previous = metadata.get("imap_uid_validity")
    raw_id = str(message.get("provider_message_id") or "")
    uid = metadata.get("imap_uid") or raw_id.rsplit(":", 1)[-1]
    if previous is None and re.fullmatch(r"\d+:\d+", raw_id):
        previous = raw_id.split(":")[0]
    if previous and str(previous) != validity:
        raise OperationError("not_found")
    if not str(uid).isdigit():
        raise OperationError("not_found")
    return folder, str(uid), validity


def _imap_raw(connection: Any, uid: str) -> tuple[bytes, list[str]]:
    status, info = connection.uid("FETCH", uid, "(RFC822.SIZE FLAGS)")
    metadata = b" ".join(item for item in info or [] if isinstance(item, bytes))
    size = re.search(rb"RFC822.SIZE\s+(\d+)", metadata)
    if status != "OK" or not size:
        raise OperationError("not_found")
    if int(size[1]) > MAX_MIME:
        raise OperationError("attachment_too_large")
    status, parts = connection.uid("FETCH", uid, f"(BODY.PEEK[]<0.{MAX_MIME + 1}>)")
    raw = next((item[1] for item in parts or [] if isinstance(item, tuple)), None)
    if status != "OK" or raw is None:
        raise OperationError("not_found")
    if len(raw) > MAX_MIME:
        raise OperationError("attachment_too_large")
    flags = re.search(rb"FLAGS\s+\(([^)]*)\)", metadata)
    return raw, flags[1].decode(errors="replace").split() if flags else []


def _logout(connection: Any) -> None:
    try:
        connection.logout()
    except Exception:
        pass


def _imap_hydrate(account: dict[str, Any], message: dict[str, Any]) -> dict[str, Any]:
    connection = _imap_open(account)
    try:
        folder, uid, validity = _imap_location(connection, message)
        raw, flags = _imap_raw(connection, uid)
        result: dict[str, Any] = normalize.mime_to_normalized(
            email.message_from_bytes(raw), message["provider_message_id"]
        )
        result.update(
            folder=message.get("folder", "inbox"),
            is_read="\\Seen" in flags,
            is_starred="\\Flagged" in flags,
            provider_metadata={
                "reader_version": 1,
                "imap_folder": folder,
                "imap_uid": uid,
                "imap_uid_validity": validity,
            },
        )
        return result
    finally:
        _logout(connection)


def _imap_attachment(
    account: dict[str, Any], message: dict[str, Any], attachment: dict[str, Any]
) -> bytes:
    connection = _imap_open(account)
    try:
        _, uid, _ = _imap_location(connection, message)
        raw, _ = _imap_raw(connection, uid)
        parts = list(email.message_from_bytes(raw).walk())
        index = attachment.get("part_index")
        if not isinstance(index, int) or not 0 <= index < len(parts):
            raise OperationError("not_found")
        part = parts[index]
        expected = normalize.attachment_id(
            str(index) + ":" + normalize.decode_mime_header(part.get_filename())
        )
        if attachment.get("id") != expected:
            raise OperationError("not_found")
        content = part.get_payload(decode=True) or b""
        if not isinstance(content, bytes):
            raise OperationError("provider_unavailable")
        return content
    finally:
        _logout(connection)


def imap_folders(connection: Any) -> dict[str, str]:
    result = {"inbox": "INBOX"}
    status, rows = connection.list()
    if status != "OK":
        return result
    for row in rows or []:
        if not isinstance(row, bytes):
            continue
        match = re.match(rb'\(([^)]*)\)\s+(?:"[^"]*"|NIL)\s+(.+)', row)
        if not match:
            continue
        flags = match[1].decode(errors="replace").lower().split()
        name = (
            match[2]
            .decode("ascii", errors="replace")
            .strip('"')
            .replace('\\"', '"')
            .replace("\\\\", "\\")
        )
        for flag, key in [
            ("\\sent", "sent"),
            ("\\drafts", "drafts"),
            ("\\junk", "spam"),
            ("\\trash", "trash"),
            ("\\archive", "archive"),
            ("\\all", "archive"),
        ]:
            if flag in flags:
                result.setdefault(key, name)
        conventional = {
            "sent": "sent",
            "sent items": "sent",
            "drafts": "drafts",
            "spam": "spam",
            "junk": "spam",
            "trash": "trash",
            "deleted items": "trash",
            "archive": "archive",
        }
        if name.lower() in conventional:
            result.setdefault(conventional[name.lower()], name)
    return result


def _imap_action(
    account: dict[str, Any], message: dict[str, Any], action: str, value: bool
) -> dict[str, Any]:
    connection = _imap_open(account)
    try:
        folder, uid, validity = _imap_location(connection, message, readonly=False)
        if action in {"read", "star"}:
            flag = "\\Seen" if action == "read" else "\\Flagged"
            status, _ = connection.uid(
                "STORE", uid, "+FLAGS.SILENT" if value else "-FLAGS.SILENT", "(" + flag + ")"
            )
            if status != "OK":
                raise OperationError("provider_unavailable")
            return {"is_read" if action == "read" else "is_starred": value}
        target_key = action if value else "inbox"
        target = imap_folders(connection).get(target_key)
        capabilities = {
            item.decode().upper() if isinstance(item, bytes) else item.upper()
            for item in connection.capabilities
        }
        if not target or not {"MOVE", "UIDPLUS"}.issubset(capabilities):
            raise OperationError("unsupported_action")
        if folder == target:
            return {"folder": target_key}
        status, data = connection.uid("MOVE", uid, _mailbox(target))
        if status != "OK":
            raise OperationError("provider_unavailable")
        _, copy_data = connection.response("COPYUID")
        wire = b" ".join(
            item for item in (copy_data or []) + (data or []) if isinstance(item, bytes)
        )
        match = re.search(rb"(?:COPYUID\s+)?(\d+)\s+\d+\s+(\d+)", wire)
        if not match:
            # Do not invent a destination UID. This is an uncertain provider result.
            raise OperationError("provider_unavailable")
        validity, destination_uid = match[1].decode(), match[2].decode()
        return {
            "folder": target_key,
            "provider_message_id": imap_provider_id(target, validity, destination_uid),
            "provider_metadata": {
                "reader_version": (message.get("provider_metadata") or {}).get("reader_version", 0),
                "imap_folder": target,
                "imap_uid": destination_uid,
                "imap_uid_validity": validity,
            },
        }
    finally:
        _logout(connection)


def imap_provider_id(folder: str, validity: str, uid: str) -> str:
    prefix = "" if folder.upper() == "INBOX" else normalize.attachment_id(folder)[:16] + ":"
    return prefix + validity + ":" + uid
