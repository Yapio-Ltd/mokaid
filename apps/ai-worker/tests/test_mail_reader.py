"""Real protocol behavior via fixtures: no user mailbox or external mutation."""

import base64
import json
from email.message import EmailMessage
from unittest.mock import AsyncMock

import httpx
import pytest
import respx

from app.mail import fetchers, normalize, operations, reader_sync


def payload(provider="gmail"):
    return {
        "account": {
            "id": "account",
            "workspace_id": "workspace",
            "provider": provider,
            "credentials": {"access_token": "sensitive-token", "password": "app-password"},
        },
        "message": {
            "id": "internal",
            "workspace_id": "workspace",
            "mail_account_id": "account",
            "provider_message_id": "abc",
            "folder": "inbox",
            "labels": ["INBOX"],
        },
    }


@pytest.mark.parametrize(
    "html",
    [
        '<script>alert(1)</script><p onclick="bad">Hello</p><img src="https://track.test/pixel">',
        '<svg><script>bad</script></svg><p>Hello</p><iframe src="file:///etc/passwd"></iframe>',
        '<p style="background-image:url(https://evil);color:red;behavior:expression(x)">Hello</p>',
        '<a href="javascript:alert(1)">Hello</a><img src="data:image/svg+xml,x"><object>bad</object>',
    ],
)
def test_html_structural_sanitizer_blocks_active_and_remote_content(html):
    safe = normalize.safe_html(html)
    assert "Hello" in safe
    for forbidden in (
        "script",
        "onclick",
        "<img",
        "https:",
        "file:",
        "iframe",
        "javascript",
        "data:",
        "expression",
        "<object",
        "bad",
    ):
        assert forbidden not in safe
    assert (
        normalize.safe_html('<table><tr><td colspan="2"><b>ok</b></td></tr></table>')
        == '<table><tr><td colspan="2"><b>ok</b></td></tr></table>'
    )


def test_mime_preserves_html_rfc_headers_and_attachment_metadata():
    message = EmailMessage()
    message["From"] = "From <from@example.com>"
    message["Message-ID"] = "<original@example.com>"
    message["References"] = "<previous@example.com>"
    message.set_content("plain")
    message.add_alternative("<p><b>Rich</b><img src='https://track'></p>", subtype="html")
    message.add_attachment(
        b"file bytes", maintype="application", subtype="pdf", filename="document.pdf"
    )
    data = normalize.mime_to_normalized(message, "7:1")
    assert data["rfc_message_id"] == "<original@example.com>"
    assert data["references"] == ["<previous@example.com>"]
    assert "Rich" in data["body_html"] and "<img" not in data["body_html"]
    assert data["attachments"][0]["filename"] == "document.pdf"
    assert data["attachments"][0]["size"] == 10
    assert data["has_attachments"]
    assert "file bytes" not in data["body_text"]


@pytest.mark.parametrize(
    "entrypoint",
    [operations.hydrate_message, operations.message_action, operations.download_attachment],
)
async def test_workspace_account_mismatch_never_reaches_provider(monkeypatch, entrypoint):
    data = payload()
    data["message"]["workspace_id"] = "other"
    http = AsyncMock()
    monkeypatch.setattr(operations, "_http", http)
    assert await entrypoint(data) == {"error": "invalid_request"}
    http.assert_not_called()


@respx.mock
async def test_gmail_old_message_hydration_includes_attachments_and_real_flags():
    request = respx.get(fetchers.GMAIL_BASE + "/messages/abc").respond(
        200,
        json={
            "id": "abc",
            "labelIds": ["SENT", "STARRED"],
            "payload": {
                "headers": [{"name": "Message-ID", "value": "<abc@example.com>"}],
                "parts": [
                    {
                        "partId": "1",
                        "filename": "invoice.pdf",
                        "mimeType": "application/pdf",
                        "body": {"attachmentId": "attachment1", "size": 3},
                    },
                    {
                        "partId": "0",
                        "mimeType": "text/html",
                        "body": {"data": base64.urlsafe_b64encode(b"<b>Body</b>").decode()},
                    },
                ],
            },
        },
    )
    response = await operations.hydrate_message(payload())
    message = response["message"]
    assert message["folder"] == "sent" and message["is_read"] and message["is_starred"]
    assert message["rfc_message_id"] == "<abc@example.com>"
    assert message["attachments"][0]["provider_id"] == "attachment1"
    assert message["body_html"] == "<b>Body</b>"
    assert request.calls[0].request.url.params["format"] == "full"


