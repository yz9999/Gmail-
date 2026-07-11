import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var accounts: AccountStore
    @EnvironmentObject private var model: MailboxViewModel

    var body: some View {
        List {
            Section {
                Button {
                    model.showingCompose = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "pencil")
                        Text("写邮件").fontWeight(.semibold)
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 13)
                    .background(GmailTheme.red.opacity(0.14), in: RoundedRectangle(cornerRadius: 16))
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.clear)
            }

            Section("邮箱") {
                ForEach(MailboxKind.allCases) { mailbox in
                    Button {
                        model.selectMailbox(mailbox)
                    } label: {
                        Label(mailbox.title, systemImage: mailbox.symbol)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fontWeight(model.mailbox == mailbox && model.activeSearch.isEmpty ? .semibold : .regular)
                    }
                    .foregroundStyle(model.mailbox == mailbox && model.activeSearch.isEmpty ? GmailTheme.red : Color.primary)
                    .listRowBackground(model.mailbox == mailbox && model.activeSearch.isEmpty ? GmailTheme.red.opacity(0.13) : Color.clear)
                }
            }

            Section("账号") {
                ForEach(accounts.accounts) { account in
                    Button {
                        let previous = accounts.selectedAccountID
                        accounts.select(account)
                        model.accountChanged(from: previous)
                    } label: {
                        HStack {
                            AccountAvatar(text: account.name)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(account.name).lineLimit(1)
                                Text(account.address).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            if account.id == accounts.selectedAccountID {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(GmailTheme.red)
                            }
                        }
                    }
                    .foregroundStyle(.primary)
                }
                Button { model.showingAccounts = true } label: {
                    Label("管理账号", systemImage: "person.crop.circle.badge.plus")
                }
            }
        }
        .navigationTitle("Gmail")
        .listStyle(.sidebar)
    }
}

struct AccountAvatar: View {
    let text: String
    var size: CGFloat = 34

    var body: some View {
        Text(String(text.prefix(1)).uppercased())
            .font(.subheadline.bold())
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(avatarColor, in: Circle())
    }

    private var avatarColor: Color {
        let colors: [Color] = [
            Color(red: 0.26, green: 0.52, blue: 0.96),
            Color(red: 0.91, green: 0.33, blue: 0.27),
            Color(red: 0.11, green: 0.63, blue: 0.45),
            Color(red: 0.58, green: 0.32, blue: 0.80),
            Color(red: 0.95, green: 0.57, blue: 0.12),
        ]
        let value = text.unicodeScalars.reduce(UInt(0)) { ($0 &* 31) &+ UInt($1.value) }
        return colors[Int(value % UInt(colors.count))]
    }
}

struct PhoneSidebarDrawer: View {
    @EnvironmentObject private var accounts: AccountStore
    @EnvironmentObject private var model: MailboxViewModel
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "envelope.fill")
                    .font(.title2)
                    .foregroundStyle(GmailTheme.red)
                Text("Gmail")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(GmailTheme.red)
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 38, height: 38)
                        .background(Color.secondary.opacity(0.12), in: Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 22)
            .padding(.top, 18)
            .padding(.bottom, 14)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    Button {
                        close()
                        model.showingCompose = true
                    } label: {
                        Label("写邮件", systemImage: "pencil")
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 20)
                            .frame(height: 54)
                            .background(GmailTheme.red.opacity(0.14), in: RoundedRectangle(cornerRadius: 18))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)

                    Text("邮箱")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 26)
                        .padding(.top, 8)
                        .padding(.bottom, 4)

                    ForEach(MailboxKind.allCases) { mailbox in
                        Button {
                            model.selectMailbox(mailbox)
                            close()
                        } label: {
                            HStack(spacing: 18) {
                                Image(systemName: mailbox.symbol)
                                    .font(.system(size: 18))
                                    .frame(width: 26)
                                Text(mailbox.title)
                                    .fontWeight(isSelected(mailbox) ? .semibold : .regular)
                                Spacer()
                                if mailbox == model.mailbox, model.total > 0, model.activeSearch.isEmpty {
                                    Text("\(model.total)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .foregroundStyle(isSelected(mailbox) ? GmailTheme.red : Color.primary)
                            .padding(.horizontal, 24)
                            .frame(height: 48)
                            .background(
                                isSelected(mailbox) ? GmailTheme.red.opacity(0.13) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 24)
                            )
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, 14)
                    }

                    Divider().padding(.vertical, 12)

                    Text("账号")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 26)
                        .padding(.bottom, 4)

                    ForEach(accounts.accounts) { account in
                        Button {
                            let previous = accounts.selectedAccountID
                            accounts.select(account)
                            model.accountChanged(from: previous)
                            close()
                        } label: {
                            HStack(spacing: 12) {
                                AccountAvatar(text: account.name, size: 36)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(account.name).font(.subheadline.weight(.medium)).lineLimit(1)
                                    Text(account.address).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                if account.id == accounts.selectedAccountID {
                                    Image(systemName: "checkmark").foregroundStyle(GmailTheme.red)
                                }
                            }
                            .padding(.horizontal, 24)
                            .frame(height: 56)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.primary)
                    }

                    Button {
                        close()
                        model.showingAccounts = true
                    } label: {
                        Label("管理账号", systemImage: "person.crop.circle.badge.plus")
                            .padding(.horizontal, 26)
                            .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary)
                    .padding(.bottom, 24)
                }
            }
        }
        .background(Color(uiColor: .systemBackground))
    }

    private func isSelected(_ mailbox: MailboxKind) -> Bool {
        model.mailbox == mailbox && model.activeSearch.isEmpty
    }
}
