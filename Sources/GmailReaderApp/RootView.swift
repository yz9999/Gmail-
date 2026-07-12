import SwiftUI

struct RootView: View {
    @EnvironmentObject private var accounts: AccountStore
    @EnvironmentObject private var preferences: AppPreferences
    @EnvironmentObject private var model: MailboxViewModel

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                TopBar()
                Divider().opacity(0.55)
                HStack(spacing: 0) {
                    Sidebar()
                    if accounts.selectedAccount == nil {
                        EmptyAccountView()
                    } else if model.selectedMessage != nil || model.isLoadingMessage {
                        MessageDetailView()
                    } else {
                        MessageListView()
                    }
                }
            }
            if let toast = model.toastMessage {
                Text(toast)
                    .foregroundColor(.white)
                    .padding(.horizontal, 18).padding(.vertical, 10)
                    .background(Color(red: 0.20, green: 0.21, blue: 0.23))
                    .cornerRadius(5)
                    .shadow(radius: 8)
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(Color(red: 0.965, green: 0.973, blue: 0.988))
        .sheet(isPresented: $model.showingCompose) { ComposeView() }
        .sheet(isPresented: $model.showingAccounts) { AccountManagerView() }
        .sheet(isPresented: $model.showingSettings) { SettingsView() }
        .alert("Gmail Reader", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("好", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

private struct TopBar: View {
    @EnvironmentObject private var accounts: AccountStore
    @EnvironmentObject private var model: MailboxViewModel

    var body: some View {
        HStack(spacing: 18) {
            HStack(spacing: 11) {
                Image(systemName: "envelope.fill")
                    .font(.system(size: 25)).foregroundColor(Color(red: 0.86, green: 0.20, blue: 0.17))
                Text("Gmail").font(.system(size: 21)).foregroundColor(Color(red: 0.35, green: 0.37, blue: 0.40))
            }
            .frame(width: 185, alignment: .leading)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("搜索所有邮件", text: $model.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .onSubmit { model.submitSearch() }
                if !model.searchText.isEmpty {
                    Button(action: { model.clearSearch() }) { Image(systemName: "xmark") }
                        .buttonStyle(.plain).foregroundColor(.secondary)
                }
                Button(action: { model.submitSearch() }) { Image(systemName: "slider.horizontal.3") }
                    .buttonStyle(.plain).foregroundColor(.secondary)
            }
            .padding(.horizontal, 16).frame(maxWidth: 690, minHeight: 44)
            .background(Color(red: 0.91, green: 0.94, blue: 0.98)).cornerRadius(22)

            Spacer(minLength: 4)
            Button { model.showingSettings = true } label: { Image(systemName: "gearshape") }
                .buttonStyle(TopIconButtonStyle())
            Menu {
                ForEach(accounts.accounts) { account in
                    Button {
                        accounts.select(account); model.accountChanged()
                    } label: {
                        if account.id == accounts.selectedAccountID { Label(account.address, systemImage: "checkmark") }
                        else { Text(account.address) }
                    }
                }
                Divider()
                Button("管理账号…") { model.showingAccounts = true }
            } label: {
                Text(String((accounts.selectedAccount?.name ?? "G").prefix(1)).uppercased())
                    .font(.system(size: 14, weight: .semibold)).foregroundColor(.white)
                    .frame(width: 34, height: 34).background(Color(red: 0.25, green: 0.47, blue: 0.85)).clipShape(Circle())
            }
            .menuStyle(.borderlessButton).frame(width: 40)
        }
        .padding(.horizontal, 18).frame(height: 64)
        .background(Color(red: 0.965, green: 0.973, blue: 0.988))
    }
}

private struct TopIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 17)).foregroundColor(.secondary)
            .frame(width: 34, height: 34)
            .background(configuration.isPressed ? Color.black.opacity(0.08) : Color.clear)
            .clipShape(Circle())
    }
}

private struct Sidebar: View {
    @EnvironmentObject private var model: MailboxViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { model.showingCompose = true } label: {
                Label("写邮件", systemImage: "square.and.pencil")
                    .font(.system(size: 14, weight: .medium)).foregroundColor(Color(red: 0.12, green: 0.20, blue: 0.30))
                    .padding(.horizontal, 19).frame(height: 52)
                    .background(Color(red: 0.76, green: 0.90, blue: 0.98)).cornerRadius(16)
            }.buttonStyle(.plain).padding(.leading, 8).padding(.vertical, 8)

