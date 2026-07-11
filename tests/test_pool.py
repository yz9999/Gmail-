import gc
import threading
import time
import weakref

import pytest

from gmail_reader.accounts import Account
from gmail_reader.config import Settings
from gmail_reader.pool import GmailConnectionPool


class FakeAccountStore:
    def get(self, account_id):
        account_id = account_id or "a"
        return Account(account_id, account_id, f"{account_id}@gmail.com", "password")

    def settings(self, account_id):
        return Settings(f"{account_id}@gmail.com", "password")


class FakeReader:
    instances = []

    def __init__(self, settings):
        self.settings = settings
        self.client = None
        self.close_count = 0
        self.__class__.instances.append(self)

    def connect(self):
        self.client = object()

    def close(self):
        self.client = None
        self.close_count += 1


def test_pool_never_exceeds_connection_cap_when_all_entries_are_busy(monkeypatch):
    monkeypatch.setattr("gmail_reader.pool.GmailReader", FakeReader)
    FakeReader.instances.clear()
    pool = GmailConnectionPool(FakeAccountStore(), max_connections=2, idle_timeout=0)
    pool.execute("a", lambda _reader: None)
    pool.execute("b", lambda _reader: None)

    entered = threading.Barrier(3)
    release = threading.Event()

    def hold(account_id):
        pool.execute(account_id, lambda _reader: (entered.wait(), release.wait()))

    holders = [threading.Thread(target=hold, args=(account,)) for account in ("a", "b")]
    for thread in holders:
        thread.start()
    entered.wait(timeout=2)

    newcomer = threading.Thread(target=lambda: pool.execute("c", lambda _reader: None))
    newcomer.start()
    time.sleep(0.05)
    assert len(pool._entries) == 2

    release.set()
    for thread in holders:
        thread.join(timeout=2)
    newcomer.join(timeout=2)
    assert not newcomer.is_alive()
    assert len(pool._entries) == 2
    assert "c" in pool._entries
    pool.close_all()


def test_pool_registry_does_not_keep_discarded_pool_alive(monkeypatch):
    monkeypatch.setattr("gmail_reader.pool.GmailReader", FakeReader)
    FakeReader.instances.clear()
    pool = GmailConnectionPool(FakeAccountStore(), idle_timeout=0)
    pool.execute("a", lambda _reader: None)
    reader = FakeReader.instances[-1]
    reference = weakref.ref(pool)

    del pool
    gc.collect()

    assert reference() is None
    assert reader.client is None
    assert reader.close_count >= 1


def test_pool_recovers_on_request_after_failed_reconnect(monkeypatch):
    class FlakyReader:
        def __init__(self, settings):
            self.settings = settings
            self.client = None
            self.connect_calls = 0

        def connect(self):
            self.connect_calls += 1
            if self.connect_calls == 2:
                raise OSError("temporary reconnect failure")
            self.client = object()

        def close(self):
            self.client = None

    monkeypatch.setattr("gmail_reader.pool.GmailReader", FlakyReader)
    pool = GmailConnectionPool(FakeAccountStore(), idle_timeout=0)

    with pytest.raises(OSError):
        pool.execute("a", lambda _reader: (_ for _ in ()).throw(OSError("lost")))

    result = pool.execute("a", lambda _reader: "recovered")

    assert result == "recovered"
    pool.close_all()
