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


def test_search_uses_gmail_full_archive_and_paginates():
    class SearchClient:
        def __init__(self):
            self.criteria = None
            self.selected = None

        def list_folders(self):
            return [([b"\\All"], b"/", "[Gmail]/All Mail")]

        def select_folder(self, folder, readonly):
            self.selected = (folder, readonly)

        def search(self, criteria, charset=None):
            self.criteria = (criteria, charset)
            return list(range(1, 121))

        def fetch(self, uids, _fields):
            return {
                uid: {
                    b"BODY[HEADER.FIELDS (FROM TO SUBJECT DATE MESSAGE-ID)]": (
                        f"Subject: result {uid}\r\n\r\n".encode()
                    ),
                    b"FLAGS": (),
                }
                for uid in uids
            }

    client = SearchClient()
    reader = GmailReader(Settings("person@gmail.com", "password"))
    reader.client = client  # type: ignore[assignment]

    records, total = reader.search_page("Microsoft", page=2, limit=50)

    assert total == 120
    assert [record.uid for record in records] == list(range(21, 71))
    assert client.selected == ("[Gmail]/All Mail", True)
    assert client.criteria == (["X-GM-RAW", "Microsoft"], "UTF-8")
