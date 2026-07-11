import Foundation

actor GmailService {
    private let imapBaseURL = "imaps://imap.gmail.com:993"
    private let smtpURL = "smtps://smtp.gmail.com:465"
    private var folderCache: [String: [MailboxKind: String]] = [:]

    func verify(credentials: GmailCredentials) async throws {
        _ = try await CurlTransport.imap(url: "\(imapBaseURL)/INBOX", credentials: credentials, command: "NOOP", timeout: 30)
    }

    func page(kind: MailboxKind, page: Int, pageSize: Int, query: String?, credentials: GmailCredentials) async throws -> MailPage {
        let folders = try await folders(credentials: credentials)
        let folder = resolveFolder(kind, folders: folders)
        let encodedFolder = encodeMailbox(folder)
        let criteria: String
        if let query, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let clean = try safeSearchQuery(query)
            let allFolder = folders[.all] ?? "INBOX"
            return try await searchPage(folder: allFolder, page: page, pageSize: pageSize, query: clean, credentials: credentials)
        }
        switch kind {
        case .unread: criteria = "UNSEEN"
        case .starred: criteria = "FLAGGED"
        default: criteria = "ALL"
        }
        let response = try await CurlTransport.imap(url: "\(imapBaseURL)/\(encodedFolder)", credentials: credentials,
                                                    command: "UID SEARCH \(criteria)")
        return try await makePage(searchResponse: response, folder: folder, page: page, pageSize: pageSize, credentials: credentials)
    }

    func message(uid: UInt64, kind: MailboxKind, query: String?, credentials: GmailCredentials) async throws -> MailMessage {
        let folders = try await folders(credentials: credentials)
        let folder = (query?.isEmpty == false) ? (folders[.all] ?? "INBOX") : resolveFolder(kind, folders: folders)
        let encoded = encodeMailbox(folder)
        let flags = try await flags(for: [uid], folder: folder, credentials: credentials)[uid] ?? []
        let raw = try await CurlTransport.imap(url: "\(imapBaseURL)/\(encoded);UID=\(uid)", credentials: credentials, timeout: 90)
        return MIMEParser.message(uid: uid, raw: raw, flags: flags)
    }

    func setFlag(uid: UInt64, kind: MailboxKind, query: String?, flag: String, enabled: Bool,
                 credentials: GmailCredentials) async throws {
        let folders = try await folders(credentials: credentials)
        let folder = (query?.isEmpty == false) ? (folders[.all] ?? "INBOX") : resolveFolder(kind, folders: folders)
        let operation = enabled ? "+FLAGS.SILENT" : "-FLAGS.SILENT"
        _ = try await CurlTransport.imap(url: "\(imapBaseURL)/\(encodeMailbox(folder))", credentials: credentials,
                                        command: "UID STORE \(uid) \(operation) (\(flag))")
    }

    func markAllRead(kind: MailboxKind, query: String?, credentials: GmailCredentials) async throws -> Int {
        let folders = try await folders(credentials: credentials)
        let folder = (query?.isEmpty == false) ? (folders[.all] ?? "INBOX") : resolveFolder(kind, folders: folders)
        var uids: [UInt64]
        if let query, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let clean = try safeSearchQuery(query)
            if clean.unicodeScalars.allSatisfy(\.isASCII) {
                let search = try await CurlTransport.imap(url: "\(imapBaseURL)/\(encodeMailbox(folder))", credentials: credentials,
                                                          command: "UID SEARCH UNSEEN X-GM-RAW \"\(escapeQuoted(clean))\"")
                uids = parseSearch(search)
            } else {
                let search = try await CurlTransport.searchUTF8(folder: folder, query: clean, credentials: credentials)
                let all = parseSearch(search)
                var resolvedFlags: [UInt64: Set<String>] = [:]
                for chunk in all.chunked(into: 500) {
                    let values = try await flags(for: chunk, folder: folder, credentials: credentials)
                    resolvedFlags.merge(values) { _, new in new }
                }
                uids = all.filter { !(resolvedFlags[$0] ?? []).contains("\\Seen") }
            }
        } else if kind == .starred {
            let search = try await CurlTransport.imap(url: "\(imapBaseURL)/\(encodeMailbox(folder))", credentials: credentials,
                                                      command: "UID SEARCH UNSEEN FLAGGED")
            uids = parseSearch(search)
        } else {
            let search = try await CurlTransport.imap(url: "\(imapBaseURL)/\(encodeMailbox(folder))", credentials: credentials,
                                                      command: "UID SEARCH UNSEEN")
            uids = parseSearch(search)
        }
        guard !uids.isEmpty else { return 0 }
        for chunk in uids.chunked(into: 500) {
            let set = chunk.map(String.init).joined(separator: ",")
            _ = try await CurlTransport.imap(url: "\(imapBaseURL)/\(encodeMailbox(folder))", credentials: credentials,
                                            command: "UID STORE \(set) +FLAGS.SILENT (\\Seen)", timeout: 90)
        }
        return uids.count
    }

    func send(to recipients: [String], subject: String, body: String, credentials: GmailCredentials) async throws {
        guard !recipients.isEmpty else { throw GmailReaderError.configuration("请输入收件人") }
        let cleanRecipients = recipients.map { sanitizeHeader($0) }.filter(isValidEmailAddress)
        guard cleanRecipients.count == recipients.count else { throw GmailReaderError.configuration("收件人地址无效") }
        let cleanSubject = sanitizeHeader(subject)
        let encodedSubject = cleanSubject.unicodeScalars.allSatisfy(\.isASCII)
            ? cleanSubject
            : "=?UTF-8?B?\(Data(cleanSubject.utf8).base64EncodedString())?="
        let messageID = "<\(UUID().uuidString)@gmail-reader.local>"
        let normalizedBody = body.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
        let raw = [
            "From: \(credentials.address)",
            "To: \(cleanRecipients.joined(separator: ", "))",
            "Subject: \(encodedSubject)",
            "Date: \(smtpDate())",
            "Message-ID: \(messageID)",
            "MIME-Version: 1.0",
            "Content-Type: text/plain; charset=UTF-8",
            "Content-Transfer-Encoding: base64",
            "",
            Data(normalizedBody.utf8).base64EncodedString(options: .lineLength76Characters),
            "",
        ].joined(separator: "\r\n")
        try await CurlTransport.smtp(url: smtpURL, sender: credentials.address, recipients: cleanRecipients,
                                     message: Data(raw.utf8), credentials: credentials)
    }

    private func searchPage(folder: String, page: Int, pageSize: Int, query: String,
                            credentials: GmailCredentials) async throws -> MailPage {
        let response: Data
        if query.unicodeScalars.allSatisfy(\.isASCII) {
            let command = "UID SEARCH X-GM-RAW \"\(escapeQuoted(query))\""
            response = try await CurlTransport.imap(url: "\(imapBaseURL)/\(encodeMailbox(folder))", credentials: credentials,
                                                    command: command, timeout: 90)
        } else {
            response = try await CurlTransport.searchUTF8(folder: folder, query: query, credentials: credentials)
        }
        return try await makePage(searchResponse: response, folder: folder, page: page, pageSize: pageSize, credentials: credentials)
    }

    private func makePage(searchResponse: Data, folder: String, page: Int, pageSize: Int,
                          credentials: GmailCredentials) async throws -> MailPage {
        let allUIDs = parseSearch(searchResponse)
        let total = allUIDs.count
        let end = max(0, total - max(0, page - 1) * pageSize)
        let start = max(0, end - pageSize)
        let selected = start < end ? Array(allUIDs[start..<end].reversed()) : []
        guard !selected.isEmpty else { return MailPage(messages: [], total: total) }
        let payloads = try await CurlTransport.fetchSummaries(folder: folder, uids: selected, credentials: credentials)
        let summaries: [MailSummary] = selected.compactMap { uid -> MailSummary? in
            guard let payload = payloads[uid] else { return nil }
            return MIMEParser.summary(uid: uid, headerData: payload.header, flags: payload.flags)
        }
        return MailPage(messages: summaries, total: total)
    }

    private func flags(for uids: [UInt64], folder: String, credentials: GmailCredentials) async throws -> [UInt64: Set<String>] {
        guard !uids.isEmpty else { return [:] }
        let set = uids.map(String.init).joined(separator: ",")
        let response = try await CurlTransport.imap(url: "\(imapBaseURL)/\(encodeMailbox(folder))", credentials: credentials,
                                                    command: "UID FETCH \(set) (UID FLAGS)")
        let text = String(decoding: response, as: UTF8.self)
        let regex = try NSRegularExpression(pattern: #"UID\s+(\d+)\s+FLAGS\s+\(([^)]*)\)"#, options: .caseInsensitive)
        var result: [UInt64: Set<String>] = [:]
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let uidRange = Range(match.range(at: 1), in: text), let uid = UInt64(text[uidRange]),
                  let flagRange = Range(match.range(at: 2), in: text) else { continue }
            result[uid] = Set(text[flagRange].split(whereSeparator: \.isWhitespace).map(String.init))
        }
        return result
    }

    private func folders(credentials: GmailCredentials) async throws -> [MailboxKind: String] {
        if let cached = folderCache[credentials.address] { return cached }
        let response = try await CurlTransport.imap(url: "\(imapBaseURL)/", credentials: credentials, command: "LIST \"\" \"*\"")
        let text = String(decoding: response, as: UTF8.self)
        var map: [MailboxKind: String] = [.inbox: "INBOX", .unread: "INBOX", .starred: "INBOX"]
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.uppercased().hasPrefix("* LIST "), let open = line.firstIndex(of: "("),
                  let close = line[open...].firstIndex(of: ")") else { continue }
            let attributes = String(line[line.index(after: open)..<close]).lowercased()
            guard let mailbox = parseLastIMAPToken(String(line[line.index(after: close)...])) else { continue }
            if attributes.contains("\\all") { map[.all] = mailbox }
            if attributes.contains("\\sent") { map[.sent] = mailbox }
            if attributes.contains("\\drafts") { map[.drafts] = mailbox }
            if attributes.contains("\\junk") || attributes.contains("\\spam") { map[.spam] = mailbox }
            if attributes.contains("\\trash") { map[.trash] = mailbox }
        }
        map[.all] = map[.all] ?? "INBOX"
        map[.starred] = map[.all]
        folderCache[credentials.address] = map
        return map
    }

    private func resolveFolder(_ kind: MailboxKind, folders: [MailboxKind: String]) -> String {
        switch kind {
        case .unread: return "INBOX"
        default: return folders[kind] ?? "INBOX"
        }
    }

    private func parseSearch(_ data: Data) -> [UInt64] {
        let text = String(decoding: data, as: UTF8.self)
        guard let line = text.components(separatedBy: .newlines).first(where: { $0.uppercased().hasPrefix("* SEARCH") }) else { return [] }
        return line.split(whereSeparator: \.isWhitespace).dropFirst(2).compactMap { UInt64($0) }
    }

    private func parseLastIMAPToken(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("\"") {
            var escaped = false
            var start: String.Index?
            var index = trimmed.index(before: trimmed.endIndex)
            while index > trimmed.startIndex {
                index = trimmed.index(before: index)
                let character = trimmed[index]
                if character == "\"", !escaped { start = index; break }
                escaped = character == "\\" && !escaped
                if character != "\\" { escaped = false }
            }
            if let start {
                return String(trimmed[trimmed.index(after: start)..<trimmed.index(before: trimmed.endIndex)])
                    .replacingOccurrences(of: "\\\"", with: "\"")
                    .replacingOccurrences(of: "\\\\", with: "\\")
            }
        }
        return trimmed.split(whereSeparator: \.isWhitespace).last.map(String.init)
    }

    private func encodeMailbox(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "/-._~&")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "INBOX"
    }

    private func safeSearchQuery(_ value: String) throws -> String {
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.count <= 512 else { throw GmailReaderError.configuration("搜索内容不能超过 512 个字符") }
        guard !result.contains("\r"), !result.contains("\n"), !result.contains("\0") else {
            throw GmailReaderError.configuration("搜索内容包含无效字符")
        }
        return result
    }

    private func escapeQuoted(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func sanitizeHeader(_ value: String) -> String {
        value.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "").trimmingCharacters(in: .whitespaces)
    }

    private func isValidEmailAddress(_ value: String) -> Bool {
        guard value.count <= 254, !value.contains(where: { $0.isWhitespace }) else { return false }
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty, parts[1].contains(".") else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.!#$%&'*+/=?^_`{|}~-@")
        return value.unicodeScalars.allSatisfy(allowed.contains)
    }

    private func smtpDate() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter.string(from: Date())
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
