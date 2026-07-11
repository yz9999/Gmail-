from __future__ import annotations

import os
import re
import smtplib
from email.utils import getaddresses

from flask import Flask, jsonify, render_template, request
from imapclient.exceptions import IMAPClientError, LoginError
from dotenv import load_dotenv

from .accounts import AccountStore
from .client import GmailReader
from .config import ConfigurationError, Settings
from .pool import GmailConnectionPool


def create_app() -> Flask:
    load_dotenv()
    app = Flask(__name__)
    app.json.ensure_ascii = False
    account_store = AccountStore()
    connection_pool = GmailConnectionPool(account_store)

    @app.get("/")
    def index():
        address = os.getenv("GMAIL_ADDRESS", "").strip()
        return render_template("index.html", address=address)

    @app.get("/api/accounts")
    def accounts():
        return jsonify([account.public_dict() for account in account_store.list_accounts()])

    @app.post("/api/accounts")
    def add_account():
        payload = request.get_json(silent=True) or {}
        name = str(payload.get("name", ""))
        address = str(payload.get("address", ""))
        app_password = str(payload.get("app_password", ""))

        settings = Settings.from_credentials(address, app_password)
        with GmailReader(settings) as reader:
            status = reader.check()
        account = account_store.add(name, address, app_password)
        return jsonify({"account": account.public_dict(), "status": status}), 201

    @app.delete("/api/accounts/<account_id>")
    def delete_account(account_id: str):
        connection_pool.close(account_id)
        account_store.delete(account_id)
        return jsonify({"ok": True})

    @app.get("/api/account")
    def account():
        result = connection_pool.execute(
            request.args.get("account"), lambda reader: reader.check()
        )
        return jsonify(result)

    @app.get("/api/messages")
    def messages():
        view = request.args.get("view", "inbox")
        limit = min(max(request.args.get("limit", 30, type=int), 1), 100)
        page = max(request.args.get("page", 1, type=int), 1)
        records, total = connection_pool.execute(
            request.args.get("account"),
            lambda reader: reader.fetch_view_page(view=view, page=page, limit=limit),
        )
        return jsonify(
            {
                "messages": [record.to_dict() for record in reversed(records)],
                "page": page,
                "page_size": limit,
                "total": total,
                "has_previous": page > 1,
                "has_next": page * limit < total,
            }
        )

    @app.get("/api/messages/<int:uid>")
    def message(uid: int):
        view = request.args.get("view", "inbox")
        record = connection_pool.execute(
            request.args.get("account"), lambda reader: reader.fetch_one(uid, view=view)
        )
        if record is None:
            return jsonify({"error": "邮件不存在或已经移动"}), 404
        return jsonify(record.to_dict())

    @app.post("/api/messages/<int:uid>/flags")
    def flags(uid: int):
        payload = request.get_json(silent=True) or {}
        view = str(payload.get("view", "inbox"))
        action = str(payload.get("action", ""))
        connection_pool.execute(
            str(payload.get("account", "")) or None,
            lambda reader: reader.update_flags(uid, view, action),
        )
        return jsonify({"ok": True})

    @app.post("/api/messages/mark-all-read")
    def mark_all_read():
        payload = request.get_json(silent=True) or {}
        view = str(payload.get("view", "inbox"))
        count = connection_pool.execute(
            str(payload.get("account", "")) or None,
            lambda reader: reader.mark_all_read(view),
        )
        return jsonify({"ok": True, "count": count})

    @app.post("/api/send")
    def send():
        payload = request.get_json(silent=True) or {}
        raw_to = str(payload.get("to", ""))
        recipients = [address for _name, address in getaddresses([raw_to]) if address]
        subject = str(payload.get("subject", "")).strip()
        body = str(payload.get("body", ""))

        if not recipients or any(not _valid_email(item) for item in recipients):
            return jsonify({"error": "请输入有效的收件人邮箱"}), 400
        if len(subject) > 998:
            return jsonify({"error": "邮件主题过长"}), 400

        connection_pool.execute(
            str(payload.get("account", "")) or None,
            lambda reader: reader.send_message(recipients, subject, body),
        )
        return jsonify({"ok": True})

    @app.errorhandler(ConfigurationError)
    def configuration_error(exc: ConfigurationError):
        return jsonify({"error": str(exc), "code": "configuration_error"}), 503

    @app.errorhandler(LoginError)
    def login_error(_exc: LoginError):
        return jsonify({"error": "Gmail 登录失败，请检查邮箱和应用专用密码"}), 401

    @app.errorhandler(IMAPClientError)
    def imap_error(exc: IMAPClientError):
        return jsonify({"error": f"Gmail 服务错误：{exc}"}), 502

    @app.errorhandler(smtplib.SMTPException)
    def smtp_error(exc: smtplib.SMTPException):
        return jsonify({"error": f"邮件发送失败：{exc}"}), 502

    @app.errorhandler(OSError)
    def network_error(exc: OSError):
        return jsonify({"error": f"无法连接 Gmail：{exc}"}), 502

    @app.errorhandler(ValueError)
    def value_error(exc: ValueError):
        return jsonify({"error": str(exc)}), 400

    return app


def _valid_email(value: str) -> bool:
    return bool(re.fullmatch(r"[^\s@]+@[^\s@]+\.[^\s@]+", value))


def main() -> None:
    app = create_app()
    host = os.getenv("GMAIL_WEB_HOST", "127.0.0.1")
    port = int(os.getenv("GMAIL_WEB_PORT", "5001"))
    app.run(host=host, port=port, debug=False)


if __name__ == "__main__":
    main()