@respx.mock
async def test_gmail_attachment_fetch_is_message_scoped_and_binary_exact():
    request = respx.get(fetchers.GMAIL_BASE + "/messages/abc/attachments/part").respond(
        200, json={"data": base64.urlsafe_b64encode(b"\x00bytes").decode()}
    )
    data = payload()
    data["attachment"] = {"provider_id": "part", "size": 6}
    result = await operations.download_attachment(data)
    assert base64.b64decode(result["content_base64"]) == b"\x00bytes"
    assert request.call_count == 1


@pytest.mark.parametrize(
    "action,value,expected",
    [
        ("read", True, {"addLabelIds": [], "removeLabelIds": ["UNREAD"]}),
        ("read", False, {"addLabelIds": ["UNREAD"], "removeLabelIds": []}),
        ("star", True, {"addLabelIds": ["STARRED"], "removeLabelIds": []}),
        ("archive", True, {"addLabelIds": [], "removeLabelIds": ["INBOX"]}),
        ("spam", True, {"addLabelIds": ["SPAM"], "removeLabelIds": ["INBOX"]}),
    ],
)
@respx.mock
async def test_gmail_flags_are_actual_provider_mutations(action, value, expected):
    request = respx.post(fetchers.GMAIL_BASE + "/messages/abc/modify").respond(
        200, json={"id": "abc", "labelIds": ["STARRED"]}
    )
    result = await operations.message_action({**payload(), "action": action, "value": value})
    assert json.loads(request.calls[0].request.content) == expected
    assert result["changes"]["is_starred"]
    assert result["changes"]["folder"] == "archive"


@pytest.mark.parametrize("value,path", [(True, "trash"), (False, "untrash")])
@respx.mock
async def test_gmail_trash_is_reversible_and_never_delete(value, path):
    request = respx.post(fetchers.GMAIL_BASE + "/messages/abc/" + path).respond(
        200, json={"id": "abc", "labelIds": ["TRASH"] if value else ["INBOX"]}
    )
    response = await operations.message_action({**payload(), "action": "trash", "value": value})
    assert response["changes"]["folder"] == ("trash" if value else "inbox")
    assert request.call_count == 1


@respx.mock
async def test_graph_move_and_attachment_use_fixed_account_path():
    move = respx.post(fetchers.GRAPH_BASE + "/me/messages/abc/move").respond(
        201, json={"id": "immutable", "parentFolderId": "trash"}
    )
    response = await operations.message_action({**payload("microsoft"), "action": "trash"})
    assert json.loads(move.calls[0].request.content) == {"destinationId": "deleteditems"}
    assert response["changes"]["provider_message_id"] == "immutable"
    assert move.calls[0].request.headers["prefer"] == 'IdType="ImmutableId"'
    attachment = respx.get(
        fetchers.GRAPH_BASE + "/me/messages/abc/attachments/part/$value"
    ).respond(200, content=b"file")
    response = await operations.download_attachment(
        {**payload("microsoft"), "attachment": {"provider_id": "part", "size": 4}}
    )
    assert base64.b64decode(response["content_base64"]) == b"file"
    assert attachment.called


@pytest.mark.parametrize("status", [301, 401, 403, 404, 429, 500])
@respx.mock
async def test_upstream_errors_never_echo_secrets_or_follow_redirects(status):
    request = respx.get(fetchers.GMAIL_BASE + "/messages/abc").respond(
        status, text="sensitive-token app-password", headers={"Location": "https://evil.test"}
    )
    response = await operations.hydrate_message(payload())
    assert "error" in response
    assert "sensitive-token" not in json.dumps(response)
    assert "app-password" not in json.dumps(response)
    assert request.call_count == 1


