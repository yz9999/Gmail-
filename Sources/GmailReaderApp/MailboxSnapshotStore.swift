import Foundation

/// 仅缓存最近一次收件箱摘要，让应用启动时先立即显示邮件，再在后台刷新 Gmail。
/// 文件不包含密码、正文或附件。
enum MailboxSnapshotStore {
    private struct Snapshot: Codable {
        let savedAt: Date
        let total: Int
        let messages: [Row]
    }

    private struct Row: Codable {
        let uid: UInt64
        let messageID: String
        let subject: String
        let sender: String
        let recipients: String
        let dateText: String
        let date: Date?
        let isRead: Bool
        let isStarred: Bool

        init(_ value: MailSummary) {
            uid = value.uid
            messageID = value.messageID
            subject = value.subject
            sender = value.sender
            recipients = value.recipients
            dateText = value.dateText
            date = value.date
            isRead = value.isRead
            isStarred = value.isStarred
        }

        var summary: MailSummary {
            MailSummary(
                uid: uid,
                messageID: messageID,
                subject: subject,
                sender: sender,
                recipients: recipients,
                dateText: dateText,
                date: date,
                isRead: isRead,
                isStarred: isStarred
            )
        }
    }

    static func load(accountID: UUID) -> MailPage? {
        let url = fileURL(accountID: accountID)
        guard let data = try? Data(contentsOf: url), data.count <= 2_000_000,
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              snapshot.total >= 0, snapshot.messages.count <= 100,
              Date().timeIntervalSince(snapshot.savedAt) < 14 * 24 * 60 * 60 else { return nil }
        return MailPage(messages: snapshot.messages.map(\.summary), total: snapshot.total)
    }

    static func save(accountID: UUID, page: MailPage) {
        let snapshot = Snapshot(
            savedAt: Date(),
            total: max(0, page.total),
            messages: page.messages.prefix(100).map(Row.init)
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        let directory = snapshotsDirectory()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = fileURL(accountID: accountID)
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            return
        }
    }

    private static func snapshotsDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Gmail Reader", isDirectory: true)
            .appendingPathComponent("mailbox-snapshots", isDirectory: true)
    }

    private static func fileURL(accountID: UUID) -> URL {
        snapshotsDirectory().appendingPathComponent("\(accountID.uuidString).json")
    }
}
