"""Bounded, read-only Google tools for explicitly granted OAuth integrations.

Every operation has a fixed HTTPS origin and path template. Account selection and
live grant/token resolution happen in the API before every managed tool call.
"""

import base64
import binascii
import copy
import json
import re
from typing import Any
from urllib.parse import quote

import httpx

from app.mail.normalize import html_to_text
from app.schemas import McpServerGrant

MAX_RESPONSE_BYTES = 2_000_000
MAX_TEXT_CHARS = 60_000
TIMEOUT = httpx.Timeout(20.0, connect=5.0)


def _string(description: str, maximum: int = 1024) -> dict[str, Any]:
    return {"type": "string", "description": description, "minLength": 1, "maxLength": maximum}


PAGE = {
    "page_size": {"type": "integer", "minimum": 1, "maximum": 100, "default": 50},
    "page_token": _string("Continuation token from the previous result.", 4096),
}
ID = _string("Resource ID, not a URL.", 256)


def _tool(
    name: str, description: str, properties: dict[str, Any], required: tuple[str, ...] = ()
) -> dict[str, Any]:
    return {
        "name": name,
        "description": description,
        "input_schema": {
            "type": "object",
            "properties": properties,
            "required": list(required),
            "additionalProperties": False,
        },
    }


TOOLS: dict[str, list[dict[str, Any]]] = {
    "gmail": [
        _tool(
            "list_messages",
            "List one page of Gmail message IDs using Gmail search syntax. Use get_message for content.",
            {**PAGE, "q": _string("Gmail search query.")},
        ),
        _tool(
            "get_message",
            "Read one Gmail message, including headers and text. Attachments are not downloaded.",
            {"message_id": ID},
            ("message_id",),
        ),
    ],
    "google_calendar": [
        _tool(
            "list_calendars",
            "List one page of calendars accessible to the connected Google account.",
            PAGE,
        ),
        _tool(
            "list_events",
            "Read one page of calendar events. Provide time_min and time_max (RFC3339) to limit the interval.",
            {
                **PAGE,
                "calendar_id": _string("Calendar ID or primary.", 512),
                "time_min": _string("RFC3339 lower bound.", 64),
                "time_max": _string("RFC3339 upper bound.", 64),
                "q": _string("Free text event search."),
            },
        ),
    ],
    "google_drive": [
        _tool(
            "list_files",
            "List one page of accessible Drive files. Optional q uses Google Drive query syntax.",
            {**PAGE, "q": _string("Drive query, for example name contains 'budget'.", 2048)},
        ),
        _tool(
            "get_file",
            "Read Drive file metadata, not its binary content.",
            {"file_id": ID},
            ("file_id",),
        ),
        _tool(
            "export_file",
            "Export a supported Google Workspace file as bounded text. Use Docs/Sheets tools for structured content.",
            {
                "file_id": ID,
                "mime_type": {
                    "type": "string",
                    "enum": ["text/plain", "text/csv", "text/tab-separated-values"],
                    "default": "text/plain",
                },
            },
            ("file_id",),
        ),
    ],
    "google_docs": [
        _tool(
            "get_document",
            "Read text from all Google document tabs and tables. Returns bounded text and title.",
            {"document_id": ID},
            ("document_id",),
        ),
    ],
    "google_sheets": [
        _tool(
            "get_spreadsheet",
            "Read spreadsheet title and sheet metadata. Use get_range for cell values.",
            {"spreadsheet_id": ID},
            ("spreadsheet_id",),
        ),
        _tool(
            "get_range",
            "Read cells in an explicit A1 range. Choose a bounded range, for example Sheet1!A1:F100.",
            {"spreadsheet_id": ID, "range": _string("A1 range to read.", 1024)},
            ("spreadsheet_id", "range"),
        ),
    ],
    "google_meet": [
        _tool(
            "get_space",
            "Read an accessible Meet space by ID or meeting code. Legacy app-created permissions only allow spaces created by this app.",
            {"space_id": ID},
            ("space_id",),
        ),
        _tool(
            "list_conference_records",
            "Read one page of accessible Meet conference records. Legacy app-created permissions limit accessible records.",
            {
                **PAGE,
                "filter": _string(
                    'Meet filter expression, for example space.meeting_code = "abc-mnop-xyz".', 2048
                ),
            },
        ),
    ],
}


class GoogleToolError(Exception):
    """A deliberately credential-free error suitable for model output."""


def list_tools(provider: str) -> list[dict[str, Any]]:
    """Return static definitions without making requests or exposing credentials."""
    return copy.deepcopy(TOOLS.get(provider, []))


