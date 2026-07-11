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
