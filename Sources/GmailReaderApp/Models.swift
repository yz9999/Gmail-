import Foundation

struct MailAccount: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var address: String

    init(id: UUID = UUID(), name: String, address: String) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.address = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

enum MailboxKind: String, CaseIterable, Identifiable {
    case inbox, starred, unread, sent, drafts, all, spam, trash

    var id: String { rawValue }
    var title: String {
        switch self {
        case .inbox: return "收件箱"
        case .starred: return "已加星标"
        case .unread: return "未读"
        case .sent: return "已发邮件"
        case .drafts: return "草稿"
        case .all: return "所有邮件"
        case .spam: return "垃圾邮件"
        case .trash: return "已删除邮件"
        }
    }
    var symbol: String {
        switch self {
        case .inbox: return "tray.fill"
        case .starred: return "star"
        case .unread: return "envelope.badge"
        case .sent: return "paperplane"
        case .drafts: return "doc"
        case .all: return "tray.2"
        case .spam: return "exclamationmark.octagon"
        case .trash: return "trash"
        }
    }
}

struct MailSummary: Identifiable, Hashable {
    let uid: UInt64
    let messageID: String
    let subject: String
    let sender: String
    let recipients: String
    let dateText: String
    let date: Date?
    var isRead: Bool
    var isStarred: Bool

    var id: UInt64 { uid }
    var senderDisplay: String {
        let value = sender.trimmingCharacters(in: .whitespacesAndNewlines)
        if let angle = value.firstIndex(of: "<") {
            let name = value[..<angle].trimmingCharacters(in: CharacterSet(charactersIn: " \""))
            if !name.isEmpty { return String(name) }
        }
        return value.isEmpty ? "（未知发件人）" : value
    }
}

struct MailMessage: Identifiable {
    let uid: UInt64
    let messageID: String
    let subject: String
    let sender: String
    let recipients: String
    let dateText: String
    let plainBody: String
    let htmlBody: String
    var isRead: Bool
    var isStarred: Bool

    var id: UInt64 { uid }
}

struct MailPage {
    let messages: [MailSummary]
    let total: Int
}

struct ProxySettings: Equatable {
    var enabled: Bool
    var host: String
    var port: Int

    static let `default` = ProxySettings(enabled: true, host: "127.0.0.1", port: 6153)
}

enum GmailReaderError: LocalizedError {
    case configuration(String)
    case keychain(String)
    case network(String)
    case protocolError(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .configuration(let value), .keychain(let value), .network(let value), .protocolError(let value):
            return value
        case .cancelled:
            return "操作已取消"
        }
    }
}