async def test_attachment_size_rejected_before_provider(monkeypatch):
    call = AsyncMock()
    monkeypatch.setattr(operations, "_http", call)
    response = await operations.download_attachment(
        {**payload(), "attachment": {"size": operations.MAX_ATTACHMENT + 1}}
    )
    assert response == {"error": "attachment_too_large"}
    call.assert_not_called()


class Imap:
    capabilities = (b"IMAP4rev1", b"MOVE", b"UIDPLUS")

    def __init__(self):
        self.calls = []
        self.message = EmailMessage()
        self.message["Message-ID"] = "<imap@example.com>"
        self.message.set_content("hello")
        self.message.add_attachment(
            b"pdf-bytes", maintype="application", subtype="pdf", filename="report.pdf"
        )

    def login(self, *args):
        return "OK", []

    def select(self, mailbox, readonly=True):
        self.calls.append(("select", mailbox, readonly))
        return "OK", []

    def status(self, *args):
        return "OK", [b"(UIDVALIDITY 7 UIDNEXT 10)"]

    def list(self):
        return "OK", [
            rb'(\Sent) "/" "Sent"',
            rb'(\Trash) "/" "Trash"',
            rb'(\Drafts) "/" "Drafts"',
            rb'(\Junk) "/" "Junk"',
            rb'(\Archive) "/" "Archive"',
        ]

    def uid(self, command, *args):
        self.calls.append((command, *args))
        if command == "FETCH" and args[1] == "(RFC822.SIZE FLAGS)":
            return "OK", [rb"1 (RFC822.SIZE 500 FLAGS (\Seen \Flagged))"]
        if command == "FETCH":
            return "OK", [(b"1 FETCH", self.message.as_bytes())]
        if command == "SEARCH":
            return "OK", [b"1 2"]
        return "OK", [b"moved"]

    def response(self, code):
        return code, [b"7 1 9"]

    def logout(self):
        self.calls.append(("logout",))


async def test_imap_hydration_download_and_read_preserve_safe_protocol(monkeypatch):
    server = Imap()
    monkeypatch.setattr(fetchers, "_connect_imap", lambda settings: server)
    data = payload("imap")
    data["message"]["provider_message_id"] = "7:1"
    hydrated = (await operations.hydrate_message(data))["message"]
    assert hydrated["is_read"] and hydrated["is_starred"]
    data["attachment"] = hydrated["attachments"][0]
    assert (
        base64.b64decode((await operations.download_attachment(data))["content_base64"])
        == b"pdf-bytes"
    )
    response = await operations.message_action({**data, "action": "read", "value": False})
    assert response["changes"]["is_read"] is False
    assert ("STORE", "1", "-FLAGS.SILENT", r"(\Seen)") in server.calls
    assert all(
        "PEEK" in call[2] or call[2] == "(RFC822.SIZE FLAGS)"
        for call in server.calls
        if call[0] == "FETCH"
    )


async def test_imap_move_tracks_new_uid_without_expunge(monkeypatch):
    server = Imap()
    monkeypatch.setattr(fetchers, "_connect_imap", lambda settings: server)
    data = payload("imap")
    data["message"]["provider_message_id"] = "7:1"
    result = await operations.message_action({**data, "action": "trash"})
    assert result["changes"]["folder"] == "trash"
    assert result["changes"]["provider_metadata"]["imap_uid"] == "9"
    assert result["changes"]["provider_metadata"]["imap_folder"] == "Trash"
    assert ("MOVE", "1", '"Trash"') in server.calls
    assert not any(call[0] in {"EXPUNGE", "DELETE"} for call in server.calls)


