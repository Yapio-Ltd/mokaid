import base64
import json

import httpx
import pytest

from app.mcp import google
from app.mcp.client import McpToolbox, is_write_tool
from app.schemas import McpServerGrant


def grant(provider):
    # Native tools must ignore even a poisoned installation URL.
    return McpServerGrant(
        key=provider,
        name=provider,
        url="http://127.0.0.1/private",
        transport="google",
        credentials={"access_token": "secret-access"},
    )


def mock_http(monkeypatch, handler):
    original = httpx.AsyncClient

    def client(**kwargs):
        assert kwargs["follow_redirects"] is False
        assert kwargs["timeout"].connect == 5
        return original(**kwargs, transport=httpx.MockTransport(handler))

    monkeypatch.setattr(google.httpx, "AsyncClient", client)


@pytest.mark.parametrize("provider", list(google.TOOLS))
async def test_native_discovery_has_no_network_or_tokens(provider):
    tools = await McpToolbox([grant(provider)]).discover()
    assert tools
    assert "secret-access" not in json.dumps(tools)
    for tool in tools:
        assert tool["name"].startswith(f"mcp:{provider}:")
        assert not is_write_tool(tool["tool"])
        assert tool["input_schema"]["additionalProperties"] is False


@pytest.mark.parametrize(
    "provider,name,args,host,path,param",
    [
        (
            "gmail",
            "list_messages",
            {"q": "is:unread", "page_size": 3, "page_token": "next"},
            "gmail.googleapis.com",
            "/gmail/v1/users/me/messages",
            ("maxResults", "3"),
        ),
        (
            "gmail",
            "get_message",
            {"message_id": "abc"},
            "gmail.googleapis.com",
            "/gmail/v1/users/me/messages/abc",
            ("format", "full"),
        ),
        (
            "google_calendar",
            "list_calendars",
            {},
            "www.googleapis.com",
            "/calendar/v3/users/me/calendarList",
            ("maxResults", "50"),
        ),
        (
            "google_calendar",
            "list_events",
            {"calendar_id": "my@email.test", "time_min": "2026-09-01T00:00:00Z"},
            "www.googleapis.com",
            "/calendar/v3/calendars/my@email.test/events",
            ("timeMin", "2026-09-01T00:00:00Z"),
        ),
        (
            "google_drive",
            "list_files",
            {"page_size": 1},
            "www.googleapis.com",
            "/drive/v3/files",
            ("pageSize", "1"),
        ),
        (
            "google_drive",
            "get_file",
            {"file_id": "abc"},
            "www.googleapis.com",
            "/drive/v3/files/abc",
            ("supportsAllDrives", "true"),
        ),
        (
            "google_drive",
            "export_file",
            {"file_id": "abc", "mime_type": "text/csv"},
            "www.googleapis.com",
            "/drive/v3/files/abc/export",
            ("mimeType", "text/csv"),
        ),
        (
            "google_docs",
            "get_document",
            {"document_id": "abc"},
            "docs.googleapis.com",
            "/v1/documents/abc",
            ("includeTabsContent", "true"),
        ),
        (
            "google_sheets",
            "get_spreadsheet",
            {"spreadsheet_id": "abc"},
            "sheets.googleapis.com",
            "/v4/spreadsheets/abc",
            ("includeGridData", "false"),
        ),
        (
            "google_sheets",
            "get_range",
            {"spreadsheet_id": "abc", "range": "'My Sheet'!A1:C5"},
            "sheets.googleapis.com",
            "/v4/spreadsheets/abc/values/'My Sheet'!A1:C5",
            ("valueRenderOption", "FORMATTED_VALUE"),
        ),
        (
            "google_meet",
            "get_space",
            {"space_id": "abc-mnop-xyz"},
            "meet.googleapis.com",
            "/v2/spaces/abc-mnop-xyz",
            None,
        ),
        (
            "google_meet",
            "list_conference_records",
            {"filter": 'space.meeting_code = "abc-mnop-xyz"'},
            "meet.googleapis.com",
            "/v2/conferenceRecords",
            ("pageSize", "50"),
        ),
    ],
)
async def test_fixed_read_endpoints(monkeypatch, provider, name, args, host, path, param):
    requests = []

    def handler(request):
        requests.append(request)
        assert request.method == "GET"
        assert request.url.scheme == "https"
        assert request.url.host == host
        assert request.url.path == path
        assert request.headers["authorization"] == "Bearer secret-access"
        if param:
            assert request.url.params[param[0]] == param[1]
        return httpx.Response(200, json={"nextPageToken": "next", "id": "abc"})

    mock_http(monkeypatch, handler)
    toolbox = McpToolbox([grant(provider)])
    await toolbox.discover()
    result = await toolbox.call(f"mcp:{provider}:{name}", args)
    assert not result["is_error"]
    assert len(requests) == 1  # Pagination is explicit; never fetch an unbounded mailbox.
    assert "secret-access" not in json.dumps(result)


@pytest.mark.parametrize(
    "provider,name,args",
    [
        ("gmail", "list_messages", {"page_size": 101}),
        ("gmail", "list_messages", {"page_size": True}),
        ("gmail", "get_message", {"message_id": "../../secrets"}),
        ("gmail", "get_message", {"message_id": "https://evil.test"}),
        ("gmail", "list_messages", {"url": "https://evil.test"}),
        ("gmail", "list_messages", {"q": "secret\nheader"}),
        ("google_drive", "export_file", {"file_id": "abc", "mime_type": "application/pdf"}),
        ("google_calendar", "list_events", {"calendar_id": ".."}),
        ("google_sheets", "get_range", {"spreadsheet_id": "abc"}),
        ("gmail", "send_message", {}),
    ],
)
async def test_invalid_input_never_opens_network(monkeypatch, provider, name, args):
    def unexpected(**kwargs):
        pytest.fail("invalid tool input reached network")

    monkeypatch.setattr(google.httpx, "AsyncClient", unexpected)
    assert (await google.call_tool(grant(provider), name, args))["is_error"]


