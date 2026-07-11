import SwiftUI

struct AccountManagerView: View {
    @EnvironmentObject private var accounts: AccountStore
    @EnvironmentObject private var model: MailboxViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var address = ""
    @State private var password = ""
    @State private var isAdding = false

    var body: some View {
        NavigationStack {
            Form {
                if !accounts.accounts.isEmpty {
                    Section("已添加账号") {
                        ForEach(accounts.accounts) { account in
                            HStack {
                                AccountAvatar(text: account.name)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(account.name)
                                    Text(account.address).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if account.id == accounts.selectedAccountID {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(GmailTheme.red)
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                let previous = accounts.selectedAccountID
                                accounts.select(account)
                                model.accountChanged(from: previous)
                            }
                            .swipeActions {
                                Button(role: .destructive) { model.delete(account) } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                        }
                    }
                }

                Section("添加 Gmail 账号") {
                    TextField("账号名称（选填）", text: $name)
                    TextField("Gmail 地址", text: $address)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress)
                        .autocorrectionDisabled()
                    SecureField("16 位应用专用密码", text: $password)
                        .textInputAutocapitalization(.never)
                    Button(isAdding ? "正在验证…" : "验证并添加") {
                        isAdding = true
                        Task {
                            if await model.verifyAndAdd(name: name, address: address, password: password) {
                                name = ""; address = ""; password = ""
                            }
                            isAdding = false
                        }
                    }
                    .disabled(isAdding || address.isEmpty || password.isEmpty)
                }

                Section {
                    Text("账号需要开启 Google 两步验证并生成应用专用密码。应用不会读取本机项目目录，也不会导入 .env、accounts.json、Cookie 或 macOS 版账号。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("账号管理")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
        }
    }
}
