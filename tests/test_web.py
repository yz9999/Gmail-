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
