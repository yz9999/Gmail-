from __future__ import annotations

import smtplib
import socket
import ssl

import socks
from imapclient import IMAPClient, tls

from .config import ProxySettings


def _proxy_type(kind: str) -> int:
    return {
        "socks5": socks.SOCKS5,
        "socks4": socks.SOCKS4,
        "http": socks.HTTP,
    }[kind]


def create_proxy_socket(
    proxy: ProxySettings,
    destination_host: str,
    destination_port: int,
    timeout: float | None,
) -> socket.socket:
    sock = socks.socksocket()
    sock.set_proxy(
        proxy_type=_proxy_type(proxy.kind),
        addr=proxy.host,
        port=proxy.port,
        rdns=proxy.rdns,
        username=proxy.username,
        password=proxy.password,
    )
    if timeout is not None:
        sock.settimeout(timeout)
    sock.connect((destination_host, destination_port))
    return sock


class _ProxyIMAP4TLS(tls.IMAP4_TLS):
    def __init__(
        self,
        host: str,
        port: int,
        ssl_context: ssl.SSLContext | None,
        timeout: float | None,
        proxy: ProxySettings,
    ) -> None:
        self.proxy = proxy
        super().__init__(host, port, ssl_context, timeout)

    def _create_socket(self, timeout: float | None) -> socket.socket:
        sock = create_proxy_socket(self.proxy, self.host, self.port, timeout)
        return tls.wrap_socket(sock, self.ssl_context, self.host)


class ProxyIMAPClient(IMAPClient):
    def __init__(self, *args: object, proxy: ProxySettings, **kwargs: object) -> None:
        self.proxy = proxy
        super().__init__(*args, **kwargs)

    def _create_IMAP4(self):  # type: ignore[no-untyped-def]
        connect_timeout = getattr(self._timeout, "connect", None)
        return _ProxyIMAP4TLS(
            self.host,
            self.port,
            self.ssl_context,
            connect_timeout,
            self.proxy,
        )


class ProxySMTPSSL(smtplib.SMTP_SSL):
    def __init__(self, *args: object, proxy: ProxySettings, **kwargs: object) -> None:
        self.proxy = proxy
        super().__init__(*args, **kwargs)

    def _get_socket(self, host: str, port: int, timeout: float) -> socket.socket:
        sock = create_proxy_socket(self.proxy, host, port, timeout)
        return self.context.wrap_socket(sock, server_hostname=host)
