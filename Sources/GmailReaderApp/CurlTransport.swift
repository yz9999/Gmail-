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
    struct PagePayload {
        let allUIDs: [UInt64]
        let summaries: [UInt64: SummaryPayload]
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
            return try consume(result, usingProxy: credentials.proxy.enabled)
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
                                                  proxyHost, credentials.proxy.enabled ? Int32(credentials.proxy.port) : 0, 90),
                               usingProxy: credentials.proxy.enabled)
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
                                                   proxyHost, credentials.proxy.enabled ? Int32(credentials.proxy.port) : 0, 60),
                               usingProxy: credentials.proxy.enabled)
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
                                                       proxyHost, credentials.proxy.enabled ? Int32(credentials.proxy.port) : 0, 60),
                               usingProxy: credentials.proxy.enabled)
        }.value
        return try parseSummaryResponse(response, expectedUIDs: Set(uids))
    }

    static func fetchPage(folder: String, criteria: String, query: String?, page: Int, pageSize: Int,
                          credentials: GmailCredentials) async throws -> PagePayload {
        let response = try await Task.detached(priority: .userInitiated) {
            let host = try duplicate("imap.gmail.com")
            let folderPointer = try duplicate(folder)
            let criteriaPointer = try duplicate(criteria)
            let queryPointer = try query.map(duplicate)
            let username = try duplicate(credentials.address)
            let password = try duplicate(credentials.password)
            let proxyHost = credentials.proxy.enabled ? try duplicate(credentials.proxy.host) : nil
            defer {
                free(host); free(folderPointer); free(criteriaPointer); free(queryPointer)
                free(username); free(password); free(proxyHost)
            }
            let result = gr_imap_page(host, 993, folderPointer, criteriaPointer, queryPointer,
                                      Int32(page), Int32(pageSize), username, password, proxyHost,
                                      credentials.proxy.enabled ? Int32(credentials.proxy.port) : 0, 60)
            return try consume(result, usingProxy: credentials.proxy.enabled)
        }.value
        return try decodePage(response, page: page, pageSize: pageSize)
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
                                            senderPointer, recipientPointer, bytes, message.count, 60),
                               usingProxy: credentials.proxy.enabled)
        }.value
    }

    static func translateToChinese(_ text: String, proxy: ProxySettings) async throws -> String {
        let encoded = formEncode(text)
        let body = Data("client=gtx&sl=auto&tl=zh-CN&dt=t&q=\(encoded)".utf8)
        let response = try await Task.detached(priority: .userInitiated) {
            guard initialized else { throw GmailReaderError.network("无法初始化系统网络库") }
            let url = try duplicate("https://translate.googleapis.com/translate_a/single")
            let contentType = try duplicate("application/x-www-form-urlencoded; charset=UTF-8")
            let proxyHost = proxy.enabled ? try duplicate(proxy.host) : nil
            defer { free(url); free(contentType); free(proxyHost) }
            return try body.withUnsafeBytes { bytes in
                let pointer = bytes.bindMemory(to: UInt8.self).baseAddress
                guard let pointer else { throw GmailReaderError.configuration("没有可翻译的邮件正文") }
                let result = gr_http_post(url, pointer, body.count, contentType, proxyHost,
                                          proxy.enabled ? Int32(proxy.port) : 0, 30)
                return try consumeTranslation(result, usingProxy: proxy.enabled)
            }
        }.value
        return try parseTranslation(response)
    }

    private static func duplicate(_ value: String) throws -> UnsafeMutablePointer<CChar> {
        guard let pointer = strdup(value) else { throw GmailReaderError.network("内存不足") }
        return pointer
    }

    private static func consume(_ result: GRResult, usingProxy: Bool) throws -> Data {
        defer { gr_result_free(result) }
        if let error = result.error {
            let raw = String(cString: error)
            let lower = raw.lowercased()
            let message: String
            if lower.contains("login") || lower.contains("authentic") || raw.contains("AUTHENTICATIONFAILED") {
                message = "Gmail 登录失败，请检查邮箱地址和应用专用密码"
            } else if lower.contains("ssl") || lower.contains("tls") || lower.contains("certificate") {
                message = usingProxy
                    ? "通过 SOCKS5 代理建立 Gmail TLS 连接失败：\(raw)"
                    : "Gmail TLS 连接失败：\(raw)"
            } else if lower.contains("proxy") || lower.contains("connect") || lower.contains("timed out") {
                message = usingProxy
                    ? "无法通过 SOCKS5 代理连接 Gmail：\(raw)"
                    : "无法直接连接 Gmail：\(raw)"
            } else if lower.contains("message summaries") {
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

    private static func consumeTranslation(_ result: GRResult, usingProxy: Bool) throws -> Data {
        defer { gr_result_free(result) }
        if let error = result.error {
            let raw = String(cString: error)
            let prefix = usingProxy ? "无法通过 SOCKS5 代理访问 Google 翻译" : "无法访问 Google 翻译"
            throw GmailReaderError.network("\(prefix)：\(raw)")
        }
        guard result.length > 0, let data = result.data else {
            throw GmailReaderError.network("Google 翻译未返回内容")
        }
        return Data(bytes: data, count: result.length)
    }

    static func parseTranslation(_ data: Data) throws -> String {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [Any],
              let segments = root.first as? [Any] else {
            throw GmailReaderError.protocolError("Google 翻译返回了无效数据")
        }
        let translated = segments.compactMap { item -> String? in
            guard let values = item as? [Any], let value = values.first as? String else { return nil }
            return value
        }.joined()
        guard !translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GmailReaderError.protocolError("Google 翻译未返回译文")
        }
        return translated
    }

    private static func formEncode(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    static func decodePage(_ data: Data, page: Int, pageSize: Int) throws -> PagePayload {
        guard data.count >= 12, data.prefix(4) == Data("GRP1".utf8) else {
            throw GmailReaderError.protocolError("Gmail 邮件列表响应无效")
        }
        var offset = 4
        let countValue = readUInt64(data, offset: &offset)
        guard countValue <= UInt64(Int.max), countValue <= 10_000_000 else {
            throw GmailReaderError.protocolError("Gmail 邮件数量超出支持范围")
        }
        let count = Int(countValue)
        guard count <= (data.count - offset) / 8 else {
            throw GmailReaderError.protocolError("Gmail 邮件 UID 列表不完整")
        }
        var allUIDs: [UInt64] = []
        allUIDs.reserveCapacity(count)
        for _ in 0..<count { allUIDs.append(readUInt64(data, offset: &offset)) }

        let end = max(0, count - max(0, page - 1) * pageSize)
        let start = max(0, end - pageSize)
        let selected = start < end ? Array(allUIDs[start..<end].reversed()) : []
        let rawFetch = data.subdata(in: offset..<data.count)
        let summaries = selected.isEmpty
            ? [:]
            : try parseSummaryResponse(rawFetch, expectedUIDs: Set(selected))
        return PagePayload(allUIDs: allUIDs, summaries: summaries)
    }

    private static func readUInt64(_ data: Data, offset: inout Int) -> UInt64 {
        var value: UInt64 = 0
        for _ in 0..<8 {
            value = (value << 8) | UInt64(data[offset])
            offset += 1
        }
        return value
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
