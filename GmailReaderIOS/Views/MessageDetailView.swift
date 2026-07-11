import SwiftUI

struct MessageDetailView: View {
    @EnvironmentObject private var model: MailboxViewModel

    var body: some View {
        Group {
            if model.isLoadingMessage {
                ProgressView("正在打开邮件…")
            } else if let message = model.selectedMessage, let summary = model.selectedSummary {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text(message.subject)
                            .font(.title2)
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        HStack(alignment: .top, spacing: 12) {
                            AccountAvatar(text: message.sender)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(message.sender).font(.subheadline.bold()).textSelection(.enabled)
                                Text("发送至 \(message.recipients)")
                                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                            Spacer()
                            if let date = message.date {
                                Text(date.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }

                        if !message.htmlBody.isEmpty {
                            HTMLWebView(html: message.htmlBody)
                                .frame(minHeight: 420)
                        } else {
                            Text(message.plainBody)
                                .font(.body)
                                .lineSpacing(4)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding()
                }
                .toolbar {
                    ToolbarItemGroup(placement: .navigationBarTrailing) {
                        Button { model.toggleStar(summary) } label: {
                            Image(systemName: message.isStarred ? "star.fill" : "star")
                                .foregroundColor(message.isStarred ? .yellow : .primary)
                        }
                        Button { model.markUnread(summary) } label: { Image(systemName: "envelope.badge") }
                    }
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "envelope.open").font(.system(size: 44)).foregroundStyle(.secondary)
                    Text("选择一封邮件").foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("邮件")
        .navigationBarTitleDisplayMode(.inline)
    }
}