async def test_imap_missing_move_is_reported_unsupported_without_mutating(monkeypatch):
    server = Imap()
    server.capabilities = (b"IMAP4rev1",)
    monkeypatch.setattr(fetchers, "_connect_imap", lambda settings: server)
    data = payload("imap")
    data["message"]["provider_message_id"] = "7:1"
    assert await operations.message_action({**data, "action": "trash"}) == {
        "error": "unsupported_action"
    }
    assert not any(call[0] in {"STORE", "MOVE"} for call in server.calls)


async def test_imap_uidvalidity_mismatch_never_fetches_or_modifies(monkeypatch):
    server = Imap()
    monkeypatch.setattr(fetchers, "_connect_imap", lambda settings: server)
    data = payload("imap")
    data["message"]["provider_message_id"] = "8:1"
    assert await operations.hydrate_message(data) == {"error": "not_found"}
    assert not any(call[0] in {"FETCH", "STORE"} for call in server.calls)


@respx.mock
async def test_gmail_all_folder_backfill_and_label_changes():
    respx.get(fetchers.GMAIL_BASE + "/profile").respond(200, json={"historyId": "100"})
    listing = respx.get(fetchers.GMAIL_BASE + "/messages").respond(
        200, json={"messages": [{"id": "abc"}], "nextPageToken": "older"}
    )
    respx.get(fetchers.GMAIL_BASE + "/messages/abc").respond(
        200, json={"id": "abc", "labelIds": ["SENT"]}
    )
    account = payload()["account"]
    messages, state = await reader_sync.fetch(account)
    assert messages[0]["folder"] == "sent"
    assert listing.calls[0].request.url.params["includeSpamTrash"] == "true"
    assert "labelIds" not in listing.calls[0].request.url.params
    assert state["reader_backfill"] and state["history_id"] == "100"
    respx.get(fetchers.GMAIL_BASE + "/history").respond(
        200, json={"historyId": "100", "history": []}
    )
    listing.respond(200, json={"messages": []})
    _, state = await reader_sync.fetch({**account, "sync_state": state})
    assert listing.calls[-1].request.url.params["pageToken"] == "older"
    assert not state["reader_backfill"]
    history = respx.get(fetchers.GMAIL_BASE + "/history").respond(
        200, json={"historyId": "200", "history": [{"labelsAdded": [{"message": {"id": "abc"}}]}]}
    )
    messages, state = await reader_sync.fetch({**account, "sync_state": state})
    assert len(messages) == 1 and state["history_id"] == "200"
    assert "labelId" not in history.calls[0].request.url.params


async def test_imap_sync_collects_standard_folders_and_flags(monkeypatch):
    server = Imap()
    monkeypatch.setattr(fetchers, "_connect_imap", lambda settings: server)
    messages, state = await reader_sync.fetch(payload("imap")["account"])
    assert {item["folder"] for item in messages} == {
        "inbox",
        "sent",
        "drafts",
        "spam",
        "trash",
        "archive",
    }
    assert len({item["provider_message_id"] for item in messages}) == len(messages)
    assert all(item["attachments"] and item["is_read"] for item in messages)
    assert state["reader_version"] == 1


@pytest.mark.parametrize(
    "url", ["https://example.com/invoice?id=2", "http://example.com", "mailto:person@example.com"]
)
def test_html_keeps_only_safe_links(url):
    sanitized = normalize.safe_html(f'<a href="{url}" onclick="bad">Open</a>')
    assert "href=" in sanitized and "onclick" not in sanitized


@pytest.mark.parametrize(
    "url",
    [
        "javascript:alert(1)",
        "data:text/html,hi",
        "file:///tmp/private",
        "https://user:password@example.com",
        "https://example.com/%0d%0aevil",
        "mailto:p@example.com?body=inject",
        "//example.com",
    ],
)
def test_html_blocks_dangerous_links(url):
    assert "href=" not in normalize.safe_html(f'<a href="{url}">Open</a>')


def test_html_huge_integer_attribute_does_not_break_sync():
    assert normalize.safe_html('<td colspan="' + "1" * 5000 + '">Body</td>') == "<td>Body</td>"


