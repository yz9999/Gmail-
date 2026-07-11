from __future__ import annotations

import socket
import threading
import time
import weakref
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
    users: int = 0


def _close_resources(entries: dict[str, _PoolEntry], lock: threading.RLock) -> None:
    with lock:
        pooled = list(entries.values())
        entries.clear()
    for entry in pooled:
        with entry.lock:
            entry.reader.close()


class GmailConnectionPool:
    """Small per-account IMAP connection pool for fast repeated web requests."""

    def __init__(
        self,
        account_store: AccountStore,
        max_connections: int = 8,
        idle_timeout: float = 15 * 60,
    ) -> None:
        if max_connections < 1:
            raise ValueError("max_connections 必须大于 0")
        self.account_store = account_store
        self.max_connections = max_connections
        self.idle_timeout = idle_timeout
        self._entries: dict[str, _PoolEntry] = {}
        self._lock = threading.RLock()
        self._available = threading.Condition(self._lock)
        self._finalizer = weakref.finalize(
            self, _close_resources, self._entries, self._lock
        )

    def execute(self, account_id: str | None, operation: Callable[[GmailReader], T]) -> T:
        account = self.account_store.get(account_id)
        entry = self._checkout_entry(account.id)
        try:
            with entry.lock:
                entry.last_used = time.monotonic()
                if entry.reader.client is None:
                    entry.reader.connect()
                try:
                    return operation(entry.reader)
                except (IMAPClientError, OSError, socket.timeout):
                    entry.reader.close()
                    try:
                        entry.reader.connect()
                        entry.last_used = time.monotonic()
                        return operation(entry.reader)
                    except BaseException:
                        entry.reader.close()
                        raise
        finally:
            self._release_entry(entry)

    def close(self, account_id: str) -> None:
        with self._available:
            entry = self._entries.pop(account_id, None)
            self._available.notify_all()
        if entry:
            with entry.lock:
                entry.reader.close()

    def close_all(self) -> None:
        with self._available:
            entries = list(self._entries.values())
            self._entries.clear()
            self._available.notify_all()
        for entry in entries:
            with entry.lock:
                entry.reader.close()

    def _checkout_entry(self, account_id: str) -> _PoolEntry:
        with self._available:
            while True:
                self._prune_idle()
                existing = self._entries.get(account_id)
                if existing:
                    existing.users += 1
                    return existing
                if len(self._entries) < self.max_connections or self._evict_one():
                    break
                self._available.wait()

            settings = self.account_store.settings(account_id)
            reader = GmailReader(settings)
            reader.connect()
            entry = _PoolEntry(reader=reader, users=1)
            self._entries[account_id] = entry
            return entry

    def _release_entry(self, entry: _PoolEntry) -> None:
        with self._available:
            entry.users = max(0, entry.users - 1)
            entry.last_used = time.monotonic()
            self._available.notify_all()

    def _evict_one(self) -> bool:
        for account_id, entry in sorted(
            self._entries.items(), key=lambda item: item[1].last_used
        ):
            if entry.users or not entry.lock.acquire(blocking=False):
                continue
            try:
                self._entries.pop(account_id, None)
                entry.reader.close()
                return True
            finally:
                entry.lock.release()
        return False

    def _prune_idle(self) -> None:
        if self.idle_timeout <= 0:
            return
        cutoff = time.monotonic() - self.idle_timeout
        for account_id, entry in list(self._entries.items()):
            if entry.users or entry.last_used >= cutoff or not entry.lock.acquire(blocking=False):
                continue
            try:
                self._entries.pop(account_id, None)
                entry.reader.close()
            finally:
                entry.lock.release()
