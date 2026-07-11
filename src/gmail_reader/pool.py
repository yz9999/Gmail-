from __future__ import annotations

import atexit
import socket
import threading
import time
from collections.abc import Callable
from dataclasses import dataclass, field
from typing import TypeVar

from imapclient.exceptions import IMAPClientError

from .accounts import AccountStore
from .client import GmailReader

T = TypeVar("T")


@dataclass(slots=True)
class _PoolEntry:
    reader: GmailReader
    lock: threading.RLock = field(default_factory=threading.RLock)
    last_used: float = field(default_factory=time.monotonic)


class GmailConnectionPool:
    """Small per-account IMAP connection pool for fast repeated web requests."""

    def __init__(self, account_store: AccountStore, max_connections: int = 8) -> None:
        self.account_store = account_store
        self.max_connections = max_connections
        self._entries: dict[str, _PoolEntry] = {}
        self._lock = threading.RLock()
        atexit.register(self.close_all)

    def execute(self, account_id: str | None, operation: Callable[[GmailReader], T]) -> T:
        account = self.account_store.get(account_id)
        entry = self._entry(account.id)
        with entry.lock:
            entry.last_used = time.monotonic()
            try:
                return operation(entry.reader)
            except (IMAPClientError, OSError, socket.timeout):
                entry.reader.close()
                entry.reader.connect()
                entry.last_used = time.monotonic()
                return operation(entry.reader)

    def close(self, account_id: str) -> None:
        with self._lock:
            entry = self._entries.pop(account_id, None)
        if entry:
            with entry.lock:
                entry.reader.close()

    def close_all(self) -> None:
        with self._lock:
            entries = list(self._entries.values())
            self._entries.clear()
        for entry in entries:
            with entry.lock:
                entry.reader.close()

    def _entry(self, account_id: str) -> _PoolEntry:
        with self._lock:
            existing = self._entries.get(account_id)
            if existing:
                return existing

            self._evict_if_needed()
            settings = self.account_store.settings(account_id)
            reader = GmailReader(settings)
            reader.connect()
            entry = _PoolEntry(reader=reader)
            self._entries[account_id] = entry
            return entry

    def _evict_if_needed(self) -> None:
        if len(self._entries) < self.max_connections:
            return
        for account_id, entry in sorted(
            self._entries.items(), key=lambda item: item[1].last_used
        ):
            if not entry.lock.acquire(blocking=False):
                continue
            try:
                self._entries.pop(account_id, None)
                entry.reader.close()
                return
            finally:
                entry.lock.release()