@respx.mock
async def test_graph_attachment_metadata_finishes_pages_before_marking_hydrated():
    url = fetchers.GRAPH_BASE + "/me/messages/abc/attachments"
    request = respx.get(url).mock(
        side_effect=[
            httpx.Response(
                200,
                json={
                    "value": [{"id": "a", "name": "a.pdf", "size": 1}],
                    "@odata.nextLink": url + "?$skip=1",
                },
            ),
            httpx.Response(200, json={"value": [{"id": "b", "name": "b.pdf", "size": 1}]}),
        ]
    )
    result = await operations.graph_attachment_metadata(payload("microsoft")["account"], "abc")
    assert [item["id"] for item in result] == ["a", "b"]
    assert request.call_count == 2


@respx.mock
async def test_graph_attachment_continuation_cannot_change_origin_or_message():
    url = fetchers.GRAPH_BASE + "/me/messages/abc/attachments"
    respx.get(url).respond(200, json={"value": [], "@odata.nextLink": "https://evil.test/steal"})
    with pytest.raises(operations.OperationError):
        await operations.graph_attachment_metadata(payload("microsoft")["account"], "abc")


async def test_imap_legacy_move_does_not_claim_unfetched_attachment_manifest(monkeypatch):
    server = Imap()
    monkeypatch.setattr(fetchers, "_connect_imap", lambda settings: server)
    data = payload("imap")
    data["message"]["provider_message_id"] = "7:1"
    result = await operations.message_action({**data, "action": "trash"})
    assert result["changes"]["provider_metadata"]["reader_version"] == 0


@respx.mock
async def test_gmail_arrivals_and_analysis_do_not_wait_for_backfill():
    account = payload()["account"]
    account["sync_state"] = {"reader_version": 1, "history_id": "100", "backfill_page": "older"}
    account["last_sync_at"] = "2026-09-27T00:00:00Z"
    history = respx.get(fetchers.GMAIL_BASE + "/history").respond(
        200,
        json={
            "historyId": "200",
            "history": [
                {
                    "messagesAdded": [{"message": {"id": "new"}}],
                    "labelsAdded": [{"message": {"id": "changed"}}],
                }
            ],
        },
    )
    listing = respx.get(fetchers.GMAIL_BASE + "/messages").respond(
        200, json={"messages": [{"id": "old"}], "nextPageToken": "more"}
    )
    for name in ["new", "changed", "old"]:
        respx.get(fetchers.GMAIL_BASE + "/messages/" + name).respond(
            200, json={"id": name, "labelIds": ["INBOX"]}
        )
    messages, state = await reader_sync.fetch(account)
    assert history.called and listing.called
    assert {item["provider_message_id"]: item["_skip_analysis"] for item in messages} == {
        "new": False,
        "changed": True,
        "old": True,
    }
    assert state["history_id"] == "200" and state["backfill_page"] == "more"


async def test_imap_metadata_refresh_skips_repeat_analysis(monkeypatch):
    server = Imap()
    monkeypatch.setattr(fetchers, "_connect_imap", lambda settings: server)
    account = payload("imap")["account"]
    _, state = await reader_sync.fetch(account)
    messages, _ = await reader_sync.fetch(
        {**account, "sync_state": state, "last_sync_at": "2026-09-27T00:00:00Z"}
    )
    assert all(item["_skip_analysis"] for item in messages if not item.get("_removed"))


async def test_imap_missing_uid_creates_scoped_local_tombstone(monkeypatch):
    server = Imap()
    monkeypatch.setattr(fetchers, "_connect_imap", lambda settings: server)
    account = payload("imap")["account"]
    account["sync_state"] = {
        "imap_folders": {
            "INBOX": {"validity": "7", "next_uid": 10, "before": 0, "known_uids": [1, 2, 9]}
        }
    }
    messages, _ = await reader_sync.fetch(account)
    assert {"provider_message_id": "7:9", "_removed": True, "_from_folder": "inbox"} in messages


