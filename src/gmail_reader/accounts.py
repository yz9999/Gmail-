from __future__ import annotations

import json
import os
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from dotenv import load_dotenv

from .config import ConfigurationError, Settings


@dataclass(frozen=True, slots=True)
class Account:
    id: str
    name: str
    address: str
    app_password: str
    source: str = "file"

    def public_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "name": self.name,
            "address": self.address,
            "source": self.source,
            "deletable": self.source == "file",
        }


class AccountStore:
    ENV_ACCOUNT_ID = "env"

    def __init__(self, path: str | Path | None = None) -> None:
        load_dotenv()
        configured = path or os.getenv("GMAIL_ACCOUNTS_FILE", "accounts.json")
        self.path = Path(configured).expanduser()

    def list_accounts(self) -> list[Account]:
        accounts: list[Account] = []
        env_account = self._environment_account()
        if env_account:
            accounts.append(env_account)
        accounts.extend(self._file_accounts())
        return accounts

    def get(self, account_id: str | None) -> Account:
        accounts = self.list_accounts()
        if not accounts:
            raise ConfigurationError("尚未配置 Gmail 账号，请先添加账号")
        if not account_id:
            return accounts[0]
        for account in accounts:
            if account.id == account_id:
                return account
        raise ConfigurationError("所选 Gmail 账号不存在，请重新选择")

    def settings(self, account_id: str | None) -> Settings:
        account = self.get(account_id)
        return Settings.from_credentials(account.address, account.app_password)

    def add(self, name: str, address: str, app_password: str) -> Account:
        address = address.strip().lower()
        password = "".join(app_password.split())
        Settings.from_credentials(address, password)

        if any(item.address.lower() == address for item in self.list_accounts()):
            raise ConfigurationError("这个 Gmail 账号已经存在")

        account = Account(
            id=uuid.uuid4().hex,
            name=name.strip() or address.split("@", 1)[0],
            address=address,
            app_password=password,
        )
        accounts = self._file_accounts()
        accounts.append(account)
        self._write(accounts)
        return account

    def delete(self, account_id: str) -> None:
        if account_id == self.ENV_ACCOUNT_ID:
            raise ConfigurationError(".env 默认账号不能在网页删除")
        accounts = self._file_accounts()
        remaining = [item for item in accounts if item.id != account_id]
        if len(remaining) == len(accounts):
            raise ConfigurationError("账号不存在")
        self._write(remaining)

    def _environment_account(self) -> Account | None:
        address = os.getenv("GMAIL_ADDRESS", "").strip()
        password = "".join(os.getenv("GMAIL_APP_PASSWORD", "").split())
        if not address or not password:
            return None
        return Account(
            id=self.ENV_ACCOUNT_ID,
            name=os.getenv("GMAIL_ACCOUNT_NAME", "").strip() or address.split("@", 1)[0],
            address=address,
            app_password=password,
            source="env",
        )

    def _file_accounts(self) -> list[Account]:
        if not self.path.exists():
            return []
        try:
            payload = json.loads(self.path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            raise ConfigurationError(f"无法读取多账号配置文件：{exc}") from exc

        raw_accounts = payload.get("accounts", []) if isinstance(payload, dict) else []
        accounts: list[Account] = []
        for item in raw_accounts:
            if not isinstance(item, dict):
                continue
            try:
                accounts.append(
                    Account(
                        id=str(item["id"]),
                        name=str(item.get("name", "")),
                        address=str(item["address"]),
                        app_password=str(item["app_password"]),
                    )
                )
            except KeyError:
                continue
        return accounts

    def _write(self, accounts: list[Account]) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        payload = {
            "version": 1,
            "accounts": [
                {
                    "id": account.id,
                    "name": account.name,
                    "address": account.address,
                    "app_password": account.app_password,
                }
                for account in accounts
            ],
        }
        temporary = self.path.with_name(f"{self.path.name}.tmp")
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        try:
            with os.fdopen(descriptor, "w", encoding="utf-8") as file:
                json.dump(payload, file, ensure_ascii=False, indent=2)
                file.write("\n")
            os.replace(temporary, self.path)
            os.chmod(self.path, 0o600)
        finally:
            if temporary.exists():
                temporary.unlink()
