"""Bounded synchronization of every standard mail folder, including older pages."""

import asyncio
import email
import re
from datetime import datetime
from typing import Any

from app.mail import fetchers, normalize, operations

PAGE = 25


async def fetch(account: dict[str, Any]) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    if account["provider"] == "gmail":
        return await _gmail(account)
    if account["provider"] == "microsoft":
        return await _graph(account)
    if account["provider"] == "imap":
        return await asyncio.to_thread(_imap, account)
    raise operations.OperationError("invalid_request")


async def _gmail(account: dict[str, Any]) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    state = dict(account.get("sync_state") or {})
    history = state.get("history_id") if state.get("reader_version") == 1 else None
    ids: list[str] = []
    removed: list[dict[str, Any]] = []
    added: set[str] = set()
    initial_account = not state and not account.get("last_sync_at")
    if history:
        params = {"startHistoryId": history, "maxResults": 100}
        if state.get("history_page_token"):
            params["pageToken"] = state["history_page_token"]
        try:
            body = await operations._http(account, "GET", "/history", params=params)
        except operations.OperationError as exc:
            if exc.code != "not_found":
                raise
            history = None
        else:
            for entry in body.get("history", []):
                added.update(
                    item["message"]["id"]
                    for item in entry.get("messagesAdded", [])
                    if item.get("message", {}).get("id")
                )
                removed.extend(
                    {"provider_message_id": item["message"]["id"], "_removed": True}
                    for item in entry.get("messagesDeleted", [])
                    if item.get("message", {}).get("id")
                )
                ids.extend(item["id"] for item in entry.get("messages", []) if item.get("id"))
                for key in ["messagesAdded", "labelsAdded", "labelsRemoved"]:
                    ids.extend(
                        item["message"]["id"]
                        for item in entry.get(key, [])
                        if item.get("message", {}).get("id")
                    )
            if body.get("nextPageToken"):
                state["history_page_token"] = body["nextPageToken"]
            else:
                state.pop("history_page_token", None)
                if body.get("historyId"):
                    state["history_id"] = str(body["historyId"])
    if not history or state.get("backfill_page"):
        if not history:
            profile = await operations._http(account, "GET", "/profile")
            state["history_id"] = str(profile["historyId"])
            state.pop("backfill_page", None)
            state.pop("history_page_token", None)
        params = {"maxResults": 100, "includeSpamTrash": "true"}
        if state.get("backfill_page"):
            params["pageToken"] = state["backfill_page"]
        body = await operations._http(account, "GET", "/messages", params=params)
        ids.extend(item["id"] for item in body.get("messages", []) if item.get("id"))
        state.pop("backfill_page", None)
        if body.get("nextPageToken"):
            state["backfill_page"] = body["nextPageToken"]
    messages = list(removed)
    for message_id in dict.fromkeys(ids):
        try:
            body = await operations._http(
                account, "GET", "/messages/" + operations._id(message_id), params={"format": "full"}
            )
        except operations.OperationError as exc:
            if exc.code == "not_found":
                continue
            raise
        item = fetchers.gmail_to_normalized(body)
        item["_skip_analysis"] = item["folder"] != "inbox" or not (
            message_id in added or (initial_account and len(messages) < PAGE)
        )
        messages.append(item)
    state["reader_version"] = 1
    state["reader_backfill"] = bool(state.get("backfill_page") or state.get("history_page_token"))
    return messages, state


async def _graph(account: dict[str, Any]) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    state = dict(account.get("sync_state") or {})
    folders = dict(state.get("graph_folders") or {})
    messages = []
    for folder, well_known in [
        ("inbox", "inbox"),
        ("sent", "sentitems"),
        ("drafts", "drafts"),
        ("spam", "junkemail"),
        ("trash", "deleteditems"),
        ("archive", "archive"),
    ]:
        previous = folders.get(folder) or {}
        continuation = previous.get("next") or previous.get("delta")
        path = "/mailFolders/" + well_known + "/messages/delta"
        params: dict[str, Any] = {"$top": PAGE}
        if continuation:
            # OData continuation is provider-controlled, but never forward tokens
            # outside the exact Graph host/path or to another resource.
            prefix = fetchers.GRAPH_BASE + "/me/"
            if not continuation.startswith(prefix):
                raise operations.OperationError("invalid_request")
            path, _, query = continuation[len(fetchers.GRAPH_BASE + "/me") :].partition("?")
            from urllib.parse import parse_qsl

            params = dict(parse_qsl(query))
        try:
            data = await operations._http(account, "GET", path, params=params)
        except operations.OperationError as exc:
            if exc.code == "cursor_expired" and continuation:
                data = await operations._http(
                    account,
                    "GET",
                    "/mailFolders/" + well_known + "/messages/delta",
                    params={"$top": PAGE},
                )
            elif exc.code == "not_found" and not continuation:
                continue  # Not every mailbox has an archive folder.
            else:
                raise
        for item in data.get("value", []):
            if not item.get("id"):
                continue
            if item.get("@removed"):
                messages.append(
                    {"provider_message_id": item["id"], "_removed": True, "_from_folder": folder}
                )
                continue
            item["_folder"] = folder
            if item.get("hasAttachments"):
                item["attachments"] = await operations.graph_attachment_metadata(
                    account, item["id"]
                )
            else:
                item["attachments"] = []
            normalized = fetchers._graph_to_normalized(item)
            normalized["_skip_analysis"] = folder != "inbox" or not (
                (not previous and not account.get("last_sync_at") and len(messages) < PAGE)
                or (
                    previous.get("delta")
                    and _received_after(item.get("receivedDateTime"), account.get("last_sync_at"))
                )
            )
            messages.append(normalized)
        if data.get("@odata.nextLink"):
            folders[folder] = {"next": data["@odata.nextLink"]}
        elif data.get("@odata.deltaLink"):
            folders[folder] = {"delta": data["@odata.deltaLink"]}
        else:
            raise operations.OperationError("provider_unavailable")
    state["graph_folders"] = folders
    state["reader_version"] = 1
    state["reader_backfill"] = any(item.get("next") for item in folders.values())
    return messages, state