@respx.mock
async def test_graph_hydration_preserves_message_headers_html_and_manifest():
    data = payload("microsoft")
    data["message"]["folder"] = "sent"
    respx.get(fetchers.GRAPH_BASE + "/me/messages/abc").respond(
        200,
        json={
            "id": "abc",
            "body": {
                "contentType": "html",
                "content": '<b>Hello</b><img src="https://tracking.test">',
            },
            "internetMessageId": "<graph@example.com>",
            "internetMessageHeaders": [{"name": "References", "value": "<earlier@example.com>"}],
            "isRead": True,
            "flag": {"flagStatus": "flagged"},
        },
    )
    respx.get(fetchers.GRAPH_BASE + "/me/messages/abc/attachments").respond(
        200,
        json={
            "value": [
                {"id": "file", "name": "report.pdf", "size": 4, "contentType": "application/pdf"}
            ]
        },
    )
    result = (await operations.hydrate_message(data))["message"]
    assert result["folder"] == "sent"
    assert result["is_read"] and result["is_starred"]
    assert result["references"] == ["<earlier@example.com>"]
    assert result["body_html"] == "<b>Hello</b>"
    assert result["attachments"][0]["filename"] == "report.pdf"


@respx.mock
async def test_inline_gmail_attachment_is_found_by_exact_part_and_filename():
    raw = {
        "id": "abc",
        "payload": {
            "parts": [
                {
                    "partId": "1",
                    "filename": "inline.txt",
                    "body": {"data": base64.urlsafe_b64encode(b"inline").decode()},
                }
            ]
        },
    }
    respx.get(fetchers.GMAIL_BASE + "/messages/abc").respond(200, json=raw)
    data = {**payload(), "attachment": {"size": 6, "part_id": "1", "filename": "inline.txt"}}
    assert (
        base64.b64decode((await operations.download_attachment(data))["content_base64"])
        == b"inline"
    )
    data["attachment"]["filename"] = "another.txt"
    assert await operations.download_attachment(data) == {"error": "not_found"}


@respx.mock
async def test_provider_attachment_response_cannot_exceed_advertised_budget():
    data = {**payload("microsoft"), "attachment": {"provider_id": "part", "size": 1}}
    respx.get(fetchers.GRAPH_BASE + "/me/messages/abc/attachments/part/$value").respond(
        200, content=b"x" * (operations.MAX_ATTACHMENT + 1)
    )
    assert await operations.download_attachment(data) == {"error": "attachment_too_large"}


@pytest.mark.parametrize(
    "action,value,expected",
    [
        ("read", True, {"isRead": True}),
        ("star", False, {"flag": {"flagStatus": "notFlagged"}}),
    ],
)
@respx.mock
async def test_graph_read_and_star_have_precise_patch_bodies(action, value, expected):
    request = respx.patch(fetchers.GRAPH_BASE + "/me/messages/abc").respond(200, json={})
    result = await operations.message_action(
        {**payload("microsoft"), "action": action, "value": value}
    )
    assert "changes" in result
    assert json.loads(request.calls[0].request.content) == expected


@respx.mock
async def test_gmail_modify_missing_labels_reads_current_metadata():
    respx.post(fetchers.GMAIL_BASE + "/messages/abc/modify").respond(200, json={"id": "abc"})
    respx.get(fetchers.GMAIL_BASE + "/messages/abc").respond(
        200, json={"labelIds": ["INBOX", "UNREAD"]}
    )
    result = await operations.message_action({**payload(), "action": "archive", "value": False})
    assert result["changes"]["folder"] == "inbox"
    assert not result["changes"]["is_read"]


@pytest.mark.parametrize(
    "data",
    [
        {"action": "delete", "value": True},
        {"action": "read", "value": "false"},
    ],
)
async def test_invalid_actions_are_rejected_before_dispatch(monkeypatch, data):
    http = AsyncMock()
    monkeypatch.setattr(operations, "_http", http)
    assert await operations.message_action({**payload(), **data}) == {"error": "invalid_request"}
    http.assert_not_called()


