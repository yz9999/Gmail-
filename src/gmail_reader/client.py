from __future__ import annotations

import socket
import smtplib
import time
from collections.abc import Callable, Iterable
from email.message import EmailMessage

from imapclient import IMAPClient
from imapclient.exceptions import IMAPClientError

from .config import Settings
from .message import EmailRecord, parse_email
from .proxy import ProxyIMAPClient, ProxySMTPSSL


class GmailReader:
    def __init__(self, settings: Settings) -> None:
        self.settings = settings
        self.client: IMAPClient | None = None

    def connect(self) -> None:
        self.close()
        options = {
            "port": self.settings.port,
            "ssl": True,
            "timeout": 30,
        }
        if self.settings.proxy:
            client = ProxyIMAPClient(
                self.settings.host,
                proxy=self.settings.proxy,
                **options,
            )
        else:
            client = IMAPClient(self.settings.host, **options)
        client.login(self.settings.address, self.settings.app_password)
        self.client = client

    def close(self) -> None:
        if self.client is None:
            return
        try:
            self.client.logout()
        except (IMAPClientError, OSError):
            pass
        finally:
            self.client = None

    def __enter__(self) -> "GmailReader":
        self.connect()
        return self

    def __exit__(self, *_: object) -> None:
        self.close()

    def check(self) -> dict[str, object]:
        client = self._require_client()
        capabilities = sorted(
            item.decode(errors="replace") if isinstance(item, bytes) else str(item)
            for item in client.capabilities()
        )
        status = client.folder_status(self.settings.folder, [b"MESSAGES", b"UNSEEN"])
        return {
            "address": self.settings.address,
            "folder": self.settings.folder,
            "messages": int(status.get(b"MESSAGES", 0)),
            "unseen": int(status.get(b"UNSEEN", 0)),
            "idle_supported": "IDLE" in capabilities,
        }

    def fetch(self, limit: int = 10, unread_only: bool = False) -> list[EmailRecord]:
        client = self._require_client()
        client.select_folder(self.settings.folder, readonly=True)
        criteria = ["UNSEEN"] if unread_only else ["ALL"]
        uids = list(client.search(criteria))[-limit:]
        return self._fetch_uids(uids)

    def fetch_view(self, view: str = "inbox", limit: int = 30) -> list[EmailRecord]:
        client = self._require_client()
        folder, criteria = self._resolve_view(view)
        client.select_folder(folder, readonly=True)
        uids = list(client.search(criteria))[-limit:]
        return self._fetch_uids(uids)

    def fetch_view_summaries(self, view: str = "inbox", limit: int = 30) -> list[EmailRecord]:
        """Fetch only message headers for a fast mailbox list."""
        records, _total = self.fetch_view_page(view=view, page=1, limit=limit)
        return records

    def fetch_view_page(
        self, view: str = "inbox", page: int = 1, limit: int = 50
    ) -> tuple[list[EmailRecord], int]:
        """Fetch one newest-first page of message headers and the total count."""
        client = self._require_client()
        folder, criteria = self._resolve_view(view)
        select_info = client.select_folder(folder, readonly=True)
        if criteria == ["ALL"] and page == 1:
            total = int(select_info.get(b"EXISTS", select_info.get(b"MESSAGES", 0)))
            uid_next = int(select_info.get(b"UIDNEXT", 1))
            if uid_next <= 1:
                return [], total
            # UIDs in a Gmail folder are normally dense. Fetching a modest trailing
            # range avoids a separate SEARCH round trip on every refresh.
            window = max(limit * 3, 100)
            records = self._fetch_summaries(f"{max(1, uid_next - window)}:{uid_next - 1}")
            if len(records) >= min(limit, total):
                return records[-limit:], total

        uids = list(client.search(criteria))
        total = len(uids)
        offset = (page - 1) * limit
        end = max(0, total - offset)
        start = max(0, end - limit)
        page_uids = uids[start:end]
        return self._fetch_summaries(page_uids), total

    def fetch_one(self, uid: int, view: str = "inbox") -> EmailRecord | None:
        client = self._require_client()
        folder, _ = self._resolve_view(view)
        client.select_folder(folder, readonly=True)
        records = self._fetch_uids([uid])
        return records[0] if records else None

    def update_flags(self, uid: int, view: str, action: str) -> None:
        client = self._require_client()
        folder, _ = self._resolve_view(view)
        client.select_folder(folder, readonly=False)
        operations = {
            "star": (client.add_flags, [b"\\Flagged"]),
            "unstar": (client.remove_flags, [b"\\Flagged"]),
            "read": (client.add_flags, [b"\\Seen"]),
            "unread": (client.remove_flags, [b"\\Seen"]),
        }
        operation = operations.get(action)
        if operation is None:
            raise ValueError("未知邮件操作")
        method, flags = operation
        method([uid], flags, silent=True)

    def mark_all_read(self, view: str = "inbox") -> int:
        """Mark every unread message in the selected mailbox view as read."""
        client = self._require_client()
        folder, view_criteria = self._resolve_view(view)
        client.select_folder(folder, readonly=False)
        criteria = ["UNSEEN"]
        if view_criteria not in (["ALL"], ["UNSEEN"]):
            criteria.extend(view_criteria)
        uids = list(client.search(criteria))
        if uids:
            client.add_flags(uids, [b"\\Seen"], silent=True)
        return len(uids)

    def send_message(self, recipients: list[str], subject: str, body: str) -> None:
        message = EmailMessage()
        message["From"] = self.settings.address
        message["To"] = ", ".join(recipients)
        message["Subject"] = subject
        message.set_content(body)

        smtp_class = ProxySMTPSSL if self.settings.proxy else smtplib.SMTP_SSL
        smtp_options = {"timeout": 30}
        if self.settings.proxy:
            smtp_options["proxy"] = self.settings.proxy
        with smtp_class(self.settings.smtp_host, self.settings.smtp_port, **smtp_options) as smtp:
            smtp.login(self.settings.address, self.settings.app_password)
            smtp.send_message(message)

    def watch(
        self,
        on_message: Callable[[EmailRecord], None],
        *,
        include_existing: bool = False,
        idle_timeout: int = 60,
        renew_after: int = 25 * 60,
    ) -> None:
        """Continuously watch for new messages, reconnecting with backoff when needed."""
        backoff = 1
        last_uid = 0

        while True:
            try:
                if self.client is None:
                    self.connect()
                client = self._require_client()
                client.select_folder(self.settings.folder, readonly=True)

                all_uids = list(client.search(["ALL"]))
                current_max = max(all_uids, default=0)
                if last_uid == 0:
                    if include_existing:
                        for record in self._fetch_uids(
                            list(client.search(["UNSEEN"]))
                        ):
                            on_message(record)
                    last_uid = current_max
                else:
                    self._emit_after(last_uid, on_message)
                    all_uids = list(client.search(["ALL"]))
                    last_uid = max(all_uids, default=last_uid)

                backoff = 1
                idle_started = time.monotonic()
                client.idle()

                while time.monotonic() - idle_started < renew_after:
                    responses = client.idle_check(timeout=idle_timeout)
                    if responses:
                        client.idle_done()
                        new_last_uid = self._emit_after(last_uid, on_message)
                        last_uid = max(last_uid, new_last_uid)
                        client.idle()
                        idle_started = time.monotonic()

                client.idle_done()
            except KeyboardInterrupt:
                raise
            except (IMAPClientError, OSError, socket.timeout):
                self.close()
                time.sleep(backoff)
                backoff = min(backoff * 2, 60)

    def _emit_after(
        self, last_uid: int, on_message: Callable[[EmailRecord], None]
    ) -> int:
        client = self._require_client()
        uids = [uid for uid in client.search(["UID", f"{last_uid + 1}:*"]) if uid > last_uid]
        for record in self._fetch_uids(uids):
            on_message(record)
        return max(uids, default=last_uid)

    def _fetch_uids(self, uids: Iterable[int]) -> list[EmailRecord]:
        client = self._require_client()
        uid_list = list(uids)
        if not uid_list:
            return []

        fetched = client.fetch(uid_list, [b"RFC822", b"FLAGS"])
        records: list[EmailRecord] = []
        for uid in sorted(fetched):
            item = fetched[uid]
            raw = item.get(b"RFC822")
            if not isinstance(raw, bytes):
                continue
            raw_flags = item.get(b"FLAGS", ())
            flags = tuple(
                flag.decode(errors="replace") if isinstance(flag, bytes) else str(flag)
                for flag in raw_flags
            )
            records.append(parse_email(int(uid), raw, flags))
        return records

    def _fetch_summaries(self, uids: Iterable[int] | str) -> list[EmailRecord]:
        client = self._require_client()
        uid_set: list[int] | str = uids if isinstance(uids, str) else list(uids)
        if not uid_set:
            return []

        header_request = b"BODY.PEEK[HEADER.FIELDS (FROM TO SUBJECT DATE MESSAGE-ID)]"
        fetched = client.fetch(uid_set, [header_request, b"FLAGS"])
        records: list[EmailRecord] = []
        for uid in sorted(fetched):
            item = fetched[uid]
            raw_header = next(
                (
                    value
                    for key, value in item.items()
                    if isinstance(key, bytes)
                    and key.startswith(b"BODY[HEADER.FIELDS")
                    and isinstance(value, bytes)
                ),
                None,
            )
            if raw_header is None:
                continue
            raw_flags = item.get(b"FLAGS", ())
            flags = tuple(
                flag.decode(errors="replace") if isinstance(flag, bytes) else str(flag)
                for flag in raw_flags
            )
            records.append(parse_email(int(uid), raw_header, flags))
        return records

    def _resolve_view(self, view: str) -> tuple[str, list[str]]:
        self._require_client()
        if view == "inbox":
            return self.settings.folder, ["ALL"]
        if view == "unread":
            return self.settings.folder, ["UNSEEN"]

        special_use = {
            "sent": "\\Sent",
            "drafts": "\\Drafts",
            "spam": "\\Junk",
            "trash": "\\Trash",
            "all": "\\All",
        }

        if view == "starred":
            folder = self._find_special_folder("\\All") or self.settings.folder
            return folder, ["FLAGGED"]

        flag = special_use.get(view)
        if flag is None:
            raise ValueError("未知邮箱视图")
        folder = self._find_special_folder(flag)
        if folder is None:
            raise ValueError(f"Gmail 未返回 {view} 邮箱")
        return folder, ["ALL"]

    def _find_special_folder(self, wanted_flag: str) -> str | None:
        client = self._require_client()
        wanted = wanted_flag.casefold()
        for flags, _delimiter, folder in client.list_folders():
            normalized = {
                (flag.decode(errors="replace") if isinstance(flag, bytes) else str(flag)).casefold()
                for flag in flags
            }
            if wanted in normalized:
                return folder.decode(errors="replace") if isinstance(folder, bytes) else str(folder)
        return None

    def _require_client(self) -> IMAPClient:
        if self.client is None:
            raise RuntimeError("IMAP 客户端尚未连接")
        return self.client
