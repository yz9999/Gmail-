import CoreFoundation
import Foundation

enum MIMEParser {
    struct Headers {
        private let values: [String: String]

        init(data: Data) {
            let text = decodeBytes(data, charset: nil)
            var unfolded: [String] = []
            for line in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
                if (line.hasPrefix(" ") || line.hasPrefix("\t")), !unfolded.isEmpty {
                    unfolded[unfolded.count - 1] += " " + line.trimmingCharacters(in: .whitespaces)
                } else {
                    unfolded.append(line)
                }
            }
            var result: [String: String] = [:]
            for line in unfolded {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let key = line[..<colon].lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if result[key] == nil { result[key] = value }
            }
            values = result
        }

        subscript(_ name: String) -> String { values[name.lowercased()] ?? "" }
        func decoded(_ name: String) -> String { decodeHeader(self[name]) }
    }

    static func summary(uid: UInt64, headerData: Data, flags: Set<String>) -> MailSummary {
        let headers = Headers(data: headerData)
        let dateText = headers.decoded("date")
        return MailSummary(
            uid: uid,
            messageID: headers.decoded("message-id"),
            subject: headers.decoded("subject").nonEmpty ?? "（无主题）",
            sender: headers.decoded("from"),
            recipients: headers.decoded("to"),
            dateText: dateText,
            date: parseDate(dateText),
            isRead: flags.contains("\\Seen"),
            isStarred: flags.contains("\\Flagged")
        )
    }

    static func message(uid: UInt64, raw: Data, flags: Set<String>) -> MailMessage {
        let entity = parseEntity(raw)
        let headers = Headers(data: entity.header)
        var plain = ""
        var html = ""
        collectBodies(raw, plain: &plain, html: &html)
        if plain.isEmpty, !html.isEmpty {
            plain = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                .replacingOccurrences(of: "&nbsp;", with: " ")
        }
        return MailMessage(
            uid: uid,
            messageID: headers.decoded("message-id"),
            subject: headers.decoded("subject").nonEmpty ?? "（无主题）",
            sender: headers.decoded("from"),
            recipients: headers.decoded("to"),
            dateText: headers.decoded("date"),
            plainBody: plain.trimmingCharacters(in: .whitespacesAndNewlines),
            htmlBody: html,
            isRead: flags.contains("\\Seen"),
            isStarred: flags.contains("\\Flagged")
        )
    }

    static func decodeHeader(_ value: String) -> String {
        guard value.contains("=?") else { return value }
        let pattern = #"=\?([^?]+)\?([bBqQ])\?([^?]*)\?="#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return value }
        let range = NSRange(value.startIndex..., in: value)
        let matches = regex.matches(in: value, range: range)
        guard !matches.isEmpty else { return value }
        var result = ""
        var cursor = value.startIndex
        for match in matches {
            guard let full = Range(match.range(at: 0), in: value),
                  let charsetRange = Range(match.range(at: 1), in: value),
                  let encodingRange = Range(match.range(at: 2), in: value),
                  let payloadRange = Range(match.range(at: 3), in: value) else { continue }
            let between = value[cursor..<full.lowerBound]
            if !between.allSatisfy({ $0.isWhitespace }) { result += between }
            let charset = String(value[charsetRange])
            let encoding = value[encodingRange].lowercased()
            let payload = String(value[payloadRange])
            let data: Data?
            if encoding == "b" {
                data = Data(base64Encoded: payload)
            } else {
                data = quotedPrintableData(payload.replacingOccurrences(of: "_", with: " "))
            }
            result += data.map { decodeBytes($0, charset: charset) } ?? String(value[full])
            cursor = full.upperBound
        }
        result += value[cursor...]
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct Entity { let header: Data; let body: Data }

    private static func parseEntity(_ data: Data) -> Entity {
        if let range = data.range(of: Data("\r\n\r\n".utf8)) {
            return Entity(header: data[..<range.lowerBound], body: data[range.upperBound...])
        }
        if let range = data.range(of: Data("\n\n".utf8)) {
            return Entity(header: data[..<range.lowerBound], body: data[range.upperBound...])
        }
        return Entity(header: data, body: Data())
    }

    private static func collectBodies(_ raw: Data, plain: inout String, html: inout String) {
        let entity = parseEntity(raw)
        let headers = Headers(data: entity.header)
        let contentType = headers["content-type"].isEmpty ? "text/plain" : headers["content-type"]
        let mediaType = contentType.components(separatedBy: ";")[0].trimmingCharacters(in: .whitespaces).lowercased()
        if mediaType.hasPrefix("multipart/"), let boundary = parameter("boundary", in: contentType) {
            for part in multipartParts(entity.body, boundary: boundary) {
                collectBodies(part, plain: &plain, html: &html)
            }
            return
        }
        if mediaType == "message/rfc822" {
            collectBodies(entity.body, plain: &plain, html: &html)
            return
        }
        guard mediaType == "text/plain" || mediaType == "text/html" else { return }
        if headers["content-disposition"].lowercased().hasPrefix("attachment") { return }
        let decoded = decodeTransfer(entity.body, encoding: headers["content-transfer-encoding"])
        let text = decodeBytes(decoded, charset: parameter("charset", in: contentType))
        if mediaType == "text/html", html.isEmpty { html = text }
        if mediaType == "text/plain", plain.isEmpty { plain = text }
    }

    private static func multipartParts(_ body: Data, boundary: String) -> [Data] {
        let marker = Data("--\(boundary)".utf8)
        var parts: [Data] = []
        var cursor = body.startIndex
        guard let first = body.range(of: marker, in: cursor..<body.endIndex) else { return [] }
        cursor = first.upperBound
        while cursor < body.endIndex {
            if body[cursor...].starts(with: [45, 45]) { break }
            cursor = trimLeadingNewline(in: body, from: cursor)
            guard let next = body.range(of: marker, in: cursor..<body.endIndex) else { break }
            var end = next.lowerBound
            if end >= 2, body[body.index(end, offsetBy: -2)..<end] == Data([13, 10]) { end -= 2 }
            else if end >= 1, body[body.index(before: end)] == 10 { end -= 1 }
            parts.append(body.subdata(in: cursor..<end))
            cursor = next.upperBound
        }
        return parts
    }

    private static func trimLeadingNewline(in data: Data, from index: Data.Index) -> Data.Index {
        if data.distance(from: index, to: data.endIndex) >= 2,
           data[index] == 13, data[data.index(after: index)] == 10 {
            return data.index(index, offsetBy: 2)
        }
        if index < data.endIndex, data[index] == 10 { return data.index(after: index) }
        return index
    }

    private static func parameter(_ name: String, in header: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let pattern = "(?:^|;)\\s*\(escaped)\\s*=\\s*(?:\"([^\"]*)\"|([^;\\s]*))"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: header, range: NSRange(header.startIndex..., in: header)) else { return nil }
        for index in 1...2 where match.range(at: index).location != NSNotFound {
            if let range = Range(match.range(at: index), in: header) { return String(header[range]) }
        }
        return nil
    }

    private static func decodeTransfer(_ data: Data, encoding: String) -> Data {
        switch encoding.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "base64":
            return Data(base64Encoded: data.filter { !$0.isASCIIWhitespace }, options: .ignoreUnknownCharacters) ?? data
        case "quoted-printable":
            return quotedPrintableData(String(decoding: data, as: UTF8.self)) ?? data
        default:
            return data
        }
    }

    private static func quotedPrintableData(_ value: String) -> Data? {
        let bytes = Array(value.utf8)
        var result: [UInt8] = []
        var index = 0
        while index < bytes.count {
            if bytes[index] == 61 {
                if index + 1 < bytes.count, bytes[index + 1] == 10 { index += 2; continue }
                if index + 2 < bytes.count, bytes[index + 1] == 13, bytes[index + 2] == 10 { index += 3; continue }
                if index + 2 < bytes.count, let high = hex(bytes[index + 1]), let low = hex(bytes[index + 2]) {
                    result.append(high << 4 | low); index += 3; continue
                }
            }
            result.append(bytes[index]); index += 1
        }
        return Data(result)
    }

    private static func hex(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: return byte - 48
        case 65...70: return byte - 55
        case 97...102: return byte - 87
        default: return nil
        }
    }

    private static func decodeBytes(_ data: Data, charset: String?) -> String {
        let normalized = charset?.trimmingCharacters(in: CharacterSet(charactersIn: " \"'")).lowercased()
        var encodings: [String.Encoding] = []
        if let normalized, !normalized.isEmpty {
            let cfEncoding = CFStringConvertIANACharSetNameToEncoding(normalized as CFString)
            if cfEncoding != kCFStringEncodingInvalidId {
                encodings.append(String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding)))
            }
        }
        encodings += [.utf8, .isoLatin1, .windowsCP1252]
        for encoding in encodings {
            if let value = String(data: data, encoding: encoding) { return value }
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func parseDate(_ value: String) -> Date? {
        let formats = ["EEE, d MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss Z"]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            if let date = formatter.date(from: value.components(separatedBy: " (").first ?? value) { return date }
        }
        return nil
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

private extension UInt8 {
    var isASCIIWhitespace: Bool { self == 9 || self == 10 || self == 13 || self == 32 }
}