async def test_bad_credentials_id_or_provider_never_reach_network():
    data = payload()
    data["account"]["provider"] = "untrusted"
    assert await operations.hydrate_message(data) == {"error": "invalid_request"}
    data = payload()
    data["message"]["provider_message_id"] = ".."
    assert await operations.hydrate_message(data) == {"error": "invalid_request"}
    data = payload()
    data["account"]["credentials"] = {}
    assert await operations.hydrate_message(data) == {"error": "auth_failed"}


@respx.mock
async def test_graph_full_folder_delta_cursors_tombstones_and_new_message_analysis():
    account = payload("microsoft")["account"]
    account["last_sync_at"] = "2026-09-27T00:00:00Z"
    previous_url = fetchers.GRAPH_BASE + "/me/mailFolders/inbox/messages/delta?$deltatoken=previous"
    account["sync_state"] = {"graph_folders": {"inbox": {"delta": previous_url}}}
    for key in ["inbox", "sentitems", "drafts", "junkemail", "deleteditems", "archive"]:
        values = []
        if key == "inbox":
            values = [
                {"id": "new", "receivedDateTime": "2026-09-27T00:01:00Z"},
                {"id": "gone", "@removed": {"reason": "deleted"}},
                {"id": "old", "receivedDateTime": "2026-09-26T00:01:00Z", "hasAttachments": True},
            ]
        respx.get(fetchers.GRAPH_BASE + "/me/mailFolders/" + key + "/messages/delta").respond(
            200,
            json={
                "value": values,
                "@odata.deltaLink": fetchers.GRAPH_BASE
                + "/me/mailFolders/"
                + key
                + "/messages/delta?$deltatoken=new",
            },
        )
    respx.get(fetchers.GRAPH_BASE + "/me/messages/old/attachments").respond(200, json={"value": []})
    messages, state = await reader_sync.fetch(account)
    assert (
        next(item for item in messages if item["provider_message_id"] == "new")["_skip_analysis"]
        is False
    )
    assert next(item for item in messages if item["provider_message_id"] == "old")["_skip_analysis"]
    assert {"provider_message_id": "gone", "_removed": True, "_from_folder": "inbox"} in messages
    assert len(state["graph_folders"]) == 6
    assert not state["reader_backfill"]


@respx.mock
async def test_graph_expired_cursor_restarts_and_optional_archive_absence_is_allowed():
    account = payload("microsoft")["account"]
    account["sync_state"] = {
        "graph_folders": {
            "inbox": {
                "delta": fetchers.GRAPH_BASE
                + "/me/mailFolders/inbox/messages/delta?$deltatoken=old"
            }
        }
    }
    inbox = respx.get(fetchers.GRAPH_BASE + "/me/mailFolders/inbox/messages/delta").mock(
        side_effect=[
            httpx.Response(410),
            httpx.Response(
                200,
                json={
                    "value": [],
                    "@odata.nextLink": fetchers.GRAPH_BASE
                    + "/me/mailFolders/inbox/messages/delta?$skip=next",
                },
            ),
        ]
    )
    for key in ["sentitems", "drafts", "junkemail", "deleteditems"]:
        respx.get(fetchers.GRAPH_BASE + "/me/mailFolders/" + key + "/messages/delta").respond(
            200,
            json={
                "value": [],
                "@odata.deltaLink": fetchers.GRAPH_BASE
                + "/me/mailFolders/"
                + key
                + "/messages/delta?x=1",
            },
        )
    respx.get(fetchers.GRAPH_BASE + "/me/mailFolders/archive/messages/delta").respond(404)
    _, state = await reader_sync.fetch(account)
    assert inbox.call_count == 2
    assert state["reader_backfill"]


async def test_graph_poisoned_continuation_fails_closed():
    account = payload("microsoft")["account"]
    account["sync_state"] = {"graph_folders": {"inbox": {"delta": "https://evil.test/token"}}}
    with pytest.raises(operations.OperationError, match="invalid_request"):
        await reader_sync.fetch(account)


