import SwiftUI

struct ComposeView: View {
    @EnvironmentObject private var model: MailboxViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var recipients = ""
    @State private var subject = ""
    @State private var messageBody = ""
    @State private var isSending = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("收件人（多个地址用逗号分隔）", text: $recipients)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress)
                    TextField("主题", text: $subject)
                }
                Section("正文") {
                    TextEditor(text: $messageBody).frame(minHeight: 260)
                }
            }
            .navigationTitle("新邮件")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSending ? "发送中…" : "发送") {
                        isSending = true
                        let values = recipients.components(separatedBy: CharacterSet(charactersIn: ",;\n"))
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                        Task {
                            if await model.send(recipients: values, subject: subject, body: messageBody) { dismiss() }
                            isSending = false
                        }
                    }
                    .disabled(isSending || recipients.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
