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
            // Google 翻译会保留 HTML 标签、表格、图片与链接属性，
            // 整体发送可避免分段破坏邮件 DOM 结构。
            let translated = try await CurlTransport.translateToChinese(html, proxy: proxy)
            result = Result(content: translated, isHTML: true)
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
