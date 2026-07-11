from __future__ import annotations

import os
from dataclasses import dataclass

from dotenv import load_dotenv


class ConfigurationError(ValueError):
    """Raised when required configuration is missing or invalid."""


@dataclass(frozen=True, slots=True)
class ProxySettings:
    kind: str
    host: str
    port: int
    rdns: bool = True
    username: str | None = None
    password: str | None = None


@dataclass(frozen=True, slots=True)
class Settings:
    address: str
    app_password: str
    folder: str = "INBOX"
    host: str = "imap.gmail.com"
    port: int = 993
    smtp_host: str = "smtp.gmail.com"
    smtp_port: int = 465
    proxy: ProxySettings | None = None

    @classmethod
    def from_env(cls) -> "Settings":
        load_dotenv()

        address = os.getenv("GMAIL_ADDRESS", "").strip()
        # Google often displays app passwords in four groups. Spaces are cosmetic.
        app_password = "".join(os.getenv("GMAIL_APP_PASSWORD", "").split())
        if not address or "@" not in address:
            raise ConfigurationError("请在 .env 中设置有效的 GMAIL_ADDRESS")
        if not app_password:
            raise ConfigurationError("请在 .env 中设置 GMAIL_APP_PASSWORD")
        return cls.from_credentials(address, app_password)

    @classmethod
    def from_credentials(cls, address: str, app_password: str) -> "Settings":
        """Build account settings using credentials plus shared environment options."""
        load_dotenv()

        address = address.strip()
        app_password = "".join(app_password.split())
        folder = os.getenv("GMAIL_FOLDER", "INBOX").strip() or "INBOX"
        host = os.getenv("GMAIL_IMAP_HOST", "imap.gmail.com").strip() or "imap.gmail.com"
        raw_port = os.getenv("GMAIL_IMAP_PORT", "993").strip()
        smtp_host = os.getenv("GMAIL_SMTP_HOST", "smtp.gmail.com").strip() or "smtp.gmail.com"
        raw_smtp_port = os.getenv("GMAIL_SMTP_PORT", "465").strip()
        proxy_kind = os.getenv("GMAIL_PROXY_TYPE", "").strip().lower()

        if not address or "@" not in address:
            raise ConfigurationError("请输入有效的 Gmail 地址")
        if not app_password:
            raise ConfigurationError("请输入应用专用密码")

        try:
            port = int(raw_port)
            smtp_port = int(raw_smtp_port)
        except ValueError as exc:
            raise ConfigurationError("IMAP/SMTP 端口必须是数字") from exc

        if not 1 <= port <= 65535:
            raise ConfigurationError("GMAIL_IMAP_PORT 必须在 1 到 65535 之间")
        if not 1 <= smtp_port <= 65535:
            raise ConfigurationError("GMAIL_SMTP_PORT 必须在 1 到 65535 之间")

        proxy = None
        if proxy_kind:
            if proxy_kind not in {"socks5", "socks4", "http"}:
                raise ConfigurationError("GMAIL_PROXY_TYPE 只支持 socks5、socks4 或 http")
            proxy_host = os.getenv("GMAIL_PROXY_HOST", "127.0.0.1").strip()
            try:
                proxy_port = int(os.getenv("GMAIL_PROXY_PORT", "").strip())
            except ValueError as exc:
                raise ConfigurationError("GMAIL_PROXY_PORT 必须是数字") from exc
            if not proxy_host or not 1 <= proxy_port <= 65535:
                raise ConfigurationError("请设置有效的代理地址和端口")
            rdns = os.getenv("GMAIL_PROXY_RDNS", "true").strip().lower() not in {
                "0",
                "false",
                "no",
                "off",
            }
            proxy = ProxySettings(
                kind=proxy_kind,
                host=proxy_host,
                port=proxy_port,
                rdns=rdns,
                username=os.getenv("GMAIL_PROXY_USERNAME") or None,
                password=os.getenv("GMAIL_PROXY_PASSWORD") or None,
            )

        return cls(
            address=address,
            app_password=app_password,
            folder=folder,
            host=host,
            port=port,
            smtp_host=smtp_host,
            smtp_port=smtp_port,
            proxy=proxy,
        )
