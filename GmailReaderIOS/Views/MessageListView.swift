import SwiftUI

struct MessageListView: View {
    @EnvironmentObject private var model: MailboxViewModel

    var body: some View {
        Group {
            if model.isLoading && model.messages.isEmpty {
                ProgressView("正在获取邮件…")
            } else if model.messages.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: model.activeSearch.isEmpty ? "tray" : "magnifyingglass")
                        .font(.system(size: 42)).foregroundStyle(.secondary)
                    Text(model.activeSearch.isEmpty ? "这里没有邮件" : "没有搜索结果")
                        .foregroundStyle(.secondary)
                }
            } else {
                List(selection: $model.selectedSummary) {
                    ForEach(model.messages) { message in
                        NavigationLink(value: message) {
                            MessageRow(message: message)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button {
                                model.toggleStar(message)
                            } label: {
                                Label(message.isStarred ? "取消星标" : "星标", systemImage: "star")
                            }
                            .tint(.yellow)
                        }
                    }
                }
                .listStyle(.plain)
                .refreshable { model.reload() }
                .onChange(of: model.selectedSummary) { value in
                    if let value, model.selectedMessage?.id != value.id { model.open(value) }
                }
            }
        }
        .navigationTitle(model.activeSearch.isEmpty ? model.mailbox.title : "搜索结果")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $model.searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索所有邮件")
        .onSubmit(of: .search) { model.submitSearch() }
        .onChange(of: model.searchText) { value in
            if value.isEmpty, !model.activeSearch.isEmpty { model.clearSearch() }
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Menu {
                    Button { model.markAllRead() } label: {
                        Label("将所有会话标记为已读", systemImage: "envelope.open")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                Button { model.reload() } label: { Image(systemName: "arrow.clockwise") }
            }
            ToolbarItemGroup(placement: .bottomBar) {
                Text(model.rangeText).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { model.previousPage() } label: { Image(systemName: "chevron.left") }
                    .disabled(model.page <= 1 || model.isLoading)
                Button { model.nextPage() } label: { Image(systemName: "chevron.right") }
                    .disabled(model.page >= model.pageCount || model.isLoading)
            }
        }
        .overlay(alignment: .top) {
            if model.isLoading && !model.messages.isEmpty { ProgressView().progressViewStyle(.linear) }
        }
    }
}

struct PhoneMessageListView: View {
    @EnvironmentObject private var accounts: AccountStore
    @EnvironmentObject private var model: MailboxViewModel
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var searchFocused: Bool

    let openSidebar: () -> Void
    let openMessage: (MailSummary) -> Void

    var body: some View {
        VStack(spacing: 0) {
            searchHeader
            mailboxHeader
            Divider()
            messageContent
            paginationBar
        }
        .background(Color(uiColor: .systemBackground))
        .toolbar(.hidden, for: .navigationBar)
        .overlay(alignment: .bottomTrailing) {
            composeButton
                .padding(.trailing, 18)
                .padding(.bottom, 66)
        }
        .overlay(alignment: .top) {
            if model.isLoading && !model.messages.isEmpty {
                ProgressView().progressViewStyle(.linear)
            }
        }
    }