            ForEach([MailboxKind.inbox, .starred, .unread, .sent, .drafts, .all, .spam, .trash]) { item in
                Button { model.selectMailbox(item) } label: {
                    HStack(spacing: 14) {
                        Image(systemName: item.symbol).frame(width: 19)
                        Text(item.title)
                        Spacer()
                    }
                    .font(.system(size: 13, weight: model.mailbox == item && model.activeSearch.isEmpty ? .semibold : .regular))
                    .foregroundColor(Color(red: 0.22, green: 0.23, blue: 0.25))
                    .padding(.leading, 24).padding(.trailing, 14).frame(height: 32)
                    .background(model.mailbox == item && model.activeSearch.isEmpty ? Color(red: 0.83, green: 0.88, blue: 0.96) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                }.buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.trailing, 12).frame(width: 218)
        .background(Color(red: 0.965, green: 0.973, blue: 0.988))
    }
}

private struct EmptyAccountView: View {
    @EnvironmentObject private var model: MailboxViewModel
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "envelope.badge.shield.leadinghalf.filled").font(.system(size: 58)).foregroundColor(.secondary)
            Text("添加 Gmail 账号").font(.title2).fontWeight(.semibold)
            Text("应用专用密码会存入 macOS 钥匙串，不会启动本地网页服务。")
                .foregroundColor(.secondary).multilineTextAlignment(.center)
            Button("添加账号") { model.showingAccounts = true }.buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.white).cornerRadius(14).padding(.trailing, 12).padding(.bottom, 12)
    }
}

private struct MessageListView: View {
    @EnvironmentObject private var model: MailboxViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button(action: { model.refresh() }) { Image(systemName: "arrow.clockwise") }.buttonStyle(ToolbarButtonStyle())
                Menu {
                    Button("将所有会话标记为已读", action: { model.markAllRead() })
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 30)
                if !model.activeSearch.isEmpty {
                    Text("“\(model.activeSearch)”的搜索结果").font(.system(size: 13, weight: .medium)).lineLimit(1).padding(.leading, 8)
                }
                Spacer()
                Text(model.rangeText).font(.system(size: 12)).foregroundColor(.secondary)
                Button(action: { model.previousPage() }) { Image(systemName: "chevron.left") }
                    .buttonStyle(ToolbarButtonStyle()).disabled(model.page <= 1 || model.isLoading)
                Button(action: { model.nextPage() }) { Image(systemName: "chevron.right") }
                    .buttonStyle(ToolbarButtonStyle()).disabled(model.page >= model.pageCount || model.isLoading)
            }
            .padding(.horizontal, 14).frame(height: 49)
            Divider()

            if model.isLoading && model.messages.isEmpty {
                VStack(spacing: 12) { ProgressView(); Text("正在获取邮件…").foregroundColor(.secondary) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.messages.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "tray").font(.system(size: 42)).foregroundColor(.secondary)
                    Text(model.activeSearch.isEmpty ? "这里没有邮件" : "没有找到匹配的邮件").foregroundColor(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.messages) { message in
                            MessageRow(message: message)
                            Divider().padding(.leading, 48)
                        }
                    }
                }
                .overlay(alignment: .top) {
                    if model.isLoading { ProgressView().progressViewStyle(.linear).frame(maxWidth: .infinity) }
                }
            }
        }
        .background(Color.white).cornerRadius(14).padding(.trailing, 12).padding(.bottom, 12)
    }
}

private struct ToolbarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.foregroundColor(.secondary).frame(width: 30, height: 30)
            .background(configuration.isPressed ? Color.black.opacity(0.08) : Color.clear).clipShape(Circle())
    }
}

private struct MessageRow: View {
    @EnvironmentObject private var model: MailboxViewModel
    let message: MailSummary

    var body: some View {
        HStack(spacing: 12) {
            Button { model.toggleStar(uid: message.uid) } label: {
                Image(systemName: message.isStarred ? "star.fill" : "star")
                    .foregroundColor(message.isStarred ? Color(red: 0.96, green: 0.68, blue: 0.05) : .secondary)
            }.buttonStyle(.plain).frame(width: 24)
            Text(message.senderDisplay).font(.system(size: 13, weight: message.isRead ? .regular : .semibold))
                .lineLimit(1).frame(width: 190, alignment: .leading)
            Text(message.subject).font(.system(size: 13, weight: message.isRead ? .regular : .semibold)).lineLimit(1)
            Spacer(minLength: 8)
            Text(displayDate(message.date, fallback: message.dateText)).font(.system(size: 11, weight: message.isRead ? .regular : .semibold))
                .foregroundColor(message.isRead ? .secondary : .primary).frame(minWidth: 72, alignment: .trailing)
        }
        .padding(.horizontal, 14).frame(height: 42)
        .background(message.isRead ? Color(red: 0.97, green: 0.975, blue: 0.98) : Color.white)
        .contentShape(Rectangle()).onTapGesture { model.open(message) }
    }

