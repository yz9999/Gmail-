from gmail_reader.web import create_app


def test_index_renders_gmail_interface(monkeypatch):
    monkeypatch.setenv("GMAIL_ADDRESS", "person@gmail.com")
    app = create_app()
    app.config.update(TESTING=True)

    response = app.test_client().get("/")

    assert response.status_code == 200
    assert "Gmail" in response.get_data(as_text=True)
    assert "写邮件" in response.get_data(as_text=True)


def test_send_rejects_invalid_recipient(monkeypatch):
    app = create_app()
    app.config.update(TESTING=True)

    response = app.test_client().post(
        "/api/send", json={"to": "not-an-email", "subject": "Test", "body": "Body"}
    )

    assert response.status_code == 400
    assert response.get_json()["error"] == "请输入有效的收件人邮箱"


def test_sensitive_responses_are_not_cached(monkeypatch):
    monkeypatch.setenv("GMAIL_ADDRESS", "person@gmail.com")
    monkeypatch.setenv("GMAIL_APP_PASSWORD", "abcdefghijklmnop")
    app = create_app()
    app.config.update(TESTING=True)

    response = app.test_client().get("/")

    assert response.headers["Cache-Control"] == "no-store"
    assert response.headers["X-Frame-Options"] == "DENY"
    assert response.headers["X-Content-Type-Options"] == "nosniff"


def test_untrusted_host_is_rejected():
    app = create_app()
    app.config.update(TESTING=True)

    response = app.test_client().get("/", headers={"Host": "attacker.example"})

    assert response.status_code == 400


def test_state_changing_routes_require_json_content_type():
    app = create_app()
    app.config.update(TESTING=True)

    response = app.test_client().post(
        "/api/messages/mark-all-read",
        data="view=inbox",
        content_type="application/x-www-form-urlencoded",
    )

    assert response.status_code == 415
