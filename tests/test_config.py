from gmail_reader.config import ConfigurationError, Settings


def test_settings_removes_spaces_from_app_password(monkeypatch):
    monkeypatch.setenv("GMAIL_ADDRESS", "person@gmail.com")
    monkeypatch.setenv("GMAIL_APP_PASSWORD", "abcd efgh ijkl mnop")

    settings = Settings.from_env()

    assert settings.address == "person@gmail.com"
    assert settings.app_password == "abcdefghijklmnop"


def test_settings_requires_address(monkeypatch):
    monkeypatch.setenv("GMAIL_ADDRESS", "")
    monkeypatch.setenv("GMAIL_APP_PASSWORD", "abcdefghijklmnop")

    try:
        Settings.from_env()
    except ConfigurationError as exc:
        assert "GMAIL_ADDRESS" in str(exc)
    else:
        raise AssertionError("ConfigurationError was not raised")


def test_proxy_settings(monkeypatch):
    monkeypatch.setenv("GMAIL_ADDRESS", "person@gmail.com")
    monkeypatch.setenv("GMAIL_APP_PASSWORD", "abcdefghijklmnop")
    monkeypatch.setenv("GMAIL_PROXY_TYPE", "socks5")
    monkeypatch.setenv("GMAIL_PROXY_HOST", "127.0.0.1")
    monkeypatch.setenv("GMAIL_PROXY_PORT", "6153")

    settings = Settings.from_env()

    assert settings.proxy is not None
    assert settings.proxy.kind == "socks5"
    assert settings.proxy.port == 6153
    assert settings.proxy.rdns is True