    private func displayDate(_ date: Date?, fallback: String) -> String {
        guard let date else { return fallback }
        let formatter = DateFormatter()
        if Calendar.current.isDateInToday(date) { formatter.dateFormat = "HH:mm" }
        else if Calendar.current.component(.year, from: date) == Calendar.current.component(.year, from: Date()) { formatter.dateFormat = "M月d日" }
        else { formatter.dateFormat = "yyyy/M/d" }
        return formatter.string(from: date)
    }
}

private struct MessageDetailView: View {
    @EnvironmentObject private var model: MailboxViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button(action: { model.closeMessage() }) { Image(systemName: "arrow.left") }.buttonStyle(ToolbarButtonStyle())
                if let message = model.selectedMessage {
                    Button { model.markUnread(message) } label: { Image(systemName: "envelope.badge") }.buttonStyle(ToolbarButtonStyle())
                    Button { model.toggleStar(uid: message.uid) } label: {
                        Image(systemName: message.isStarred ? "star.fill" : "star")
                            .foregroundColor(message.isStarred ? .yellow : .secondary)
                    }.buttonStyle(ToolbarButtonStyle())
                }
                Spacer()
            }.padding(.horizontal, 14).frame(height: 49)
            Divider()
            if model.isLoadingMessage || model.selectedMessage == nil {
                ProgressView("正在打开邮件…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let message = model.selectedMessage {
                VStack(alignment: .leading, spacing: 0) {
                    Text(message.subject).font(.system(size: 22)).padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 20)
                    HStack(alignment: .top, spacing: 12) {
                        Text(String(message.sender.prefix(1)).uppercased()).fontWeight(.semibold).foregroundColor(.white)
                            .frame(width: 38, height: 38).background(Color(red: 0.32, green: 0.50, blue: 0.80)).clipShape(Circle())
                        VStack(alignment: .leading, spacing: 4) {
                            Text(message.sender).font(.system(size: 13, weight: .semibold)).textSelection(.enabled)
                            Text("发送至 \(message.recipients)").font(.system(size: 11)).foregroundColor(.secondary).textSelection(.enabled)
                        }
                        Spacer()
                        Text(message.dateText).font(.system(size: 11)).foregroundColor(.secondary).textSelection(.enabled)
                    }.padding(.horizontal, 28).padding(.bottom, 12)
                    translationBar
                        .padding(.horizontal, 28)
                        .padding(.bottom, 14)
                    if model.showingTranslation, let translated = model.translatedBody {
                        ScrollView {
                            Text(translated)
                                .font(.system(size: 14))
                                .lineSpacing(4)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                                .padding(.horizontal, 28)
                                .padding(.bottom, 30)
                        }
                    } else if !message.htmlBody.isEmpty {
                        HTMLWebView(html: message.htmlBody).padding(.horizontal, 28).padding(.bottom, 18)
                    } else {
                        ScrollView {
                            Text(message.plainBody).font(.system(size: 14)).lineSpacing(4).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .topLeading).padding(.horizontal, 28).padding(.bottom, 30)
                        }
                    }
                }
            }
        }
        .background(Color.white).cornerRadius(14).padding(.trailing, 12).padding(.bottom, 12)
    }

    @ViewBuilder
    private var translationBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "character.book.closed")
                .foregroundColor(Color(red: 0.16, green: 0.42, blue: 0.82))
            if model.isTranslating {
                ProgressView().controlSize(.small)
                Text("正在翻译成中文…")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            } else if model.translatedBody != nil {
                Text("由 Google 翻译")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                if model.showingTranslation {
                    Button("显示原文") { model.showOriginalMessage() }
                } else {
                    Button("显示译文") { model.showTranslatedMessage() }
                }
            } else {
                Button("翻译成中文") { model.translateCurrentMessage() }
                    .buttonStyle(.link)
                Spacer()
                Text("使用 Google 翻译")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 38)
        .background(Color(red: 0.94, green: 0.96, blue: 0.99))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct ComposeView: View {
    @EnvironmentObject private var model: MailboxViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var recipients = ""
    @State private var subject = ""
    @State private var messageBody = ""
    @State private var isSending = false

    var body: some View {
        VStack(spacing: 0) {
            HStack { Text("新邮件").fontWeight(.semibold); Spacer(); Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(.plain) }
                .padding(.horizontal, 14).frame(height: 40).background(Color(red: 0.16, green: 0.22, blue: 0.29)).foregroundColor(.white)
            TextField("收件人（多个地址用逗号分隔）", text: $recipients).textFieldStyle(.plain).padding(.horizontal, 14).frame(height: 42)
            Divider()
            TextField("主题", text: $subject).textFieldStyle(.plain).padding(.horizontal, 14).frame(height: 42)
            Divider()
            TextEditor(text: $messageBody).font(.system(size: 14)).padding(10)
            HStack {
                Button(isSending ? "正在发送…" : "发送") {
                    isSending = true
                    let values = recipients.components(separatedBy: CharacterSet(charactersIn: ",;\n"))
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                    Task {
                        if await model.send(recipients: values, subject: subject, body: messageBody) { dismiss() }
                        isSending = false
                    }
                }.buttonStyle(.borderedProminent).disabled(isSending || recipients.trimmingCharacters(in: .whitespaces).isEmpty)
                Spacer()
                Button { dismiss() } label: { Image(systemName: "trash") }
            }.padding(12)
        }.frame(width: 620, height: 520)
    }
}