def _imap(account: dict[str, Any]) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    state = dict(account.get("sync_state") or {})
    cursors = dict(state.get("imap_folders") or {})
    connection = operations._imap_open(account)
    messages = []
    pending = False
    try:
        for folder, mailbox in operations.imap_folders(connection).items():
            status, _ = connection.select(operations._mailbox(mailbox), readonly=True)
            if status != "OK":
                continue
            status, info = connection.status(operations._mailbox(mailbox), "(UIDNEXT UIDVALIDITY)")
            wire = b" ".join(item for item in info or [] if isinstance(item, bytes))
            validity_match = re.search(rb"UIDVALIDITY\s+(\d+)", wire)
            if status != "OK" or not validity_match:
                raise operations.OperationError("provider_unavailable")
            validity = validity_match[1].decode()
            status, data = connection.uid("SEARCH", None, "ALL")
            if status != "OK":
                raise operations.OperationError("provider_unavailable")
            all_uids = sorted(int(uid) for uid in (data[0] or b"").split())
            previous = cursors.get(mailbox) or {}
            previous_validity = str(previous.get("validity", validity))
            known_uids = set(previous.get("known_uids", []))
            missing = known_uids - set(all_uids) if previous_validity == validity else known_uids
            for missing_uid in missing:
                old_id = _cached_imap_id(
                    folder, mailbox, previous_validity, str(missing_uid), state
                )
                messages.append(
                    {"provider_message_id": old_id, "_removed": True, "_from_folder": folder}
                )
            if previous_validity != validity:
                previous = {}
                known_uids = set()
            if not previous:
                selected = all_uids[-PAGE:]
                older = all_uids[:-PAGE]
                before = min(selected) if older else 0
                next_uid = max(selected, default=0) + 1
            else:
                fresh = [uid for uid in all_uids if uid >= previous.get("next_uid", 0)]
                before = previous.get("before", 0)
                older = [uid for uid in all_uids if uid < before] if before else []
                selected = sorted(set(fresh[:PAGE] + older[-PAGE:] + all_uids[-10:]))
                next_uid = max(fresh[:PAGE], default=previous.get("next_uid", 1) - 1) + 1
                before = min(older[-PAGE:]) if len(older) > PAGE else 0
                pending = pending or len(fresh) > PAGE
            for uid in selected:
                try:
                    raw, flags = operations._imap_raw(connection, str(uid))
                except operations.OperationError as exc:
                    if exc.code == "not_found":
                        continue
                    raise
                provider_id = _cached_imap_id(folder, mailbox, validity, str(uid), state)
                item = normalize.mime_to_normalized(email.message_from_bytes(raw), provider_id)
                item.update(
                    folder=folder,
                    is_read="\\Seen" in flags,
                    is_starred="\\Flagged" in flags,
                    provider_metadata={
                        "reader_version": 1,
                        "imap_folder": mailbox,
                        "imap_uid": str(uid),
                        "imap_uid_validity": validity,
                    },
                )
                item["_skip_analysis"] = folder != "inbox" or not (
                    (not previous and not account.get("last_sync_at") and len(messages) < PAGE)
                    or (previous and uid >= previous.get("next_uid", 0))
                )
                messages.append(item)
            cursors[mailbox] = {
                "validity": validity,
                "next_uid": next_uid,
                "before": before,
                "known_uids": sorted((known_uids & set(all_uids)) | set(selected))[-10000:],
            }
            pending = pending or bool(before)
    finally:
        operations._logout(connection)
    state.update(imap_folders=cursors, reader_version=1, reader_backfill=pending)
    return messages, state


def _cached_imap_id(
    folder: str, mailbox: str, validity: str, uid: str, state: dict[str, Any]
) -> str:
    if (
        folder == "inbox"
        and state.get("uid_next")
        and not state.get("uid_epoch_ids", False)
        and str(state.get("uid_validity")) == validity
    ):
        return uid
    return operations.imap_provider_id(mailbox, validity, uid)


def _received_after(received: str | None, previous: str | None) -> bool:
    try:
        return bool(
            received
            and previous
            and datetime.fromisoformat(received) > datetime.fromisoformat(previous)
        )
    except (TypeError, ValueError):
        return False
