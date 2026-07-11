import base64

from gmail_reader.web import _is_loopback_host, create_app

WEB_TOKEN = "test-web-token-with-at-least-24-characters"


def auth_headers(**extra):
    encoded = base64.b64encode(f"gmail:{WEB_TOKEN}".encode()).decode()
    return {"Authorization": f"Basic {encoded}", **extra}


def configure_token(monkeypatch):
    monkeypatch.setenv("GMAIL_WEB_TOKEN", WEB_TOKEN)


def test_index_renders_gmail_interface(monkeypatch):
    configure_token(monkeypatch)
    monkeypatch.setenv("GMAIL_ADDRESS", "person@gmail.com")
    app = create_app()
    app.config.update(TESTING=True)

    response = app.test_client().get("/", headers=auth_headers())

    assert response.status_code == 200
    assert "Gmail" in response.get_data(as_text=True)
    assert "写邮件" in response.get_data(as_text=True)


def test_send_rejects_invalid_recipient(monkeypatch):
    configure_token(monkeypatch)
    app = create_app()
    app.config.update(TESTING=True)

    response = app.test_client().post(
        "/api/send",
        json={"to": "not-an-email", "subject": "Test", "body": "Body"},
        headers=auth_headers(),
    )

    assert response.status_code == 400
    assert response.get_json()["error"] == "请输入有效的收件人邮箱"


def test_sensitive_responses_are_not_cached(monkeypatch):
    configure_token(monkeypatch)
    monkeypatch.setenv("GMAIL_ADDRESS", "person@gmail.com")
    monkeypatch.setenv("GMAIL_APP_PASSWORD", "abcdefghijklmnop")
    app = create_app()
    app.config.update(TESTING=True)

    response = app.test_client().get("/", headers=auth_headers())

    assert response.headers["Cache-Control"] == "no-store"
    assert response.headers["X-Frame-Options"] == "DENY"
    assert response.headers["X-Content-Type-Options"] == "nosniff"


def test_untrusted_host_is_rejected(monkeypatch):
    configure_token(monkeypatch)
    app = create_app()
    app.config.update(TESTING=True)

    response = app.test_client().get(
        "/", headers=auth_headers(Host="attacker.example")
    )

    assert response.status_code == 400


def test_state_changing_routes_require_json_content_type(monkeypatch):
    configure_token(monkeypatch)
    app = create_app()
    app.config.update(TESTING=True)

    response = app.test_client().post(
        "/api/messages/mark-all-read",
        data="view=inbox",
        content_type="application/x-www-form-urlencoded",
        headers=auth_headers(),
    )

    assert response.status_code == 415


def test_json_arrays_are_rejected(monkeypatch):
    configure_token(monkeypatch)
    app = create_app()
    app.config.update(TESTING=True)

    response = app.test_client().post(
        "/api/send", json=[], headers=auth_headers()
    )

    assert response.status_code == 400


def test_web_requires_basic_authentication(monkeypatch):
    configure_token(monkeypatch)
    app = create_app()
    app.config.update(TESTING=True)

    response = app.test_client().get("/")

    assert response.status_code == 401
    assert response.headers["WWW-Authenticate"].startswith("Basic ")


def test_weak_web_token_is_rejected(monkeypatch):
    monkeypatch.setenv("GMAIL_WEB_TOKEN", "too-short")

    try:
        create_app()
    except ValueError as exc:
        assert "至少需要 24" in str(exc)
    else:
        raise AssertionError("weak token was accepted")


def test_only_loopback_hosts_are_allowed():
    assert _is_loopback_host("127.0.0.1") is True
    assert _is_loopback_host("::1") is True
    assert _is_loopback_host("localhost") is True
    assert _is_loopback_host("0.0.0.0") is False
    assert _is_loopback_host("192.168.1.20") is False


def test_remote_clients_are_rejected(monkeypatch):
    configure_token(monkeypatch)
    app = create_app()
    app.config.update(TESTING=True)

    response = app.test_client().get(
        "/",
        headers=auth_headers(),
        environ_overrides={"REMOTE_ADDR": "192.168.1.20"},
    )

    assert response.status_code == 403
