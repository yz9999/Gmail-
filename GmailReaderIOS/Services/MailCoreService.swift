import Foundation
import MailCore

@MainActor
final class MailCoreService {
    private var sessions: [UUID: MCOIMAPSession] = [:]
    private var folderCache: [UUID: [MailboxKind: String]] = [:]

    func cancelOperations(for accountID: UUID?) {
        if let accountID { sessions[accountID]?.cancelAllOperations() }
        else { sessions.values.forEach { $0.cancelAllOperations() } }
    }

    func verify(credentials: MailCredentials) async throws {
        let session = configuredSession(credentials: credentials, cache: false)
        guard let operation = session.checkAccountOperation() else {
            throw GmailReaderError.mail("无法创建 Gmail 验证请求")
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                operation.start { error in
                    if let error { continuation.resume(throwing: self.friendly(error)) }
                    else { continuation.resume() }
                }
            }
        } onCancel: {
            operation.cancel()
        }
    }

    func page(kind: MailboxKind, page: Int, pageSize: Int, query: String?,
              credentials: MailCredentials) async throws -> MailPage {
        let session = configuredSession(credentials: credentials)
        let folders = try await folders(for: credentials, session: session)
        let hasQuery = !(query?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let folder = hasQuery ? (folders[.all] ?? "INBOX") : resolveFolder(kind, folders: folders)
        let expression: MCOIMAPSearchExpression
        if let query, hasQuery {
            let clean = try validateSearch(query)
            expression = MCOIMAPSearchExpression.searchGmailRaw(clean)
        } else {
            switch kind {
            case .unread: expression = MCOIMAPSearchExpression.searchUnread()
            case .starred: expression = MCOIMAPSearchExpression.searchFlagged()
            default: expression = MCOIMAPSearchExpression.searchAll()
            }
        }

        let allUIDs = try await search(session: session, folder: folder, expression: expression)
        let total = allUIDs.count
        let end = max(0, total - max(0, page - 1) * pageSize)
        let start = max(0, end - pageSize)
        let pageUIDs = start < end ? Array(allUIDs[start..<end].reversed()) : []
        guard !pageUIDs.isEmpty else { return MailPage(messages: [], total: total) }

        let indexSet = makeIndexSet(pageUIDs)
        let requestKind: MCOIMAPMessagesRequestKind = [.headers, .internalDate, .flags]
        guard let operation = session.fetchMessagesOperation(withFolder: folder, requestKind: requestKind, uids: indexSet) else {
            throw GmailReaderError.mail("无法创建邮件列表请求")
        }
        let fetched: [MCOIMAPMessage] = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                operation.start { error, messages, _ in
                    if let error { continuation.resume(throwing: self.friendly(error)) }
                    else { continuation.resume(returning: messages ?? []) }
                }
            }
        } onCancel: {
            operation.cancel()
        }
        let byUID = Dictionary(uniqueKeysWithValues: fetched.map { ($0.uid, $0) })
        let summaries = pageUIDs.compactMap { uid -> MailSummary? in
            guard let message = byUID[uid] else { return nil }
            return makeSummary(message, folder: folder)
        }
        return MailPage(messages: summaries, total: total)
    }

    func message(summary: MailSummary, credentials: MailCredentials) async throws -> MailMessage {
        let session = configuredSession(credentials: credentials)
        guard let operation = session.fetchMessageOperation(withFolder: summary.folder, uid: summary.uid) else {
            throw GmailReaderError.mail("无法创建邮件正文请求")
        }
        let data: Data = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                operation.start { error, data in
                    if let error { continuation.resume(throwing: self.friendly(error)) }
                    else if let data { continuation.resume(returning: data) }
                    else { continuation.resume(throwing: GmailReaderError.mail("Gmail 没有返回邮件正文")) }
                }
            }
        } onCancel: {
            operation.cancel()
        }
        guard let parser = MCOMessageParser(data: data) else {
            throw GmailReaderError.mail("无法解析这封邮件")
        }
        return MailMessage(
            uid: summary.uid,
            folder: summary.folder,
            messageID: parser.header.messageID ?? summary.messageID,
            subject: parser.header.subject?.nonEmpty ?? summary.subject,
            sender: formatAddress(parser.header.from) ?? summary.sender,
            recipients: formatAddresses(parser.header.to as? [MCOAddress]) ?? summary.recipients,
            date: parser.header.date ?? summary.date,
            plainBody: parser.plainTextBodyRenderingAndStripWhitespace(false) ?? "",
            htmlBody: parser.htmlBodyRendering() ?? "",
            isRead: true,
            isStarred: summary.isStarred
        )
    }

    func setFlag(summary: MailSummary, flag: MCOMessageFlag, enabled: Bool,
                 credentials: MailCredentials) async throws {
        let session = configuredSession(credentials: credentials)
        let uids = MCOIndexSet(index: UInt64(summary.uid))
        let kind: MCOIMAPStoreFlagsRequestKind = enabled ? .add : .remove
        guard let operation = session.storeFlagsOperation(withFolder: summary.folder, uids: uids, kind: kind, flags: flag) else {
            throw GmailReaderError.mail("无法创建邮件标记请求")
        }
        try await run(operation)
    }

    func markAllRead(kind: MailboxKind, query: String?, credentials: MailCredentials) async throws -> Int {
        let session = configuredSession(credentials: credentials)
        let folders = try await folders(for: credentials, session: session)
        let hasQuery = !(query?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let folder = hasQuery ? (folders[.all] ?? "INBOX") : resolveFolder(kind, folders: folders)
        guard let unread = MCOIMAPSearchExpression.searchUnread() else {
            throw GmailReaderError.mail("无法创建 Gmail 未读搜索条件")
        }
        let expression: MCOIMAPSearchExpression
        if let query, hasQuery {
            guard let combined = MCOIMAPSearchExpression.searchAnd(unread, other: .searchGmailRaw(try validateSearch(query))) else {
                throw GmailReaderError.mail("无法创建 Gmail 搜索条件")
            }
            expression = combined
        } else if kind == .starred {
            guard let combined = MCOIMAPSearchExpression.searchAnd(unread, other: .searchFlagged()) else {
                throw GmailReaderError.mail("无法创建 Gmail 星标搜索条件")
            }
            expression = combined
        } else {
            expression = unread
        }
        let values = try await search(session: session, folder: folder, expression: expression)
        guard !values.isEmpty else { return 0 }
        guard let operation = session.storeFlagsOperation(withFolder: folder, uids: makeIndexSet(values),
                                                          kind: .add, flags: .seen) else {
            throw GmailReaderError.mail("无法创建全部标记已读请求")
        }
        try await run(operation)
        return values.count
    }

    func send(recipients: [String], subject: String, body: String,
              credentials: MailCredentials) async throws {
        let cleanRecipients = recipients.map(sanitizeHeader).filter(isValidEmail)
        guard cleanRecipients.count == recipients.count, !cleanRecipients.isEmpty else {
            throw GmailReaderError.configuration("请输入有效的收件人地址")
        }
        let builder = MCOMessageBuilder()
        builder.header.from = MCOAddress(displayName: credentials.account.name, mailbox: credentials.account.address)
        let addresses: [MCOAddress] = cleanRecipients.compactMap { MCOAddress(mailbox: $0) }
        guard addresses.count == cleanRecipients.count else { throw GmailReaderError.mail("无法生成收件人地址") }
        builder.header.to = addresses
        builder.header.subject = sanitizeHeader(subject)
        builder.textBody = body
        guard let data = builder.data() else { throw GmailReaderError.mail("无法生成待发送邮件") }

        let session = MCOSMTPSession()
        session.hostname = "smtp.gmail.com"
        session.port = 465
        session.username = credentials.account.address
        session.password = credentials.password
        session.connectionType = .TLS
        session.isCheckCertificateEnabled = true
        session.timeout = 30
        guard let operation = session.sendOperation(with: data) else {
            throw GmailReaderError.mail("无法创建 Gmail 发送请求")
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                operation.start { error in
                    if let error { continuation.resume(throwing: self.friendly(error)) }
                    else { continuation.resume() }
                }
            }
        } onCancel: {
            operation.cancel()
        }
    }

    private func configuredSession(credentials: MailCredentials, cache: Bool = true) -> MCOIMAPSession {
        if cache, let session = sessions[credentials.account.id] {
            session.username = credentials.account.address
            session.password = credentials.password
            return session
        }
        let session = MCOIMAPSession()
        session.hostname = "imap.gmail.com"
        session.port = 993
        session.username = credentials.account.address
        session.password = credentials.password
        session.connectionType = .TLS
        session.isCheckCertificateEnabled = true
        // MailCore2 默认会在 iOS 上启用 VoIP socket。这个旧的预编译框架
        // 在部分新版 iOS 真机上开始 IMAP 操作时会直接崩溃。普通邮件
        // 客户端不需要 VoIP 能力，必须在首次连接前明确关闭。
        session.isVoIPEnabled = false
        session.timeout = 30
        session.maximumConnections = 4
        session.allowsFolderConcurrentAccessEnabled = true
        if cache { sessions[credentials.account.id] = session }
        return session
    }

    private func folders(for credentials: MailCredentials, session: MCOIMAPSession) async throws -> [MailboxKind: String] {
        if let cached = folderCache[credentials.account.id] { return cached }
        guard let operation = session.fetchAllFoldersOperation() else {
            throw GmailReaderError.mail("无法读取 Gmail 文件夹")
        }
        let folders: [MCOIMAPFolder] = try await withCheckedThrowingContinuation { continuation in
            operation.start { error, folders in
                if let error { continuation.resume(throwing: self.friendly(error)) }
                else { continuation.resume(returning: folders ?? []) }
            }
        }
        var result: [MailboxKind: String] = [.inbox: "INBOX", .unread: "INBOX"]
        for folder in folders {
            if folder.flags.contains(.allMail) { result[.all] = folder.path; result[.starred] = folder.path }
            if folder.flags.contains(.sentMail) { result[.sent] = folder.path }
            if folder.flags.contains(.drafts) { result[.drafts] = folder.path }
            if folder.flags.contains(.spam) { result[.spam] = folder.path }
            if folder.flags.contains(.trash) { result[.trash] = folder.path }
        }
        result[.all] = result[.all] ?? "INBOX"
        result[.starred] = result[.starred] ?? result[.all]
        folderCache[credentials.account.id] = result
        return result
    }

    private func resolveFolder(_ kind: MailboxKind, folders: [MailboxKind: String]) -> String {
        switch kind {
        case .unread: return "INBOX"
        default: return folders[kind] ?? "INBOX"
        }
    }

    private func search(session: MCOIMAPSession, folder: String,
                        expression: MCOIMAPSearchExpression) async throws -> [UInt32] {
        guard let operation = session.searchExpressionOperation(withFolder: folder, expression: expression) else {
            throw GmailReaderError.mail("无法创建 Gmail 搜索请求")
        }
        let indexSet: MCOIndexSet = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                operation.start { error, values in
                    if let error { continuation.resume(throwing: self.friendly(error)) }
                    else if let values { continuation.resume(returning: values) }
                    else { continuation.resume(returning: MCOIndexSet()) }
                }
            }
        } onCancel: {
            operation.cancel()
        }
        var result: [UInt32] = []
        indexSet.enumerate { value in
            if value <= UInt64(UInt32.max) { result.append(UInt32(value)) }
        }
        return result.sorted()
    }

    private func makeIndexSet(_ values: [UInt32]) -> MCOIndexSet {
        let result = MCOIndexSet()
        values.forEach { result.add(UInt64($0)) }
        return result
    }

    private func makeSummary(_ message: MCOIMAPMessage, folder: String) -> MailSummary {
        MailSummary(
            uid: message.uid,
            folder: folder,
            messageID: message.header.messageID ?? "",
            subject: message.header.subject?.nonEmpty ?? "（无主题）",
            sender: formatAddress(message.header.from) ?? "（未知发件人）",
            recipients: formatAddresses(message.header.to as? [MCOAddress]) ?? "",
            date: message.header.date ?? message.header.receivedDate,
            isRead: message.flags.contains(.seen),
            isStarred: message.flags.contains(.flagged)
        )
    }

    private func formatAddress(_ address: MCOAddress?) -> String? {
        guard let address else { return nil }
        if let name = address.displayName?.nonEmpty, let mailbox = address.mailbox?.nonEmpty { return "\(name) <\(mailbox)>" }
        return address.mailbox?.nonEmpty ?? address.displayName?.nonEmpty
    }

    private func formatAddresses(_ addresses: [MCOAddress]?) -> String? {
        guard let addresses else { return nil }
        return addresses.compactMap(formatAddress).joined(separator: ", ")
    }

    private func run(_ operation: MCOIMAPOperation) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                operation.start { error in
                    if let error { continuation.resume(throwing: self.friendly(error)) }
                    else { continuation.resume() }
                }
            }
        } onCancel: {
            operation.cancel()
        }
    }

    private func validateSearch(_ value: String) throws -> String {
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.count <= 512 else { throw GmailReaderError.configuration("搜索内容不能超过 512 个字符") }
        guard !result.contains("\r"), !result.contains("\n"), !result.contains("\0") else {
            throw GmailReaderError.configuration("搜索内容包含无效字符")
        }
        return result
    }

    private func sanitizeHeader(_ value: String) -> String {
        value.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isValidEmail(_ value: String) -> Bool {
        guard value.count <= 254, !value.contains(where: { $0.isWhitespace }) else { return false }
        let components = value.split(separator: "@", omittingEmptySubsequences: false)
        return components.count == 2 && !components[0].isEmpty && components[1].contains(".")
    }

    private func friendly(_ error: Error) -> GmailReaderError {
        let message = error.localizedDescription
        if message.localizedCaseInsensitiveContains("authentication") || message.localizedCaseInsensitiveContains("login") {
            return .mail("Gmail 登录失败，请检查邮箱地址和应用专用密码")
        }
        if message.localizedCaseInsensitiveContains("certificate") {
            return .mail("Gmail TLS 证书验证失败")
        }
        return .mail("Gmail 请求失败：\(message)")
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
