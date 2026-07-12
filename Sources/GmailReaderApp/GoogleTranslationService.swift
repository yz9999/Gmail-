import Foundation

actor GoogleTranslationService {
    struct Result: Sendable {
        let content: String
        let isHTML: Bool
    }

    private var cache: [String: Result] = [:]
    private var cacheOrder: [String] = []

    func translateToChinese(plainBody: String, htmlBody: String, cacheKey: String,
                            proxy: ProxySettings) async throws -> Result {
        if let cached = cache[cacheKey] { return cached }

        let html = htmlBody.trimmingCharacters(in: .whitespacesAndNewlines)
        let result: Result
        if !html.isEmpty, html.count <= 300_000 {
            let document = HTMLTranslationDocument(html: htmlBody)
            guard !document.units.isEmpty else {
                throw GmailReaderError.configuration("这封邮件没有可翻译的文字正文")
            }
            var translations: [Int: String] = [:]
            for batch in document.batches() {
                try Task.checkCancellation()
                let values = try await translate(batch, proxy: proxy)
                translations.merge(values) { _, new in new }
            }
            // render 逐字复用原邮件的所有标签、属性、CSS、URL 和图片，只替换文本节点。
            result = Result(content: document.render(translations: translations), isHTML: true)
        } else {
            let source = plainBody.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !source.isEmpty else { throw GmailReaderError.configuration("这封邮件没有可翻译的文字正文") }
            guard source.count <= 200_000 else { throw GmailReaderError.configuration("邮件正文过长，无法一次翻译") }
            var results: [String] = []
            for chunk in chunks(source, maximumCharacters: 3_500) {
                try Task.checkCancellation()
                results.append(try await CurlTransport.translateToChinese(chunk, proxy: proxy))
            }
            result = Result(content: results.joined(separator: "\n"), isHTML: false)
        }
        cache[cacheKey] = result
        cacheOrder.removeAll { $0 == cacheKey }
        cacheOrder.append(cacheKey)
        while cacheOrder.count > 30 {
            cache.removeValue(forKey: cacheOrder.removeFirst())
        }
        return result
    }

    private func translate(_ batch: [HTMLTranslationDocument.Unit],
                           proxy: ProxySettings) async throws -> [Int: String] {
        let request = HTMLTranslationDocument.requestHTML(for: batch)
        let response = try await CurlTransport.translateToChinese(request, proxy: proxy)
        if let parsed = HTMLTranslationDocument.parseResponse(response, expected: batch) { return parsed }

        // 极少数情况下 Google 会合并相邻片段；改为逐节点重试，仍然绝不发送原始 HTML。
        var result: [Int: String] = [:]
        for unit in batch {
            try Task.checkCancellation()
            let singleRequest = HTMLTranslationDocument.requestHTML(for: [unit])
            let singleResponse = try await CurlTransport.translateToChinese(singleRequest, proxy: proxy)
            guard let parsed = HTMLTranslationDocument.parseResponse(singleResponse, expected: [unit]),
                  let value = parsed[unit.id] else {
                throw GmailReaderError.protocolError("Google 翻译未能安全保留邮件排版，请稍后重试")
            }
            result[unit.id] = value
        }
        return result
    }

    private func chunks(_ value: String, maximumCharacters: Int) -> [String] {
        var result: [String] = []
        var start = value.startIndex
        while start < value.endIndex {
            var end = value.index(start, offsetBy: maximumCharacters, limitedBy: value.endIndex) ?? value.endIndex
            if end < value.endIndex {
                let range = start..<end
                if let newline = value[range].lastIndex(of: "\n"),
                   value.distance(from: start, to: newline) >= maximumCharacters / 2 {
                    end = value.index(after: newline)
                }
            }
            result.append(String(value[start..<end]))
            start = end
        }
        return result
    }
}