def _validate(provider: str, name: str, arguments: dict[str, Any]) -> None:
    definition = next((tool for tool in TOOLS.get(provider, []) if tool["name"] == name), None)
    if definition is None:
        raise GoogleToolError("Unknown Google read tool.")
    schema = definition["input_schema"]
    if not isinstance(arguments, dict) or set(arguments) - set(schema["properties"]):
        raise GoogleToolError("Unsupported tool arguments.")
    if any(key not in arguments for key in schema["required"]):
        raise GoogleToolError("A required tool argument is missing.")
    for key, value in arguments.items():
        spec = schema["properties"][key]
        if spec["type"] == "integer":
            if type(value) is not int or not spec["minimum"] <= value <= spec["maximum"]:
                raise GoogleToolError("Page size must be an integer between 1 and 100.")
        elif (
            not isinstance(value, str)
            or not value
            or len(value) > spec.get("maxLength", 4096)
            or any(ord(char) < 32 for char in value)
        ):
            raise GoogleToolError(
                "A text argument is empty, too long or contains control characters."
            )
        elif "enum" in spec and value not in spec["enum"]:
            raise GoogleToolError("Unsupported export format.")


def _id(arguments: dict[str, Any], name: str) -> str:
    value: str = arguments[name]
    if not re.fullmatch(r"[A-Za-z0-9_-]+", value):
        raise GoogleToolError("Use a resource ID rather than a URL or path.")
    return value


def _page(arguments: dict[str, Any], size_key: str = "pageSize") -> dict[str, Any]:
    result: dict[str, Any] = {size_key: arguments.get("page_size", 50)}
    if "page_token" in arguments:
        result["pageToken"] = arguments["page_token"]
    return result


FILE_FIELDS = "id,name,mimeType,size,modifiedTime,webViewLink,description,parents,exportLinks"


def _request(provider: str, name: str, args: dict[str, Any]) -> tuple[str, dict[str, Any], bool]:
    """Build only fixed Google endpoints. User input cannot choose a host/method."""
    if provider == "gmail":
        base = "https://gmail.googleapis.com/gmail/v1/users/me/messages"
        if name == "list_messages":
            params = _page(args, "maxResults")
            if "q" in args:
                params["q"] = args["q"]
            return base, params, False
        return f"{base}/{_id(args, 'message_id')}", {"format": "full"}, False
    if provider == "google_calendar":
        base = "https://www.googleapis.com/calendar/v3"
        params = _page(args, "maxResults")
        if name == "list_calendars":
            return f"{base}/users/me/calendarList", params, False
        calendar = args.get("calendar_id", "primary")
        if calendar in {".", ".."} or "/" in calendar or "\\" in calendar:
            raise GoogleToolError("Invalid calendar ID.")
        params.update({"singleEvents": "true", "orderBy": "startTime"})
        for source, target in [("time_min", "timeMin"), ("time_max", "timeMax"), ("q", "q")]:
            if source in args:
                params[target] = args[source]
        return f"{base}/calendars/{quote(calendar, safe='')}/events", params, False
    if provider == "google_drive":
        base = "https://www.googleapis.com/drive/v3/files"
        if name == "list_files":
            params = {
                **_page(args),
                "fields": f"nextPageToken,incompleteSearch,files({FILE_FIELDS})",
                "q": args.get("q", "trashed = false"),
                "includeItemsFromAllDrives": "true",
                "supportsAllDrives": "true",
            }
            return base, params, False
        base += f"/{_id(args, 'file_id')}"
        if name == "export_file":
            return f"{base}/export", {"mimeType": args.get("mime_type", "text/plain")}, True
        return base, {"fields": FILE_FIELDS, "supportsAllDrives": "true"}, False
    if provider == "google_docs":
        return (
            f"https://docs.googleapis.com/v1/documents/{_id(args, 'document_id')}",
            {"includeTabsContent": "true"},
            False,
        )
    if provider == "google_sheets":
        base = f"https://sheets.googleapis.com/v4/spreadsheets/{_id(args, 'spreadsheet_id')}"
        if name == "get_range":
            return (
                f"{base}/values/{quote(args['range'], safe='')}",
                {"valueRenderOption": "FORMATTED_VALUE"},
                False,
            )
        return (
            base,
            {
                "includeGridData": "false",
                "fields": "spreadsheetId,spreadsheetUrl,properties,sheets(properties)",
            },
            False,
        )
    if provider == "google_meet":
        base = "https://meet.googleapis.com/v2"
        if name == "get_space":
            return f"{base}/spaces/{_id(args, 'space_id')}", {}, False
        params = _page(args)
        if "filter" in args:
            params["filter"] = args["filter"]
        return f"{base}/conferenceRecords", params, False
    raise GoogleToolError("Unknown Google provider.")


