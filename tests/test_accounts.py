import json
import stat
from concurrent.futures import ThreadPoolExecutor

from gmail_reader.accounts import AccountStore


def test_account_store_add_and_delete(tmp_path, monkeypatch):
    monkeypatch.setenv("GMAIL_ADDRESS", "")
    monkeypatch.setenv("GMAIL_APP_PASSWORD", "")
    path = tmp_path / "accounts.json"
    store = AccountStore(path)

    account = store.add("工作", "work@gmail.com", "abcd efgh ijkl mnop")

    assert store.get(account.id).address == "work@gmail.com"
    assert store.get(account.id).app_password == "abcdefghijklmnop"
    assert stat.S_IMODE(path.stat().st_mode) == 0o600
    payload = json.loads(path.read_text(encoding="utf-8"))
    assert payload["accounts"][0]["name"] == "工作"

    store.delete(account.id)
    assert store.list_accounts() == []


def test_environment_account_is_not_deletable(tmp_path, monkeypatch):
    monkeypatch.setenv("GMAIL_ADDRESS", "person@gmail.com")
    monkeypatch.setenv("GMAIL_APP_PASSWORD", "abcdefghijklmnop")
    store = AccountStore(tmp_path / "accounts.json")

    account = store.list_accounts()[0]

    assert account.id == "env"
    assert account.public_dict()["deletable"] is False


def test_concurrent_account_writes_do_not_lose_records(tmp_path, monkeypatch):
    monkeypatch.setenv("GMAIL_ADDRESS", "")
    monkeypatch.setenv("GMAIL_APP_PASSWORD", "")
    store = AccountStore(tmp_path / "accounts.json")

    with ThreadPoolExecutor(max_workers=8) as executor:
        list(
            executor.map(
                lambda index: store.add(
                    f"账号 {index}", f"person{index}@gmail.com", "abcdefghijklmnop"
                ),
                range(24),
            )
        )

    accounts = store.list_accounts()
    assert len(accounts) == 24
    assert len({account.address for account in accounts}) == 24
