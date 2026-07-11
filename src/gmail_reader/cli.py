from __future__ import annotations

import argparse
import json
import sys

from imapclient.exceptions import IMAPClientError, LoginError

from .client import GmailReader
from .config import ConfigurationError, Settings
from .message import EmailRecord


def _print_record(record: EmailRecord, as_json: bool) -> None:
    if as_json:
        print(json.dumps(record.to_dict(), ensure_ascii=False))
        return

    print("=" * 72)
    print(f"UID:     {record.uid}")
    print(f"发件人:  {record.sender}")
    print(f"收件人:  {record.recipients}")
    print(f"时间:    {record.date}")
    print(f"主题:    {record.subject}")
    print("-" * 72)
    print(record.body or "（无文本正文）")


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="通过应用专用密码获取 Gmail 邮件")
    subparsers = parser.add_subparsers(dest="command", required=True)

    subparsers.add_parser("check", help="检查登录、邮箱和 IDLE 支持")

    fetch = subparsers.add_parser("fetch", help="获取最近邮件")
    fetch.add_argument("--limit", type=int, default=10, help="最多获取几封（默认 10）")
    fetch.add_argument("--unread", action="store_true", help="只获取未读邮件")
    fetch.add_argument("--json", action="store_true", help="输出 JSON Lines")

    watch = subparsers.add_parser("watch", help="实时监听新邮件")
    watch.add_argument(
        "--include-existing", action="store_true", help="启动时同时输出现有未读邮件"
    )
    watch.add_argument("--json", action="store_true", help="输出 JSON Lines")

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = _build_parser()
    args = parser.parse_args(argv)

    if getattr(args, "limit", 1) < 1:
        parser.error("--limit 必须大于 0")

    try:
        settings = Settings.from_env()

        with GmailReader(settings) as reader:
            if args.command == "check":
                result = reader.check()
                print("连接成功")
                print(f"账号: {result['address']}")
                print(f"邮箱: {result['folder']}")
                print(f"邮件数: {result['messages']}")
                print(f"未读数: {result['unseen']}")
                print(f"支持实时 IDLE: {'是' if result['idle_supported'] else '否'}")
                return 0

            if args.command == "fetch":
                records = reader.fetch(limit=args.limit, unread_only=args.unread)
                for record in records:
                    _print_record(record, args.json)
                if not records and not args.json:
                    print("没有符合条件的邮件。")
                return 0

            if args.command == "watch":
                if not args.json:
                    print("正在监听新邮件，按 Ctrl+C 停止……", flush=True)
                reader.watch(
                    lambda record: _print_record(record, args.json),
                    include_existing=args.include_existing,
                )
                return 0

    except ConfigurationError as exc:
        print(f"配置错误：{exc}", file=sys.stderr)
        return 2
    except LoginError:
        print(
            "登录失败：请检查 Gmail 地址和 16 位应用专用密码，并确认账号允许 IMAP 登录。",
            file=sys.stderr,
        )
        return 3
    except IMAPClientError as exc:
        print(f"IMAP 错误：{exc}", file=sys.stderr)
        return 4
    except KeyboardInterrupt:
        print("\n已停止监听。", file=sys.stderr)
        return 130

    return 1


if __name__ == "__main__":
    raise SystemExit(main())

