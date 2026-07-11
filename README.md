# Gmail Reader for macOS

使用 **Swift 5.9 + SwiftUI** 完全重写的原生 macOS Gmail 客户端。应用直接通过 IMAPS/SMTPS 与 Gmail 通信，不启动 Python、Flask、WebView 本地服务器，也不占用 `5001` 或其他本地端口。

## 功能

- Gmail 风格的原生 SwiftUI 界面
- 多账号切换与账号管理
- 应用专用密码保存在 macOS 钥匙串
- 收件箱、未读、星标、已发送、草稿、所有邮件、垃圾邮件、回收站
- 每页 50 封邮件，可前后翻页
- 使用 Gmail `X-GM-RAW` 搜索整个邮箱，支持中文搜索
- HTML 邮件通过禁用 JavaScript 的 `WKWebView` 显示
- 标记已读/未读、星标、全部标记为已读
- 通过 Gmail SMTPS 写信
- 切换账号时取消旧任务，并用请求代次检查避免串号
- SOCKS5 hostname 代理，默认 `127.0.0.1:6153`
- TLS 主机名和系统证书链验证

## 系统要求

- macOS 12 或更高版本
- Swift 5.9 或 Xcode 15
- Gmail 已开启两步验证并生成 16 位应用专用密码
- 当前网络环境下需运行本机 SOCKS5 代理（默认端口 `6153`）

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

脚本会执行 SwiftPM Release 构建、创建标准 `.app` Bundle，并进行本机临时签名。正式分发时应改用 Developer ID 签名并完成 Apple 公证。

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

普通 IMAP 与 SMTP 请求使用系统 `libcurl`：

- `imaps://imap.gmail.com:993`
- `smtps://smtp.gmail.com:465`
- `CURLPROXY_SOCKS5_HOSTNAME`

邮件列表摘要使用一条原生 `UID FETCH` 批量读取 50 封邮件，避免逐封往返造成刷新缓慢。非 ASCII Gmail 搜索需要 IMAP UTF-8 literal；这两类请求使用 SOCKS5 隧道与 Secure Transport 建立经过系统信任评估的 TLS 会话。

中文搜索发送：

```text
UID SEARCH CHARSET UTF-8 X-GM-RAW {字节数}
```

这样不会依赖会返回 Fake-IP 的本机 DNS，也不会关闭证书验证。

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
