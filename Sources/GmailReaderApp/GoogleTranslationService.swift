import Foundation

actor GoogleTranslationService {
    private var cache: [String: String] = [:]
    private var cacheOrder: [String] = []

    func translateToChinese(_ body: String, cacheKey: String, proxy: ProxySettings) async throws -> String {
        let source = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { throw GmailReaderError.configuration("这封邮件没有可翻译的文字正文") }
        guard source.count <= 200_000 else { throw GmailReaderError.configuration("邮件正文过长，无法一次翻译") }
        if let cached = cache[cacheKey] { return cached }

        var results: [String] = []
        for chunk in chunks(source, maximumCharacters: 3_500) {
            try Task.checkCancellation()
            results.append(try await CurlTransport.translateToChinese(chunk, proxy: proxy))
        }
        let translated = results.joined(separator: "\n")
        cache[cacheKey] = translated
        cacheOrder.removeAll { $0 == cacheKey }
        cacheOrder.append(cacheKey)
        while cacheOrder.count > 30 {
            cache.removeValue(forKey: cacheOrder.removeFirst())
        }
        return translated
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
