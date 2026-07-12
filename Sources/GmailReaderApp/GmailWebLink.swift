import Foundation

/// Gmail 的邮件翻译功能没有 Gmail API 或 IMAP 接口，只存在于已登录的 Gmail 网页中。
/// 这里用 RFC 822 Message-ID 构造精确搜索链接，让默认浏览器在 Gmail 中定位当前邮件。
enum GmailWebLink {
    static func messageURL(account: String, messageID: String, subject: String) -> URL? {
        let cleanAccount = singleLine(account).lowercased()
        let cleanMessageID = singleLine(messageID)
        let search: String
        if !cleanMessageID.isEmpty {
            search = "rfc822msgid:\(cleanMessageID)"
        } else {
            let cleanSubject = singleLine(subject)
            guard !cleanSubject.isEmpty else { return nil }
            search = "subject:\"\(cleanSubject.replacingOccurrences(of: "\"", with: "\\\""))\""
        }

        let fragmentAllowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        guard let encodedSearch = search.addingPercentEncoding(withAllowedCharacters: fragmentAllowed) else { return nil }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "mail.google.com"
        components.path = "/mail/u/"
        if !cleanAccount.isEmpty {
            components.queryItems = [URLQueryItem(name: "authuser", value: cleanAccount)]
        }
        components.percentEncodedFragment = "search/\(encodedSearch)"
        return components.url
    }

    private static func singleLine(_ value: String) -> String {
        value.components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