    private var searchHeader: some View {
        HStack(spacing: 10) {
            Button(action: openSidebar) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("打开邮箱菜单")

            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("搜索邮件", text: $model.searchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($searchFocused)
                .onSubmit {
                    model.submitSearch()
                    searchFocused = false
                }
                .onChange(of: model.searchText) { value in
                    if value.isEmpty, !model.activeSearch.isEmpty { model.clearSearch() }
                }

            if !model.searchText.isEmpty {
                Button {
                    model.clearSearch()
                    searchFocused = false
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除搜索")
            }

            Button { model.showingAccounts = true } label: {
                if let account = accounts.selectedAccount {
                    AccountAvatar(text: account.name, size: 34)
                } else {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.title2)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("管理账号")
        }
        .padding(.horizontal, 8)
        .frame(height: 54)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 27))
        .shadow(color: .black.opacity(colorScheme == .dark ? 0 : 0.10), radius: 3, y: 1)
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private var mailboxHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.activeSearch.isEmpty ? model.mailbox.title : "搜索结果")
                    .font(.title3.weight(.semibold))
                if !model.activeSearch.isEmpty {
                    Text(model.activeSearch)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Menu {
                Button { model.reload() } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                Button { model.markAllRead() } label: {
                    Label("将所有会话标记为已读", systemImage: "envelope.open")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 40, height: 40)
                    .contentShape(Circle())
            }
        }
        .padding(.leading, 20)
        .padding(.trailing, 10)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var messageContent: some View {
        if model.isLoading && model.messages.isEmpty {
            Spacer()
            ProgressView("正在获取邮件…")
            Spacer()
        } else if model.messages.isEmpty {
            Spacer()
            VStack(spacing: 14) {
                Image(systemName: model.activeSearch.isEmpty ? "tray" : "magnifyingglass")
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(.secondary)
                Text(model.activeSearch.isEmpty ? "这里没有邮件" : "没有搜索结果")
                    .font(.headline)
                if !model.activeSearch.isEmpty {
                    Text("请尝试其他搜索词")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        } else {
            List {
                ForEach(model.messages) { message in
                    PhoneMessageRow(
                        message: message,
                        open: { openMessage(message) },
                        toggleStar: { model.toggleStar(message) }
                    )
                    .listRowInsets(EdgeInsets(top: 7, leading: 16, bottom: 7, trailing: 12))
                    .listRowSeparator(.hidden)
                    .listRowBackground(message.isRead ? Color.clear : GmailTheme.red.opacity(0.035))
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button { model.toggleStar(message) } label: {
                            Label(message.isStarred ? "取消星标" : "星标", systemImage: "star")
                        }
                        .tint(.yellow)
                    }
                }
                Color.clear
                    .frame(height: 76)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
            .listStyle(.plain)
            .refreshable { model.reload() }
        }
    }

    private var paginationBar: some View {
        HStack(spacing: 18) {
            Text(model.rangeText)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button { model.previousPage() } label: {
                Image(systemName: "chevron.left").frame(width: 34, height: 34)
            }
            .disabled(model.page <= 1 || model.isLoading)
            Button { model.nextPage() } label: {
                Image(systemName: "chevron.right").frame(width: 34, height: 34)
            }
            .disabled(model.page >= model.pageCount || model.isLoading)
        }
        .padding(.horizontal, 18)
        .frame(height: 48)
        .background(.bar)
    }

    private var composeButton: some View {
        Button { model.showingCompose = true } label: {
            Label("写邮件", systemImage: "pencil")
                .font(.headline)
                .foregroundStyle(colorScheme == .dark ? Color.white : Color(red: 0.32, green: 0.12, blue: 0.10))
                .padding(.horizontal, 20)
                .frame(height: 56)
                .background(
                    colorScheme == .dark ? GmailTheme.red.opacity(0.58) : GmailTheme.compose,
                    in: RoundedRectangle(cornerRadius: 18)
                )
                .shadow(color: .black.opacity(0.20), radius: 5, y: 2)
        }
        .buttonStyle(.plain)
    }
}

private struct PhoneMessageRow: View {
    let message: MailSummary
    let open: () -> Void
    let toggleStar: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: open) {
                HStack(alignment: .top, spacing: 12) {
                    AccountAvatar(text: message.senderDisplay, size: 42)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(message.senderDisplay)
                            .font(.subheadline.weight(message.isRead ? .regular : .bold))
                            .lineLimit(1)
                        Text(message.subject)
                            .font(.subheadline.weight(message.isRead ? .regular : .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)

            VStack(alignment: .trailing, spacing: 9) {
                Text(displayDate(message.date))
                    .font(.caption2.weight(message.isRead ? .regular : .semibold))
                    .foregroundStyle(message.isRead ? Color.secondary : GmailTheme.red)
                Button(action: toggleStar) {
                    Image(systemName: message.isStarred ? "star.fill" : "star")
                        .font(.system(size: 17))
                        .foregroundStyle(message.isStarred ? Color.yellow : Color.secondary)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(message.isStarred ? "取消星标" : "添加星标")
            }
        }
    }

    private func displayDate(_ date: Date?) -> String {
        guard let date else { return "" }
        if Calendar.current.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(.dateTime.month().day())
    }
}

private struct MessageRow: View {
    let message: MailSummary

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AccountAvatar(text: message.senderDisplay, size: 38)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(message.senderDisplay)
                        .font(.subheadline.weight(message.isRead ? .regular : .bold))
                        .lineLimit(1)
                    Spacer()
                    Text(displayDate(message.date))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(message.subject)
                    .font(.subheadline.weight(message.isRead ? .regular : .semibold))
                    .lineLimit(2)
                    .foregroundStyle(.primary)
            }
            Image(systemName: message.isStarred ? "star.fill" : "star")
                .foregroundColor(message.isStarred ? .yellow : .secondary)
                .frame(width: 20)
        }
        .padding(.vertical, 4)
    }

    private func displayDate(_ date: Date?) -> String {
        guard let date else { return "" }
        if Calendar.current.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        return date.formatted(.dateTime.month().day())
    }
}
