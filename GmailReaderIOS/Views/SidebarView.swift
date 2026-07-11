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
                    Label("写邮件", systemImage: "square.and.pencil")
                        .fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent)
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
                    .foregroundStyle(.primary)
                    .listRowBackground(model.mailbox == mailbox && model.activeSearch.isEmpty ? Color.blue.opacity(0.13) : Color.clear)
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
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.blue)
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
    }
}

struct AccountAvatar: View {
    let text: String

    var body: some View {
        Text(String(text.prefix(1)).uppercased())
            .font(.subheadline.bold())
            .foregroundStyle(.white)
            .frame(width: 34, height: 34)
            .background(Color.blue, in: Circle())
    }
}
