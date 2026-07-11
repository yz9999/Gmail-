# Gmail Reader for iOS

使用 **Swift 5 + SwiftUI** 编写的原生 iPhone/iPad Gmail 客户端。本分支仅包含 iOS 工程，不包含任何本机账号、邮箱地址、应用专用密码、Cookie 或 `.env` 数据。

## 分支

- `main`：Web 版本
- `macos-app`：macOS SwiftUI 版本
- `ios-app`：iOS SwiftUI 版本

## 功能

- iPhone 与 iPad 自适应 SwiftUI 界面
- 多账号管理与快速切换
- 应用专用密码保存在 iOS 钥匙串，使用 `ThisDeviceOnly`
- 收件箱、未读、星标、已发送、草稿、所有邮件、垃圾邮件、回收站
- 每页 50 封邮件及前后翻页
- 使用 Gmail `X-GM-RAW` 搜索整个邮箱
- HTML 邮件通过禁用 JavaScript 的 `WKWebView` 显示
- 标记已读/未读、星标、全部标记为已读
- Gmail SMTPS 写信
- 切换账号时取消旧任务，并阻止旧请求覆盖当前账号界面
- TLS 证书验证始终开启

## 账号数据

应用首次启动为空，不会读取或导入：

```text
.env
accounts.json
macOS 钥匙串
macOS Gmail Reader 配置
浏览器 Cookie
```

账号元数据保存在 iOS Application Support 中，文件不含密码。应用专用密码保存在钥匙串服务：

```text
com.yz9999.GmailReaderIOS.password
```

仓库已忽略 `.env`、`accounts.json`、证书、描述文件和 Xcode 用户数据。

## 构建要求

- Xcode 15 或更高版本
- iOS 16 或更高版本
- Google 账号已开启两步验证
- 已生成 16 位 Google 应用专用密码

## 构建步骤

1. 使用 Xcode 打开：

   ```text
   GmailReaderIOS.xcodeproj
   ```

2. 等待 Swift Package Manager 下载 MailCore2。
3. 在 `Signing & Capabilities` 中选择自己的 Apple Developer Team。
4. 选择 iPhone、iPad 或真机后运行。

工程使用固定的 MailCore2 revision：

```text
7417b2e8dd7e2c028aadb72056e4d1428c0627c4
```

Intel Mac 可直接运行 x86_64 模拟器。MailCore2 当前二进制不包含 arm64 Simulator slice；Apple Silicon Mac 建议使用真机，或以 Rosetta 方式运行兼容的模拟器构建环境。

## 网络

- IMAPS：`imap.gmail.com:993`
- SMTPS：`smtp.gmail.com:465`
- TLS 证书检查：开启
- Gmail 全邮箱搜索：`X-GM-RAW`

iOS 版本不在应用内保存代理账号。需要代理网络时，使用 iOS 系统 VPN 或能够接管设备网络流量的代理配置。

## 工程结构

```text
GmailReaderIOS.xcodeproj/
GmailReaderIOS/
├── GmailReaderIOSApp.swift
├── Models/
│   └── MailModels.swift
├── Services/
│   ├── AccountStore.swift
│   ├── KeychainStore.swift
│   └── MailCoreService.swift
├── ViewModels/
│   └── MailboxViewModel.swift
├── Views/
│   ├── RootView.swift
│   ├── SidebarView.swift
│   ├── MessageListView.swift
│   ├── MessageDetailView.swift
│   ├── HTMLWebView.swift
│   ├── ComposeView.swift
│   └── AccountManagerView.swift
└── Resources/
    └── Assets.xcassets
```
