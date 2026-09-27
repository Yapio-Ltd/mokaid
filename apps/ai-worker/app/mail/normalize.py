"""Helpers to turn provider payloads (MIME, Graph JSON) into one shape."""

import hashlib
import re
from email.header import decode_header, make_header
from email.message import Message
from email.utils import getaddresses, parsedate_to_datetime
from html import escape
from html.parser import HTMLParser
from urllib.parse import unquote, urlsplit

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
        if "attachment" in disposition.lower() or part.get_filename():
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
        **mime_details(message),
    }


# HTML is stored only after structural allow-listing. No active content, images,
# external resources, URLs, SVG, forms or arbitrary CSS survive this boundary.

_ALLOWED_TAGS = {
    "a",
    "p",
    "div",
    "span",
    "br",
    "hr",
    "b",
    "strong",
    "i",
    "em",
    "u",
    "s",
    "blockquote",
    "pre",
    "code",
    "ul",
    "ol",
    "li",
    "table",
    "thead",
    "tbody",
    "tr",
    "td",
    "th",
    "h1",
    "h2",
    "h3",
    "h4",
}
_BLOCKED_TAGS = {
    "script",
    "style",
    "iframe",
    "object",
    "embed",
    "svg",
    "math",
    "template",
    "noscript",
}
_VOID_TAGS = {"br", "hr"}
_STYLE_VALUES = re.compile(r"^[#a-zA-Z0-9(),.% +\-]+$")
_STYLE_KEYS = {
    "color",
    "background-color",
    "font-size",
    "font-weight",
    "font-style",
    "text-align",
    "text-decoration",
    "white-space",
    "padding",
    "margin",
    "border",
    "border-color",
    "border-width",
    "border-style",
}


class _SafeHTML(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.output: list[str] = []
        self.blocked: list[str] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if tag in _BLOCKED_TAGS:
            self.blocked.append(tag)
        if self.blocked or tag not in _ALLOWED_TAGS:
            return
        safe: list[str] = []
        for key, value in attrs:
            value = value or ""
            if key == "style":
                declarations = []
                for declaration in value[:2000].split(";"):
                    name, _, val = declaration.partition(":")
                    name, val = name.strip().lower(), val.strip()
                    if (
                        name in _STYLE_KEYS
                        and len(val) < 100
                        and _STYLE_VALUES.fullmatch(val)
                        and "url" not in val.lower()
                        and "expression" not in val.lower()
                    ):
                        declarations.append(name + ":" + val)
                if declarations:
                    safe.append('style="' + escape(";".join(declarations), quote=True) + '"')
            elif tag == "a" and key == "href" and safe_link(value):
                safe.append('href="' + escape(value, quote=True) + '"')
            elif (
                key in {"colspan", "rowspan"}
                and len(value) <= 3
                and value.isdigit()
                and 1 <= int(value) <= 100
            ):
                safe.append(key + '="' + value + '"')
        self.output.append("<" + tag + (" " + " ".join(safe) if safe else "") + ">")

    def handle_endtag(self, tag: str) -> None:
        if self.blocked:
            if tag == self.blocked[-1]:
                self.blocked.pop()
            return
        if tag in _ALLOWED_TAGS and tag not in _VOID_TAGS:
            self.output.append("</" + tag + ">")

    def handle_data(self, data: str) -> None:
        if not self.blocked:
            self.output.append(escape(data))


def safe_link(value: str) -> bool:
    if len(value) > 4096 or any(ord(char) <= 32 for char in unquote(value)):
        return False
    try:
        parsed = urlsplit(value)
        if parsed.scheme.lower() in {"http", "https"}:
            return (
                bool(parsed.hostname)
                and not parsed.username
                and not parsed.password
                and parsed.port in {None, 80, 443}
            )
        if parsed.scheme.lower() == "mailto" and not parsed.query and not parsed.fragment:
            return bool(re.fullmatch(r"[^<>\s?]+@[^<>\s?]+", unquote(parsed.path)))
    except ValueError:
        return False
    return False


def safe_html(value: str | None) -> str:
    parser = _SafeHTML()
    parser.feed((value or "")[:200_000])
    parser.close()
    return "".join(parser.output)[:200_000]


def attachment_id(value: str) -> str:
    return hashlib.sha256(value.encode()).hexdigest()[:32]


def mime_details(message: Message) -> dict:
    attachments = []
    html_parts = []
    for index, part in enumerate(message.walk()):
        if part.is_multipart():
            continue
        filename = decode_mime_header(part.get_filename())
        disposition = part.get_content_disposition()
        if filename or disposition == "attachment":
            payload = part.get_payload(decode=True) or b""
            attachments.append(
                {
                    "id": attachment_id(str(index) + ":" + filename),
                    "part_index": index,
                    "filename": filename or "attachment",
                    "mime_type": part.get_content_type(),
                    "size": len(payload),
                }
            )
        elif part.get_content_type() == "text/html":
            payload = part.get_payload(decode=True) or b""
            try:
                html_parts.append(
                    payload.decode(part.get_content_charset() or "utf-8", errors="replace")
                )
            except LookupError:
                html_parts.append(payload.decode("utf-8", errors="replace"))
    return {
        "body_html": safe_html("\n".join(html_parts)),
        "attachments": attachments,
        "has_attachments": bool(attachments),
        "rfc_message_id": decode_mime_header(message.get("Message-ID")),
        "references": re.findall(r"<[^<>\r\n]+>", message.get("References", ""))[:50],
    }