def _message(data: dict[str, Any]) -> dict[str, Any]:
    payload = data.get("payload", {})
    headers = {
        item.get("name", "").lower(): item.get("value", "") for item in payload.get("headers", [])
    }
    parts = [payload]
    bodies: list[str] = []
    html_bodies: list[str] = []
    while parts:
        part = parts.pop()
        parts.extend(part.get("parts", []))
        encoded = part.get("body", {}).get("data")
        if (
            encoded
            and part.get("mimeType", "text/plain") in {"text/plain", "text/html"}
            and not part.get("filename")
        ):
            try:
                target = html_bodies if part.get("mimeType") == "text/html" else bodies
                target.append(
                    base64.urlsafe_b64decode(encoded + "=" * (-len(encoded) % 4)).decode(
                        "utf-8", errors="replace"
                    )
                )
            except (ValueError, binascii.Error):
                continue
    text = "\n".join(reversed(bodies)) or html_to_text("\n".join(reversed(html_bodies)))
    return {
        "id": data.get("id"),
        "thread_id": data.get("threadId"),
        "labels": data.get("labelIds", []),
        "headers": {
            key: headers[key] for key in ("subject", "from", "to", "cc", "date") if key in headers
        },
        "snippet": data.get("snippet", ""),
        "text": text[:MAX_TEXT_CHARS],
        "text_truncated": len(text) > MAX_TEXT_CHARS,
    }


def _document(data: dict[str, Any]) -> dict[str, Any]:
    # Walk all tabs, tables, headers and footnotes without recursive call depth.
    pending: list[Any] = [data]
    runs: list[str] = []
    while pending:
        item = pending.pop()
        if isinstance(item, dict):
            text_run = item.get("textRun")
            if isinstance(text_run, dict) and isinstance(text_run.get("content"), str):
                runs.append(text_run["content"])
            pending.extend(reversed(list(item.values())))
        elif isinstance(item, list):
            pending.extend(reversed(item))
    text = "".join(runs)
    return {
        "document_id": data.get("documentId"),
        "title": data.get("title"),
        "text": text[:MAX_TEXT_CHARS],
        "text_truncated": len(text) > MAX_TEXT_CHARS,
    }


def _http_error(status: int) -> GoogleToolError:
    if status == 401:
        return GoogleToolError("Google authorization expired. Reconnect this account.")
    if status == 403:
        return GoogleToolError(
            "Google denied access. Check the account permissions and that this Google API is enabled."
        )
    if status == 404:
        return GoogleToolError("The requested Google resource is unavailable to this account.")
    if status == 429:
        return GoogleToolError("Google rate limit reached. Try again later.")
    if status == 400:
        return GoogleToolError(
            "Google rejected the query or resource format. Check the tool arguments."
        )
    return GoogleToolError("Google request failed. Try again later.")


async def call_tool(grant: McpServerGrant, name: str, arguments: dict[str, Any]) -> dict[str, Any]:
    """Execute one bounded GET, returning sanitized errors and no credentials."""
    result: dict[str, Any] = {"server": grant.key, "tool": name, "is_error": False}
    try:
        _validate(grant.key, name, arguments)
        token = grant.credentials.get("access_token")
        if not isinstance(token, str) or not token or any(ord(char) < 32 for char in token):
            raise GoogleToolError("Google authorization is unavailable. Reconnect this account.")
        url, params, export = _request(grant.key, name, arguments)
        async with httpx.AsyncClient(timeout=TIMEOUT, follow_redirects=False) as client:
            async with client.stream(
                "GET", url, params=params, headers={"Authorization": f"Bearer {token}"}
            ) as response:
                if not 200 <= response.status_code < 300:
                    raise _http_error(response.status_code)
                body = bytearray()
                async for chunk in response.aiter_bytes():
                    body.extend(chunk)
                    if len(body) > MAX_RESPONSE_BYTES:
                        raise GoogleToolError(
                            "Google result is too large. Request a smaller page, range or document."
                        )
        data: Any
        if export:
            text = body.decode("utf-8", errors="replace")
            data = {"text": text[:MAX_TEXT_CHARS], "truncated": len(text) > MAX_TEXT_CHARS}
        else:
            data = json.loads(body)
            if not isinstance(data, dict):
                raise GoogleToolError("Google returned an invalid response.")
            if grant.key == "gmail" and name == "get_message":
                data = _message(data)
            elif grant.key == "google_docs":
                data = _document(data)
        serialized = json.dumps(data, ensure_ascii=False)
        if len(serialized) > MAX_TEXT_CHARS + 8000:
            raise GoogleToolError(
                "Google result is too large. Request a smaller page or cell range."
            )
        result["content"] = [serialized]
    except GoogleToolError as exc:
        result.update(is_error=True, content=[str(exc)])
    except (httpx.HTTPError, ValueError, TypeError, KeyError, AttributeError, RecursionError):
        # Do not log upstream exception text, URLs or response bodies: providers
        # can echo authorization data or private content in error messages.
        result.update(
            is_error=True,
            content=["Google request could not be completed. Try again or reconnect this account."],
        )
    return result
