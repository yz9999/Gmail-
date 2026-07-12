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
        var result = HTMLTranslationDocument.parseAvailableResponse(response, expected: batch)

        let missing = batch.filter { result[$0.id] == nil }
        guard !missing.isEmpty else { return result }

        // 将所有失败节点合并为一次纯文本回退请求，避免营销邮件产生几十次网络重试。
        // 回退会转义译文并恢复原始实体；仍无法识别的节点只保留该小段原文。
        do {
            try Task.checkCancellation()
            let fallbackRequest = HTMLTranslationDocument.plainFallbackRequest(for: missing)
            let fallbackResponse = try await CurlTransport.translateToChinese(fallbackRequest, proxy: proxy)
            let fallbackValues = HTMLTranslationDocument.parsePlainFallbackResponse(fallbackResponse, expected: missing)
            result.merge(fallbackValues) { _, new in new }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // 初始 HTML 批次已经成功，回退网络错误不应令整封邮件失败。
        }
        for unit in missing where result[unit.id] == nil {
            result[unit.id] = unit.source
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
