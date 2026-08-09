"""Helpers to turn provider payloads (MIME, Graph JSON) into one shape."""

import re
from email.header import decode_header, make_header
from email.message import Message
from email.utils import getaddresses, parsedate_to_datetime

_MAX_BODY = 20_000
_TAG_RE = re.compile(r"<(script|style)[^>]*>.*?</\1>", re.DOTALL | re.IGNORECASE)
_HTML_RE = re.compile(r"<[^>]+>")
_WS_RE = re.compile(r"[ \t]{2,}")
_NL_RE = re.compile(r"\n{3,}")


def html_to_text(html: str) -> str:
    """Cheap HTML → text: strip script/style, tags, collapse whitespace."""
    text = _TAG_RE.sub(" ", html or "")
    text = text.replace("<br", "\n<br").replace("</p>", "</p>\n").replace("</div>", "</div>\n")
    text = _HTML_RE.sub(" ", text)
    text = (
        text.replace("&nbsp;", " ")
        .replace("&amp;", "&")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", '"')
        .replace("&#39;", "'")
    )
    text = _WS_RE.sub(" ", text)
    text = _NL_RE.sub("\n\n", text)
    return text.strip()


def clip(text: str | None, limit: int = _MAX_BODY) -> str:
    return (text or "")[:limit]


def snippet_of(text: str | None, limit: int = 300) -> str:
    return " ".join((text or "").split())[:limit]


def decode_mime_header(raw: str | None) -> str:
    if not raw:
        return ""
    try:
        return str(make_header(decode_header(raw)))
    except Exception:
        return raw


def parse_address(raw: str | None) -> tuple[str, str]:
    """Returns (display_name, email) from a From-style header."""
    addresses = getaddresses([raw or ""])
    if not addresses:
        return "", ""
    name, email = addresses[0]
    return decode_mime_header(name), email.lower()


def parse_address_list(raw: str | None) -> list[str]:
    return [email.lower() for _name, email in getaddresses([raw or ""]) if email]


def mime_body_text(message: Message) -> tuple[str, bool]:
    """Extracts the best-effort text body and attachment flag from MIME."""
    has_attachments = False
    plain_parts: list[str] = []
    html_parts: list[str] = []

    parts = message.walk() if message.is_multipart() else [message]
    for part in parts:
        content_type = part.get_content_type()
        disposition = str(part.get("Content-Disposition") or "")
        if "attachment" in disposition.lower():
            has_attachments = True
            continue
        if part.is_multipart():
            continue

        try:
            payload = part.get_payload(decode=True)
            if payload is None:
                continue
            charset = part.get_content_charset() or "utf-8"
            decoded = payload.decode(charset, errors="replace")
        except Exception:
            continue

        if content_type == "text/plain":
            plain_parts.append(decoded)
        elif content_type == "text/html":
            html_parts.append(decoded)

    if plain_parts:
        return clip("\n".join(plain_parts)), has_attachments
    if html_parts:
        return clip(html_to_text("\n".join(html_parts))), has_attachments
    return "", has_attachments


def mime_to_normalized(message: Message, provider_message_id: str) -> dict:
    """Full MIME message → the normalized shape Phoenix ingests."""
    body_text, has_attachments = mime_body_text(message)
    from_name, from_email = parse_address(message.get("From"))

    received_at = None
    if message.get("Date"):
        try:
            received_at = parsedate_to_datetime(message["Date"]).isoformat()
        except Exception:
            received_at = None

    return {
        "provider_message_id": provider_message_id,
        "thread_id": decode_mime_header(message.get("Message-ID")),
        "from_name": from_name,
        "from_email": from_email,
        "to_emails": parse_address_list(message.get("To")),
        "cc_emails": parse_address_list(message.get("Cc")),
        "subject": decode_mime_header(message.get("Subject")),
        "snippet": snippet_of(body_text),
        "body_text": body_text,
        "folder": "inbox",
        "labels": [],
        "has_attachments": has_attachments,
        "received_at": received_at,
    }