private struct AccountManagerView: View {
    @EnvironmentObject private var accounts: AccountStore
    @EnvironmentObject private var model: MailboxViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var address = ""
    @State private var password = ""
    @State private var isAdding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("Gmail 账号").font(.title2).fontWeight(.semibold); Spacer(); Button("完成") { dismiss() } }
            if !accounts.accounts.isEmpty {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(accounts.accounts) { account in
                            HStack {
                                Text(String(account.name.prefix(1)).uppercased()).foregroundColor(.white).frame(width: 32, height: 32)
                                    .background(Color.blue).clipShape(Circle())
                                VStack(alignment: .leading) { Text(account.name).fontWeight(.medium); Text(account.address).font(.caption).foregroundColor(.secondary) }
                                Spacer()
                                if accounts.selectedAccountID == account.id { Image(systemName: "checkmark.circle.fill").foregroundColor(.blue) }
                                Button(role: .destructive) {
                                    do { try accounts.delete(account); model.accountChanged() } catch { model.errorMessage = error.localizedDescription }
                                } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                            }.padding(.vertical, 8)
                            if account.id != accounts.accounts.last?.id { Divider() }
                        }
                    }
                    .padding(.horizontal, 12)
                }.frame(maxHeight: 220).background(Color.gray.opacity(0.06)).cornerRadius(10)
            }
            Divider()
            Text("添加账号").font(.headline)
            TextField("账号名称（选填）", text: $name)
            TextField("Gmail 地址", text: $address)
            SecureField("16 位应用专用密码", text: $password)
            Text("密码仅保存到 macOS 钥匙串。添加前会通过 Gmail 验证，应用不会保存 Google 登录密码或 Cookie。")
                .font(.caption).foregroundColor(.secondary)
            HStack {
                Spacer()
                Button(isAdding ? "正在验证…" : "验证并添加") {
                    isAdding = true
                    Task {
                        if await model.verifyAndAdd(name: name, address: address, password: password) {
                            name = ""; address = ""; password = ""
                        }
                        isAdding = false
                    }
                }.buttonStyle(.borderedProminent).disabled(isAdding || address.isEmpty || password.isEmpty)
            }
        }.padding(24).frame(width: 520, height: 600)
    }
}

private struct SettingsView: View {
    @EnvironmentObject private var preferences: AppPreferences
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("连接设置").font(.title2).fontWeight(.semibold); Spacer(); Button("完成") { dismiss() } }
            Toggle("使用 SOCKS5 代理", isOn: $preferences.proxyEnabled)
            HStack {
                TextField("代理主机", text: $preferences.proxyHost)
                TextField("端口", value: $preferences.proxyPort, formatter: NumberFormatter()).frame(width: 100)
            }.disabled(!preferences.proxyEnabled)
            Text("默认使用经过系统证书校验的直连 TLS。只有当当前网络无法直接访问 Gmail 时，才需要启用 SOCKS5 代理。")
                .font(.caption).foregroundColor(.secondary)
            Spacer()
        }.padding(24).frame(width: 460, height: 260)
    }
}
