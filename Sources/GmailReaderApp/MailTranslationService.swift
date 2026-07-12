import Foundation

/// Gmail 风格的应用内邮件翻译：批量翻译纯文本节点，再放回原始 HTML。
actor MailTranslationService {
    struct Result: Sendable {
        let content: String
        let isHTML: Bool
    }

    private struct CachedToken: Sendable {
        let value: String
        let expiresAt: Date
    }

    private var token: CachedToken?
    private var cache: [String: Result] = [:]
    private var cacheOrder: [String] = []

    func translateToChinese(plainBody: String, htmlBody: String, cacheKey: String,
                            proxy: ProxySettings) async throws -> Result {
        if let cached = cache[cacheKey] { return cached }

        let result: Result
        if !htmlBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, htmlBody.count <= 300_000 {
            let document = HTMLTranslationDocument(html: htmlBody)
            guard !document.units.isEmpty else {
                throw GmailReaderError.configuration("这封邮件没有可翻译的文字正文")
            }
            var translatedByID: [Int: String] = [:]
            for batch in document.batches() {
                try Task.checkCancellation()
                let values = try await translate(batch.map(\.source), textType: "html", proxy: proxy)
                for (unit, value) in zip(batch, values) {
                    translatedByID[unit.id] = HTMLTranslationDocument.sanitizeTranslatedText(value)
                }
            }
            result = Result(content: document.render(translations: translatedByID), isHTML: true)
        } else {
            let source = plainBody.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !source.isEmpty else { throw GmailReaderError.configuration("这封邮件没有可翻译的文字正文") }
            guard source.count <= 200_000 else { throw GmailReaderError.configuration("邮件正文过长，无法翻译") }
            let chunks = textChunks(source, maximumCharacters: 4_000)
            var translated: [String] = []
            for batch in textBatches(chunks, maximumItems: 50, maximumCharacters: 12_000) {
                try Task.checkCancellation()
                translated.append(contentsOf: try await translate(batch, textType: "plain", proxy: proxy))
            }
            result = Result(content: translated.joined(), isHTML: false)
        }

        cache[cacheKey] = result
        cacheOrder.removeAll { $0 == cacheKey }
        cacheOrder.append(cacheKey)
        while cacheOrder.count > 30 {
            cache.removeValue(forKey: cacheOrder.removeFirst())
        }
        return result
    }

    private func textBatches(_ values: [String], maximumItems: Int,
                             maximumCharacters: Int) -> [[String]] {
        var result: [[String]] = []
        var current: [String] = []
        var characterCount = 0
        for value in values {
            if !current.isEmpty,
               (current.count >= maximumItems || characterCount + value.count > maximumCharacters) {
                result.append(current)
                current = []
                characterCount = 0
            }
            current.append(value)
            characterCount += value.count
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private func translate(_ texts: [String], textType: String,
                           proxy: ProxySettings) async throws -> [String] {
        guard !texts.isEmpty else { return [] }
        let activeToken = try await translationToken(proxy: proxy)
        do {
            return try await CurlTransport.translateToSimplifiedChinese(
                texts, bearerToken: activeToken, textType: textType, proxy: proxy
            )
        } catch let error as GmailReaderError where error.isAuthorizationFailure {
            token = nil
            let refreshed = try await translationToken(proxy: proxy)
            return try await CurlTransport.translateToSimplifiedChinese(
                texts, bearerToken: refreshed, textType: textType, proxy: proxy
            )
        }
    }

    private func translationToken(proxy: ProxySettings) async throws -> String {
        if let token, token.expiresAt > Date().addingTimeInterval(30) { return token.value }
        let value = try await CurlTransport.fetchMailTranslationToken(proxy: proxy)
        token = CachedToken(value: value, expiresAt: Date().addingTimeInterval(8 * 60))
        return value
    }

    private func textChunks(_ value: String, maximumCharacters: Int) -> [String] {
        guard value.count > maximumCharacters else { return [value] }
        var result: [String] = []
        var start = value.startIndex
        while start < value.endIndex {
            var end = value.index(start, offsetBy: maximumCharacters, limitedBy: value.endIndex) ?? value.endIndex
            if end < value.endIndex {
                let candidate = start..<end
                if let boundary = value[candidate].lastIndex(where: { $0 == "\n" || $0 == " " || $0 == "\t" }),
                   value.distance(from: start, to: boundary) >= maximumCharacters / 2 {
                    end = value.index(after: boundary)
                }
            }
            result.append(String(value[start..<end]))
            start = end
        }
        return result
    }
}

private extension GmailReaderError {
    var isAuthorizationFailure: Bool {
        guard case let .network(message) = self else { return false }
        return message.contains("HTTP 401") || message.contains("HTTP 403")
    }
}
