import SwiftUI

struct ComposeView: View {
    @EnvironmentObject private var model: MailboxViewModel
    @EnvironmentObject private var accounts: AccountStore
    @Environment(\.dismiss) private var dismiss
    @State private var recipients = ""
    @State private var subject = ""
    @State private var messageBody = ""
    @State private var isSending = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("发件人").foregroundStyle(.secondary)
                    Text(accounts.selectedAccount?.address ?? "")
                        .font(.subheadline)
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 18)
                .frame(height: 48)

                Divider().padding(.leading, 18)

                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("收件人").foregroundStyle(.secondary)
                    TextField("多个地址用逗号分隔", text: $recipients)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress)
                        .autocorrectionDisabled()
                }
                .padding(.horizontal, 18)
                .frame(height: 48)

                Divider().padding(.leading, 18)

                TextField("主题", text: $subject)
                    .padding(.horizontal, 18)
                    .frame(height: 48)

                Divider().padding(.leading, 18)

                TextEditor(text: $messageBody)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 14)
                    .padding(.top, 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .topLeading) {
                        if messageBody.isEmpty {
                            Text("撰写邮件")
                                .foregroundStyle(.tertiary)
                                .padding(.leading, 19)
                                .padding(.top, 17)
                                .allowsHitTesting(false)
                        }
                    }
            }
            .navigationTitle("写邮件")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        isSending = true
                        let values = recipients.components(separatedBy: CharacterSet(charactersIn: ",;\n"))
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                        Task {
                            if await model.send(recipients: values, subject: subject, body: messageBody) { dismiss() }
                            isSending = false
                        }
                    } label: {
                        if isSending {
                            ProgressView()
                        } else {
                            Image(systemName: "paperplane.fill")
                        }
                    }
                    .disabled(isSending || recipients.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel(isSending ? "发送中" : "发送")
                }
            }
        }
    }
}
