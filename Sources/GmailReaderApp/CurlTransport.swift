import CurlShim
import Foundation

struct GmailCredentials: Sendable {
    let address: String
    let password: String
    let proxy: ProxySettings
}

enum CurlTransport {
    struct SummaryPayload {
        let header: Data
        let flags: Set<String>
    }
    private static let initialized: Bool = gr_curl_initialize() != 0

    static func imap(url: String, credentials: GmailCredentials, command: String? = nil, timeout: Int = 60) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            guard initialized else { throw GmailReaderError.network("无法初始化系统网络库") }
            let urlPointer = try duplicate(url)
            let username = try duplicate(credentials.address)
            let password = try duplicate(credentials.password)
            let proxyHost = credentials.proxy.enabled ? try duplicate(credentials.proxy.host) : nil
            let request = try command.map(duplicate)
            defer { free(urlPointer); free(username); free(password); free(proxyHost); free(request) }
            let result = gr_imap_request(urlPointer, username, password, proxyHost,
                                         credentials.proxy.enabled ? Int32(credentials.proxy.port) : 0,
                                         request, Int(timeout))
            return try consume(result)
        }.value
    }

    static func fetchHeaders(baseURL: String, encodedFolder: String, uids: [UInt64], credentials: GmailCredentials) async throws -> [Data] {
        guard !uids.isEmpty else { return [] }
        let csv = uids.map(String.init).joined(separator: ",")
        let section = "HEADER.FIELDS%20(FROM%20TO%20SUBJECT%20DATE%20MESSAGE-ID)"
        let framed = try await Task.detached(priority: .userInitiated) {
            let base = try duplicate(baseURL)
            let folder = try duplicate(encodedFolder)
            let uidPointer = try duplicate(csv)
            let sectionPointer = try duplicate(section)
            let username = try duplicate(credentials.address)
            let password = try duplicate(credentials.password)
            let proxyHost = credentials.proxy.enabled ? try duplicate(credentials.proxy.host) : nil
            defer { free(base); free(folder); free(uidPointer); free(sectionPointer); free(username); free(password); free(proxyHost) }
            return try consume(gr_imap_fetch_many(base, folder, uidPointer, sectionPointer, username, password,
                                                  proxyHost, credentials.proxy.enabled ? Int32(credentials.proxy.port) : 0, 90))
        }.value
        return try decodeFrames(framed, expectedCount: uids.count)
    }

    static func searchUTF8(folder: String, query: String, credentials: GmailCredentials) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            let host = try duplicate("imap.gmail.com")
            let folderPointer = try duplicate(folder)
            let queryPointer = try duplicate(query)
            let username = try duplicate(credentials.address)
            let password = try duplicate(credentials.password)
            let proxyHost = credentials.proxy.enabled ? try duplicate(credentials.proxy.host) : nil
            defer { free(host); free(folderPointer); free(queryPointer); free(username); free(password); free(proxyHost) }
            return try consume(gr_imap_search_utf8(host, 993, folderPointer, queryPointer, username, password,
                                                   proxyHost, credentials.proxy.enabled ? Int32(credentials.proxy.port) : 0, 60))
        }.value
    }

    static func fetchSummaries(folder: String, uids: [UInt64], credentials: GmailCredentials) async throws -> [UInt64: SummaryPayload] {
        guard !uids.isEmpty else { return [:] }
        let csv = uids.map(String.init).joined(separator: ",")
        let response = try await Task.detached(priority: .userInitiated) {
            let host = try duplicate("imap.gmail.com")
            let folderPointer = try duplicate(folder)
            let uidPointer = try duplicate(csv)
            let username = try duplicate(credentials.address)
            let password = try duplicate(credentials.password)
            let proxyHost = credentials.proxy.enabled ? try duplicate(credentials.proxy.host) : nil
            defer { free(host); free(folderPointer); free(uidPointer); free(username); free(password); free(proxyHost) }
            return try consume(gr_imap_fetch_summaries(host, 993, folderPointer, uidPointer, username, password,
                                                       proxyHost, credentials.proxy.enabled ? Int32(credentials.proxy.port) : 0, 60))
        }.value
        return try parseSummaryResponse(response, expectedUIDs: Set(uids))
    }

    static func smtp(url: String, sender: String, recipients: [String], message: Data, credentials: GmailCredentials) async throws {
        let recipientLines = recipients.joined(separator: "\n")
        _ = try await Task.detached(priority: .userInitiated) {
            let urlPointer = try duplicate(url)
            let username = try duplicate(credentials.address)
            let password = try duplicate(credentials.password)
            let senderPointer = try duplicate(sender)
            let recipientPointer = try duplicate(recipientLines)
            let proxyHost = credentials.proxy.enabled ? try duplicate(credentials.proxy.host) : nil
            defer { free(urlPointer); free(username); free(password); free(senderPointer); free(recipientPointer); free(proxyHost) }
            let nsData = message as NSData
            let bytes = nsData.bytes.assumingMemoryBound(to: UInt8.self)
            return try consume(gr_smtp_send(urlPointer, username, password, proxyHost,
                                            credentials.proxy.enabled ? Int32(credentials.proxy.port) : 0,
                                            senderPointer, recipientPointer, bytes, message.count, 60))
        }.value
    }

    private static func duplicate(_ value: String) throws -> UnsafeMutablePointer<CChar> {
        guard let pointer = strdup(value) else { throw GmailReaderError.network("内存不足") }
        return pointer
    }

    private static func consume(_ result: GRResult) throws -> Data {
        defer { gr_result_free(result) }
        if let error = result.error {
            let raw = String(cString: error)
            let message: String
            if raw.localizedCaseInsensitiveContains("login") || raw.contains("AUTHENTICATIONFAILED") {
                message = "Gmail 登录失败，请检查邮箱地址和应用专用密码"
            } else if raw.localizedCaseInsensitiveContains("proxy") || raw.localizedCaseInsensitiveContains("connect") {
                message = "无法通过 SOCKS5 代理连接 Gmail：\(raw)"
            } else if raw.localizedCaseInsensitiveContains("message summaries") {
                message = "获取 Gmail 邮件摘要失败，请刷新重试"
            } else {
                message = "Gmail 网络请求失败：\(raw)"
            }
            throw GmailReaderError.network(message)
        }
        guard result.length == 0 || result.data != nil else {
            throw GmailReaderError.network("Gmail 返回了无效数据")
        }
        return result.length == 0 ? Data() : Data(bytes: result.data!, count: result.length)
    }

    private static func decodeFrames(_ data: Data, expectedCount: Int) throws -> [Data] {
        var offset = 0
        var frames: [Data] = []
        while offset < data.count {
            guard data.count - offset >= 4 else { throw GmailReaderError.protocolError("邮件头批量响应不完整") }
            let length = data[offset..<offset + 4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            offset += 4
            guard length <= Int.max, data.count - offset >= Int(length) else {
                throw GmailReaderError.protocolError("邮件头批量响应长度无效")
            }
            frames.append(data.subdata(in: offset..<offset + Int(length)))
            offset += Int(length)
        }
        guard frames.count == expectedCount else { throw GmailReaderError.protocolError("未能读取完整的邮件列表") }
        return frames
    }

    private static func parseSummaryResponse(_ data: Data, expectedUIDs: Set<UInt64>) throws -> [UInt64: SummaryPayload] {
        let fetchMarker = Data("FETCH (".utf8)
        let literalEndMarker = Data("}\r\n".utf8)
        let uidRegex = try NSRegularExpression(pattern: #"UID\s+(\d+)"#, options: .caseInsensitive)
        let flagsRegex = try NSRegularExpression(pattern: #"FLAGS\s+\(([^)]*)\)"#, options: .caseInsensitive)
        let lengthRegex = try NSRegularExpression(pattern: #"\{(\d+)\}$"#)
        var cursor = data.startIndex
        var result: [UInt64: SummaryPayload] = [:]
        while cursor < data.endIndex,
              let fetch = data.range(of: fetchMarker, in: cursor..<data.endIndex),
              let marker = data.range(of: literalEndMarker, in: fetch.lowerBound..<data.endIndex) {
            let metadataData = data.subdata(in: fetch.lowerBound..<marker.lowerBound + 1)
            let metadata = String(decoding: metadataData, as: UTF8.self)
            let fullRange = NSRange(metadata.startIndex..., in: metadata)
            guard let uidMatch = uidRegex.firstMatch(in: metadata, range: fullRange),
                  let uidRange = Range(uidMatch.range(at: 1), in: metadata), let uid = UInt64(metadata[uidRange]),
                  let lengthMatch = lengthRegex.firstMatch(in: metadata, range: fullRange),
                  let lengthRange = Range(lengthMatch.range(at: 1), in: metadata), let length = Int(metadata[lengthRange]) else {
                throw GmailReaderError.protocolError("Gmail 邮件摘要响应格式无效")
            }
            let literalStart = marker.upperBound
            guard length >= 0, data.distance(from: literalStart, to: data.endIndex) >= length else {
                throw GmailReaderError.protocolError("Gmail 邮件摘要内容不完整")
            }
            let literalEnd = data.index(literalStart, offsetBy: length)
            var flags: Set<String> = []
            if let match = flagsRegex.firstMatch(in: metadata, range: fullRange),
               let range = Range(match.range(at: 1), in: metadata) {
                flags = Set(metadata[range].split(whereSeparator: \.isWhitespace).map(String.init))
            }
            result[uid] = SummaryPayload(header: data.subdata(in: literalStart..<literalEnd), flags: flags)
            cursor = literalEnd
        }
        guard expectedUIDs.isSubset(of: Set(result.keys)) else {
            throw GmailReaderError.protocolError("部分邮件在刷新期间发生变化，请重新刷新")
        }
        return result
    }
}
