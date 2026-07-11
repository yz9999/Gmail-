import pytest

from gmail_reader.client import GmailReader
from gmail_reader.config import Settings


class FakeIMAPClient:
    def __init__(self):
        self.added_flags = None

    def select_folder(self, folder, readonly):
        assert folder == "INBOX"
        assert readonly is False

    def search(self, criteria):
        assert criteria == ["UNSEEN"]
        return [10, 11, 12]

    def add_flags(self, uids, flags, silent):
        self.added_flags = (uids, flags, silent)


def test_mark_all_read_marks_all_unseen_messages():
    reader = GmailReader(Settings("person@gmail.com", "abcdefghijklmnop"))
    fake = FakeIMAPClient()
    reader.client = fake  # type: ignore[assignment]

    count = reader.mark_all_read("inbox")

    assert count == 3
    assert fake.added_flags == ([10, 11, 12], [b"\\Seen"], True)


def test_failed_login_closes_partially_open_connection(monkeypatch):
    clients = []

    class FailingClient:
        def __init__(self, *_args, **_kwargs):
            self.shutdown_called = False
            clients.append(self)

        def login(self, _address, _password):
            raise OSError("login failed")

        def shutdown(self):
            self.shutdown_called = True

    monkeypatch.setattr("gmail_reader.client.IMAPClient", FailingClient)
    reader = GmailReader(Settings("person@gmail.com", "password"))

    with pytest.raises(OSError):
        reader.connect()

    assert reader.client is None
    assert clients[0].shutdown_called is True


def test_close_forces_shutdown_when_logout_fails():
    class BrokenLogoutClient:
        def __init__(self):
            self.shutdown_called = False

        def logout(self):
            raise OSError("connection lost")

        def shutdown(self):
            self.shutdown_called = True

    client = BrokenLogoutClient()
    reader = GmailReader(Settings("person@gmail.com", "password"))
    reader.client = client  # type: ignore[assignment]

    reader.close()

    assert reader.client is None
    assert client.shutdown_called is True


def test_full_messages_are_fetched_in_bounded_batches():
    class BatchClient:
        def __init__(self):
            self.batches = []

        def fetch(self, uids, _fields):
            self.batches.append(list(uids))
            return {
                uid: {b"RFC822": b"Subject: test\r\n\r\nbody", b"FLAGS": ()}
                for uid in uids
            }

    client = BatchClient()
    reader = GmailReader(Settings("person@gmail.com", "password"))
    reader.client = client  # type: ignore[assignment]

    records = reader._fetch_uids(range(1, 13))

    assert len(records) == 12
    assert client.batches == [list(range(1, 6)), list(range(6, 11)), [11, 12]]
