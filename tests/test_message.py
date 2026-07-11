from gmail_reader.message import parse_email


def test_parse_plain_text_email():
    raw = (
        b"From: Sender <sender@example.com>\r\n"
        b"To: receiver@gmail.com\r\n"
        b"Subject: Test message\r\n"
        b"Message-ID: <123@example.com>\r\n"
        b"Content-Type: text/plain; charset=utf-8\r\n"
        b"\r\n"
        b"Hello from Gmail.\r\n"
    )

    record = parse_email(42, raw, ("\\Seen",))

    assert record.uid == 42
    assert record.subject == "Test message"
    assert record.sender == "Sender <sender@example.com>"
    assert record.body == "Hello from Gmail."
    assert record.body_html == ""
    assert record.flags == ("\\Seen",)


def test_parse_html_fallback():
    raw = (
        b"From: sender@example.com\r\n"
        b"Subject: HTML\r\n"
        b"Content-Type: text/html; charset=utf-8\r\n"
        b"\r\n"
        b"<p>Hello <strong>world</strong></p>"
    )

    record = parse_email(1, raw)

    assert record.body == "Hello world"
    assert "<strong>world</strong>" in record.body_html
