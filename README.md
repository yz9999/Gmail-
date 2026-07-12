# Gmail Reader for macOS

使用 **Swift 5.9 + SwiftUI** 完全重写的原生 macOS Gmail 客户端。应用直接通过 IMAPS/SMTPS 与 Gmail 通信，不启动 Python、Flask、WebView 本地服务器，也不占用 `5001` 或其他本地端口。

## 功能

- Gmail 风格的原生 SwiftUI 界面
- Universal 2 应用，同时支持 Intel (`x86_64`) 和 Apple 芯片 (`arm64`)
- 多账号切换与账号管理
- 应用专用密码保存在 macOS 钥匙串
- 收件箱、未读、星标、已发送、草稿、所有邮件、垃圾邮件、回收站
- 每页 50 封邮件，可前后翻页
- 使用 Gmail `X-GM-RAW` 搜索整个邮箱，支持中文搜索
- HTML 邮件通过禁用 JavaScript 的 `WKWebView` 显示
- 邮件正文可使用 Google 翻译转为简体中文，并可随时切换原文/译文
- 标记已读/未读、星标、全部标记为已读
- 通过 Gmail SMTPS 写信
- 切换账号时取消旧任务，并用请求代次检查避免串号
- 默认直连 Gmail，也可选用 SOCKS5 hostname 代理
- TLS 主机名和系统证书链验证
- 列表搜索与 50 封摘要在同一条 TLS/IMAP 连接中完成
- 短时 UID/摘要缓存，翻页和重复搜索无需再扫描整个邮箱

## 系统要求

- macOS 12 或更高版本
- Swift 5.9 或 Xcode 15
- Gmail 已开启两步验证并生成 16 位应用专用密码
- 网络需能直接访问 Gmail；若当前网络不支持，可在设置中启用 SOCKS5 代理

## 构建

```bash
./scripts/build_app.sh
```

生成文件：

```text
dist/Gmail Reader.app
```

安装：

```bash
rm -rf "/Applications/Gmail Reader.app"
cp -R "dist/Gmail Reader.app" /Applications/
open "/Applications/Gmail Reader.app"
```

脚本会分别构建 `x86_64-apple-macosx12.0` 和 `arm64-apple-macosx12.0`，再合并为 Universal 2 可执行文件、创建标准 `.app` Bundle，并进行本机临时签名。正式分发时应改用 Developer ID 签名并完成 Apple 公证。

## 账号与迁移

首次启动时，如果以下旧版配置存在，应用会把账号元数据迁移到原生配置文件，并把应用专用密码写入 macOS 钥匙串：

```text
~/Library/Application Support/Gmail Reader/.env
~/Library/Application Support/Gmail Reader/accounts.json
```

迁移成功后会删除上述明文凭据文件。新版本账号元数据位于：

```text
~/Library/Application Support/Gmail Reader/native-accounts.json
```

该文件不含密码。钥匙串服务名为：

```text
com.yz9999.GmailReader.password
```

仓库根目录的 `.env`、`accounts.json`、构建目录和用户编辑器配置均被 `.gitignore` 排除。

## 网络实现

所有 IMAP 与 SMTP 请求均使用系统 `libcurl` 的 TLS 实现：

- `imaps://imap.gmail.com:993`
- `smtps://smtp.gmail.com:465`
- `CURLPROXY_SOCKS5_HOSTNAME`

邮件列表使用一条持续的 TLS/IMAP 会话，在同一连接内完成认证、`UID SEARCH` 和批量 `UID FETCH`，一次读取当页 50 封摘要。与旧版相比，首页不再预先请求文件夹列表，也不再为搜索结果重新建立第二条 TLS 连接。

中文等非 ASCII Gmail 搜索仍使用标准 IMAP UTF-8 literal，但底层已改为 `libcurl CONNECT_ONLY` 上的已验证 TLS 通道，不再使用已废弃的 Secure Transport socket 实现。关闭代理时会明确禁用环境代理，直接连接 Gmail；启用代理时使用 `CURLPROXY_SOCKS5_HOSTNAME`。

中文搜索发送：

```text
UID SEARCH CHARSET UTF-8 X-GM-RAW {字节数}
```

这样不会依赖会返回 Fake-IP 的本机 DNS，也不会关闭证书验证。

邮件翻译使用 Google 翻译的 HTTPS 服务，目标语言固定为简体中文。长邮件会自动分段，并在内存中缓存译文；连接会遵循应用的直连/SOCKS5 设置。

## 测试

```bash
swift test
```

运行 XCTest 需要完整 Xcode。仅安装 Command Line Tools 的机器仍可构建和运行应用，但该工具链可能提示 `XCTest not available`。

## 工程结构

```text
Package.swift
Sources/
├── CurlShim/                 # libcurl、SOCKS5 与 IMAP UTF-8 C 桥接
└── GmailReaderApp/
    ├── GmailReaderApp.swift
    ├── AccountStore.swift
    ├── KeychainStore.swift
    ├── GmailService.swift
    ├── CurlTransport.swift
    ├── MIMEParser.swift
    ├── MailboxViewModel.swift
    ├── HTMLWebView.swift
    └── RootView.swift
Resources/
Tests/
scripts/build_app.sh
```
