from __future__ import annotations

import re
from dataclasses import asdict, dataclass
from datetime import datetime
from email import policy
from email.message import Message
from email.parser import BytesParser
from html import unescape
from html.parser import HTMLParser
from typing import Any


class _HTMLTextExtractor(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.parts: list[str] = []

    def handle_data(self, data: str) -> None:
        self.parts.append(data)

    def text(self) -> str:
        value = unescape(" ".join(self.parts))
        return re.sub(r"\s+", " ", value).strip()


@dataclass(frozen=True, slots=True)
class EmailRecord:
    uid: int
    message_id: str
    subject: str
    sender: str
    recipients: str
    date: str
    body: str
    body_html: str
    flags: tuple[str, ...]

    def to_dict(self) -> dict[str, Any]:
        data = asdict(self)
        data["flags"] = list(self.flags)
        return data


def _header(message: Message, name: str) -> str:
    value = message.get(name, "")
    return str(value).strip()


def _decode_part(part: Message) -> str:
    try:
        content = part.get_content()
    except (LookupError, UnicodeError):
        payload = part.get_payload(decode=True) or b""
        content = payload.decode("utf-8", errors="replace")
    return content if isinstance(content, str) else str(content)


def _bodies_from_message(message: Message) -> tuple[str, str]:
    plain_parts: list[str] = []
    html_parts: list[str] = []

    parts = message.walk() if message.is_multipart() else [message]
    for part in parts:
        if part.is_multipart():
            continue
        if part.get_content_disposition() == "attachment":
            continue

        content_type = part.get_content_type()
        if content_type == "text/plain":
            plain_parts.append(_decode_part(part).strip())
        elif content_type == "text/html":
            html_parts.append(_decode_part(part).strip())

    # multipart/alternative usually contains one plain and one HTML representation.
    # Gmail renders the HTML alternative instead of flattening it to plain text.
    body_html = next((part for part in html_parts if part), "")
    body_text = next((part for part in plain_parts if part), "")
    if not body_text and body_html:
        parser = _HTMLTextExtractor()
        parser.feed(body_html)
        body_text = parser.text()
    return body_text, body_html


def parse_email(uid: int, raw_message: bytes, flags: tuple[str, ...] = ()) -> EmailRecord:
    message = BytesParser(policy=policy.default).parsebytes(raw_message)
    body_text, body_html = _bodies_from_message(message)
    return EmailRecord(
        uid=uid,
        message_id=_header(message, "Message-ID"),
        subject=_header(message, "Subject") or "（无主题）",
        sender=_header(message, "From"),
        recipients=_header(message, "To"),
        date=_header(message, "Date") or datetime.now().astimezone().isoformat(),
        body=body_text,
        body_html=body_html,
        flags=flags,
    )