@pytest.mark.parametrize("status", [301, 400, 401, 403, 404, 429, 500])
async def test_remote_errors_and_redirects_are_sanitized(monkeypatch, status):
    requests = []

    def handler(request):
        requests.append(request)
        return httpx.Response(
            status,
            text="secret-access private response",
            headers={"location": "https://evil.test/steal"},
        )

    mock_http(monkeypatch, handler)
    result = await google.call_tool(grant("google_drive"), "get_file", {"file_id": "abc"})
    assert result["is_error"]
    assert "secret-access" not in json.dumps(result)
    assert len(requests) == 1


async def test_network_errors_do_not_echo_credentials(monkeypatch):
    def handler(request):
        raise httpx.ConnectError("secret-access", request=request)

    mock_http(monkeypatch, handler)
    result = await google.call_tool(grant("gmail"), "list_messages", {})
    assert result["is_error"]
    assert "secret-access" not in json.dumps(result)


async def test_large_responses_are_rejected(monkeypatch):
    mock_http(
        monkeypatch,
        lambda request: httpx.Response(200, content=b"x" * (google.MAX_RESPONSE_BYTES + 1)),
    )
    result = await google.call_tool(grant("google_drive"), "export_file", {"file_id": "abc"})
    assert result["is_error"]
    assert "too large" in result["content"][0]


async def test_gmail_decodes_text_but_does_not_download_attachments(monkeypatch):
    body = base64.urlsafe_b64encode("Bonjour été".encode()).decode().rstrip("=")
    mock_http(
        monkeypatch,
        lambda request: httpx.Response(
            200,
            json={
                "id": "abc",
                "payload": {
                    "headers": [{"name": "Subject", "value": "Test"}],
                    "parts": [
                        {"mimeType": "text/plain", "body": {"data": body}},
                        {
                            "mimeType": "text/plain",
                            "filename": "secret.txt",
                            "body": {"data": "YXR0YWNobWVudA"},
                        },
                    ],
                },
            },
        ),
    )
    result = await google.call_tool(grant("gmail"), "get_message", {"message_id": "abc"})
    data = json.loads(result["content"][0])
    assert data["text"] == "Bonjour été"
    assert data["headers"]["subject"] == "Test"


async def test_docs_returns_text_from_all_tabs(monkeypatch):
    mock_http(
        monkeypatch,
        lambda request: httpx.Response(
            200,
            json={
                "title": "Doc",
                "tabs": [
                    {
                        "documentTab": {
                            "body": {
                                "content": [
                                    {
                                        "paragraph": {
                                            "elements": [{"textRun": {"content": "First\n"}}]
                                        }
                                    }
                                ]
                            }
                        }
                    },
                    {
                        "documentTab": {
                            "body": {
                                "content": [
                                    {
                                        "paragraph": {
                                            "elements": [{"textRun": {"content": "Second\n"}}]
                                        }
                                    }
                                ]
                            }
                        }
                    },
                ],
            },
        ),
    )
    result = await google.call_tool(grant("google_docs"), "get_document", {"document_id": "abc"})
    assert json.loads(result["content"][0])["text"] == "First\nSecond\n"


@pytest.mark.parametrize("token", [None, "", "access\nmalformed"])
async def test_missing_token_fails_before_network(monkeypatch, token):
    current = grant("gmail")
    current.credentials = {"access_token": token}

    def unexpected(**kwargs):
        pytest.fail("invalid credentials reached network")

    monkeypatch.setattr(google.httpx, "AsyncClient", unexpected)
    assert (await google.call_tool(current, "list_messages", {}))["is_error"]


@pytest.mark.parametrize("content", [b"not-json secret-access", b"[]"])
async def test_invalid_upstream_data_is_sanitized(monkeypatch, content):
    mock_http(monkeypatch, lambda request: httpx.Response(200, content=content))
    result = await google.call_tool(grant("gmail"), "list_messages", {})
    assert result["is_error"]
    assert "secret-access" not in json.dumps(result)


async def test_large_sheet_requires_a_smaller_range(monkeypatch):
    mock_http(
        monkeypatch, lambda request: httpx.Response(200, json={"values": [["value" * 15000]]})
    )
    result = await google.call_tool(
        grant("google_sheets"), "get_range", {"spreadsheet_id": "abc", "range": "A1:Z1000"}
    )
    assert result["is_error"]
    assert "smaller page or cell range" in result["content"][0]


async def test_export_truncation_is_explicit(monkeypatch):
    mock_http(monkeypatch, lambda request: httpx.Response(200, text="x" * 60001))
    result = await google.call_tool(grant("google_drive"), "export_file", {"file_id": "abc"})
    data = json.loads(result["content"][0])
    assert data["truncated"]
    assert len(data["text"]) == 60000


async def test_gmail_html_only_content_is_readable(monkeypatch):
    body = base64.urlsafe_b64encode(b"<p>Hello <b>world</b></p><script>hidden</script>").decode()
    mock_http(
        monkeypatch,
        lambda request: httpx.Response(
            200, json={"payload": {"mimeType": "text/html", "body": {"data": body}}}
        ),
    )
    result = await google.call_tool(grant("gmail"), "get_message", {"message_id": "abc"})
    assert json.loads(result["content"][0])["text"] == "Hello world"
