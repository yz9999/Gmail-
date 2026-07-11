from __future__ import annotations

import hmac
import ipaddress
import os
import re
import secrets
import smtplib
from email.utils import getaddresses

from flask import Flask, Response, jsonify, render_template, request
from imapclient.exceptions import IMAPClientError, LoginError
from dotenv import load_dotenv

from .accounts import AccountStore
from .client import GmailReader
from .config import ConfigurationError, Settings
from .pool import GmailConnectionPool


def create_app() -> Flask:
    load_dotenv()
    configured_token = os.getenv("GMAIL_WEB_TOKEN", "").strip()
    if configured_token and len(configured_token) < 24:
        raise ConfigurationError("GMAIL_WEB_TOKEN 至少需要 24 个字符")
    app = Flask(__name__)
    app.json.ensure_ascii = False
    app.config["MAX_CONTENT_LENGTH"] = 10 * 1024 * 1024
    app.config["TRUSTED_HOSTS"] = ["localhost", "127.0.0.1", "::1"]
    app.config["GMAIL_WEB_TOKEN"] = configured_token or secrets.token_urlsafe(32)
    account_store = AccountStore()
    connection_pool = GmailConnectionPool(account_store)

    @app.before_request
    def require_web_authentication():
        if request.remote_addr and not _is_loopback_host(request.remote_addr):
            return jsonify({"error": "只允许从本机访问"}), 403
        authorization = request.authorization
        valid = (
            authorization is not None
            and (authorization.type or "").lower() == "basic"
            and hmac.compare_digest(authorization.username or "", "gmail")
            and hmac.compare_digest(
                authorization.password or "", app.config["GMAIL_WEB_TOKEN"]
            )
        )
        if valid:
            return None

        if request.path.startswith("/api/"):
            response = jsonify({"error": "需要 Web 登录认证"})
            response.status_code = 401
        else:
            response = Response("需要登录 Gmail Reader", status=401, mimetype="text/plain")
        response.headers["WWW-Authenticate"] = 'Basic realm="Gmail Reader", charset="UTF-8"'
        return response

    @app.after_request
    def security_headers(response):
        response.headers["X-Content-Type-Options"] = "nosniff"
        response.headers["X-Frame-Options"] = "DENY"
        response.headers["Referrer-Policy"] = "no-referrer"
        if (
            request.path == "/"
            or request.path.startswith("/api/")
            or request.path.endswith((".js", ".css"))
        ):
            response.headers["Cache-Control"] = "no-store"
        return response

    @app.get("/")
    def index():
        address = os.getenv("GMAIL_ADDRESS", "").strip()
        return render_template("index.html", address=address)

    @app.get("/api/accounts")
    def accounts():
        return jsonify([account.public_dict() for account in account_store.list_accounts()])

    @app.post("/api/accounts")
    def add_account():
        payload = _json_object()
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
        account_store.delete(account_id)
        connection_pool.close(account_id)
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
        query = request.args.get("q", "").strip()
        limit = min(max(request.args.get("limit", 30, type=int), 1), 100)
        page = max(request.args.get("page", 1, type=int), 1)
        if query:
            records, total = connection_pool.execute(
                request.args.get("account"),
                lambda reader: reader.search_page(query=query, page=page, limit=limit),
            )
        else:
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
                "query": query,
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
        payload = _json_object()
        view = str(payload.get("view", "inbox"))
        action = str(payload.get("action", ""))
        connection_pool.execute(
            str(payload.get("account", "")) or None,
            lambda reader: reader.update_flags(uid, view, action),
        )
        return jsonify({"ok": True})

    @app.post("/api/messages/mark-all-read")
    def mark_all_read():
        payload = _json_object()
        view = str(payload.get("view", "inbox"))
        query = str(payload.get("q", "")).strip()
        count = connection_pool.execute(
            str(payload.get("account", "")) or None,
            lambda reader: (
                reader.mark_search_read(query) if query else reader.mark_all_read(view)
            ),
        )
        return jsonify({"ok": True, "count": count})

    @app.post("/api/send")
    def send():
        payload = _json_object()
        raw_to = str(payload.get("to", ""))
        recipients = [address for _name, address in getaddresses([raw_to]) if address]
        subject = str(payload.get("subject", "")).strip()
        body = str(payload.get("body", ""))

        if not recipients or any(not _valid_email(item) for item in recipients):
            return jsonify({"error": "请输入有效的收件人邮箱"}), 400
        if len(subject) > 998:
            return jsonify({"error": "邮件主题过长"}), 400

        settings = account_store.settings(str(payload.get("account", "")) or None)
        GmailReader(settings).send_message(recipients, subject, body)
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


def _json_object() -> dict[str, object]:
    payload = request.get_json()
    if not isinstance(payload, dict):
        raise ValueError("JSON 请求体必须是对象")
    return payload


def _is_loopback_host(host: str) -> bool:
    if host.casefold() == "localhost":
        return True
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return False


def main() -> None:
    app = create_app()
    host = os.getenv("GMAIL_WEB_HOST", "127.0.0.1")
    port = int(os.getenv("GMAIL_WEB_PORT", "5001"))
    if not _is_loopback_host(host):
        raise ConfigurationError("GMAIL_WEB_HOST 只允许 localhost 或回环地址")
    print("Web 登录用户名: gmail", flush=True)
    if os.getenv("GMAIL_WEB_TOKEN", "").strip():
        print("Web 登录密码: 使用 .env 中的 GMAIL_WEB_TOKEN", flush=True)
    else:
        print(f"Web 登录密码: {app.config['GMAIL_WEB_TOKEN']}", flush=True)
    app.run(host=host, port=port, debug=False)


if __name__ == "__main__":
    main()