@respx.mock
async def test_gmail_expired_history_restarts_without_advancing_past_failed_message():
    account = payload()["account"]
    account["sync_state"] = {"reader_version": 1, "history_id": "old"}
    respx.get(fetchers.GMAIL_BASE + "/history").respond(404)
    respx.get(fetchers.GMAIL_BASE + "/profile").respond(200, json={"historyId": "new"})
    respx.get(fetchers.GMAIL_BASE + "/messages").respond(
        200, json={"messages": [{"id": "gone"}, {"id": "failed"}]}
    )
    respx.get(fetchers.GMAIL_BASE + "/messages/gone").respond(404)
    respx.get(fetchers.GMAIL_BASE + "/messages/failed").respond(503)
    with pytest.raises(operations.OperationError, match="provider_unavailable"):
        await reader_sync.fetch(account)
    assert account["sync_state"]["history_id"] == "old"


@respx.mock
async def test_gmail_history_pagination_and_tombstones():
    account = payload()["account"]
    account["sync_state"] = {"reader_version": 1, "history_id": "100", "history_page_token": "next"}
    request = respx.get(fetchers.GMAIL_BASE + "/history").respond(
        200,
        json={
            "historyId": "200",
            "nextPageToken": "more",
            "history": [{"messagesDeleted": [{"message": {"id": "deleted"}}]}],
        },
    )
    messages, state = await reader_sync.fetch(account)
    assert messages == [{"provider_message_id": "deleted", "_removed": True}]
    assert state["history_id"] == "100" and state["history_page_token"] == "more"
    assert request.calls[0].request.url.params["pageToken"] == "next"


@pytest.mark.parametrize("failure", ["select", "status", "size", "fetch", "login", "store"])
async def test_imap_protocol_failures_are_sanitized(monkeypatch, failure):
    server = Imap()
    if failure == "select":
        server.select = lambda *args, **kwargs: ("NO", [])
    elif failure == "status":
        server.status = lambda *args: ("NO", [b"secret-token"])
    elif failure == "login":

        def login(*args):
            raise RuntimeError("secret-token")

        server.login = login
    else:
        original = server.uid

        def uid(command, *args):
            if failure == "size" and command == "FETCH":
                return "OK", [f"1 (RFC822.SIZE {operations.MAX_MIME + 1})".encode()]
            if failure == "fetch" and command == "FETCH" and "PEEK" in args[1]:
                return "NO", []
            if failure == "store" and command == "STORE":
                return "NO", [b"secret-token"]
            return original(command, *args)

        server.uid = uid
    monkeypatch.setattr(fetchers, "_connect_imap", lambda settings: server)
    data = payload("imap")
    data["message"]["provider_message_id"] = "7:1"
    result = await (
        operations.message_action({**data, "action": "read"})
        if failure == "store"
        else operations.hydrate_message(data)
    )
    assert "error" in result
    assert "secret-token" not in json.dumps(result)


async def test_imap_backfill_is_bounded_and_resumes_with_new_arrivals(monkeypatch):
    server = Imap()
    server.list = lambda: ("OK", [])
    original = server.uid
    uids = list(range(1, 81))

    def uid(command, *args):
        return (
            ("OK", [" ".join(map(str, uids)).encode()])
            if command == "SEARCH"
            else original(command, *args)
        )

    server.uid = uid
    monkeypatch.setattr(fetchers, "_connect_imap", lambda settings: server)
    account = payload("imap")["account"]
    first, state = await reader_sync.fetch(account)
    assert len(first) == 25 and state["reader_backfill"]
    assert state["imap_folders"]["INBOX"]["before"] == 56
    uids.extend([81, 82])
    second, state = await reader_sync.fetch(
        {**account, "sync_state": state, "last_sync_at": "2026-09-27T00:00:00Z"}
    )
    assert any(
        item["provider_message_id"] == "7:81" and not item["_skip_analysis"] for item in second
    )
    assert any(item["provider_message_id"] == "7:31" and item["_skip_analysis"] for item in second)
    assert state["imap_folders"]["INBOX"]["before"] == 31
