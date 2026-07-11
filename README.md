# Gmail 应用专用密码邮件读取器

通过 Gmail IMAP 和应用专用密码读取邮件，支持：

- 检查账号配置
- 获取最近邮件或未读邮件
- IMAP IDLE 实时监听新邮件
- 文本或 JSON 输出
- 默认以只读方式打开邮箱，不会误标记已读

## 1. 生成应用专用密码

1. 登录 [Google 账号安全设置](https://myaccount.google.com/security)。
2. 开启“两步验证”。
3. 打开“应用专用密码”：<https://myaccount.google.com/apppasswords>
4. 创建一个用于邮件读取的密码，复制生成的 16 位密码。

如果看不到该入口，常见原因是账号没有开启两步验证、加入了高级保护计划，或 Workspace 管理员禁止了应用专用密码。

## 2. 安装

```bash
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -e .
```

## 3. 配置

```bash
cp .env.example .env
```

编辑 `.env`：

```dotenv
GMAIL_ADDRESS=yourname@gmail.com
GMAIL_APP_PASSWORD=xxxx xxxx xxxx xxxx
```

不要提交 `.env`。它已包含在 `.gitignore` 中。

## 4. 使用

检查连接：

```bash
gmail-reader check
```

读取最近 10 封邮件：

```bash
gmail-reader fetch --limit 10
```

只读取未读邮件：

```bash
gmail-reader fetch --unread --limit 20
```

输出 JSON，便于其他程序处理：

```bash
gmail-reader fetch --unread --json
```

实时监听新邮件：

```bash
gmail-reader watch
```

启动监听时同时输出当前未读邮件：

```bash
gmail-reader watch --include-existing
```

监听并输出 JSON Lines：

```bash
gmail-reader watch --json
```

可通过 `Ctrl+C` 停止监听。连接断开后程序会自动重连；IDLE 会定期续订。

## Web 网页版

项目包含接近原生 Gmail 的响应式 Web 界面，可查看收件箱、未读、星标、已发送等邮箱，支持分页、搜索、查看正文、修改已读/星标状态、将当前视图的所有会话标记为已读和发送邮件。

启动：

```bash
source .venv/bin/activate
gmail-web
```

浏览器访问：<http://127.0.0.1:5001>

Web 服务默认只监听本机 `127.0.0.1`，不会暴露到局域网或公网。端口可通过 `.env` 中的 `GMAIL_WEB_PORT` 修改。

### 多账号

点击网页右上角头像，再点击“添加其他账号”，输入 Gmail 地址和对应的 16 位应用专用密码。程序会先验证登录，成功后才保存。

- `.env` 中的账号会作为默认账号显示。
- 新增账号保存在本机 `accounts.json`，文件权限自动设置为 `600`。
- 可以随时从右上角账号菜单切换或移除账号。
- `accounts.json` 已加入 `.gitignore`，不会被提交到 Git。

邮件列表只获取标题、发件人、日期和状态，点击邮件时再按需获取完整正文；Web 服务会复用每个账号的 IMAP 连接，因此连续刷新和账号内操作会明显更快。

### 代理网络

如果本机使用 Clash、Surge 等代理，浏览器能打开 Google 但 IMAP 出现 `SSL: UNEXPECTED_EOF_WHILE_READING`，请让 IMAP/SMTP 通过 SOCKS 代理：

```dotenv
GMAIL_PROXY_TYPE=socks5
GMAIL_PROXY_HOST=127.0.0.1
GMAIL_PROXY_PORT=6153
GMAIL_PROXY_RDNS=true
```

Surge 常用 SOCKS 端口为 `6153`，Clash 常用 `7891`。应以代理软件中显示的 SOCKS 端口为准；不使用代理时将 `GMAIL_PROXY_TYPE` 留空。

## 安全说明

- 应用专用密码仍然是敏感凭据，只放在本机 `.env` 或生产环境的密钥管理服务中。
- 修改 Google 主密码、手动撤销应用专用密码或账号策略变化后，需要生成新密码。
- 若部署到长期运行的服务器，更推荐用环境变量注入密码，不要将 `.env` 复制进镜像。
