import Foundation

/// 把 HTML 拆成“原样保留的标记”和“允许翻译的可见文字”。
///
/// 这里不能使用“翻译整份 HTML”的方式：Google 翻译在收到完整文档时，
/// 偶尔会把 head/title/meta 等标签也翻译掉，最终令 WebKit 把标签当成正文显示。
struct HTMLTranslationDocument: Sendable {
    struct Unit: Sendable, Equatable {
        let id: Int
        let source: String
        fileprivate let protectedSource: String
        fileprivate let protectedValues: [String]
    }

    private enum Piece: Sendable {
        case literal(String)
        case unit(Int)
    }

    private struct Token: Sendable {
        let original: String
        let pieces: [Piece]?
    }

    let units: [Unit]
    private let tokens: [Token]

    init(html: String) {
        let rawTokens = Self.tokenize(html)
        var nextID = 0
        var builtUnits: [Unit] = []
        var builtTokens: [Token] = []
        builtTokens.reserveCapacity(rawTokens.count)

        for rawToken in rawTokens {
            guard rawToken.isText, !rawToken.isSuppressed else {
                builtTokens.append(Token(original: rawToken.value, pieces: nil))
                continue
            }

            var pieces: [Piece] = []
            for chunk in Self.chunks(rawToken.value, maximumCharacters: 1_600) {
                let bounds = Self.translationBounds(in: chunk)
                guard let bounds, Self.shouldTranslate(String(chunk[bounds])) else {
                    pieces.append(.literal(chunk))
                    continue
                }

                let prefix = String(chunk[..<bounds.lowerBound])
                let source = String(chunk[bounds])
                let suffix = String(chunk[bounds.upperBound...])
                if !prefix.isEmpty { pieces.append(.literal(prefix)) }

                let protected = Self.protectHTMLSyntax(in: source)
                let unit = Unit(
                    id: nextID,
                    source: source,
                    protectedSource: protected.text,
                    protectedValues: protected.values
                )
                builtUnits.append(unit)
                pieces.append(.unit(nextID))
                nextID += 1

                if !suffix.isEmpty { pieces.append(.literal(suffix)) }
            }

            let containsUnit = pieces.contains {
                if case .unit = $0 { return true }
                return false
            }
            builtTokens.append(Token(original: rawToken.value, pieces: containsUnit ? pieces : nil))
        }

        units = builtUnits
        tokens = builtTokens
    }

    /// 每个请求只包含由本类生成的 div/span 片段，不包含邮件本身的任何标签。
    /// 因此 Google 只能改动文字，无法再破坏邮件 DOM、CSS、链接或图片。
    func batches(maximumCharacters: Int = 3_500) -> [[Unit]] {
        guard !units.isEmpty else { return [] }
        var result: [[Unit]] = []
        var current: [Unit] = []
        var currentLength = 0

        for unit in units {
            let length = Self.wrapper(for: unit).count
            if !current.isEmpty, currentLength + length > maximumCharacters {
                result.append(current)
                current = []
                currentLength = 0
            }
            current.append(unit)
            currentLength += length
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    static func requestHTML(for units: [Unit]) -> String {
        units.map(Self.wrapper).joined()
    }

    /// 从 Google 返回的片段提取各文本节点。只有所有 ID 和保护标记都完整时才接受结果。
    static func parseResponse(_ response: String, expected units: [Unit]) -> [Int: String]? {
        guard !units.isEmpty else { return [:] }
        guard let unitRegex = try? NSRegularExpression(
            pattern: #"<div\s+data-gr-unit\s*=\s*["']?(\d+)["']?[^>]*>(.*?)</div\s*>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ), let markerRegex = try? NSRegularExpression(
            pattern: #"<span\s+data-gr-marker\s*=\s*["']?(\d+)["']?[^>]*>\s*</span\s*>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return nil }

        let expectedByID = Dictionary(uniqueKeysWithValues: units.map { ($0.id, $0) })
        let responseRange = NSRange(response.startIndex..<response.endIndex, in: response)
        let matches = unitRegex.matches(in: response, range: responseRange)
        var result: [Int: String] = [:]

        for match in matches {
            guard let idRange = Range(match.range(at: 1), in: response),
                  let bodyRange = Range(match.range(at: 2), in: response),
                  let id = Int(response[idRange]),
                  let unit = expectedByID[id], result[id] == nil else { return nil }

            var body = String(response[bodyRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            let markerMatches = markerRegex.matches(
                in: body,
                range: NSRange(body.startIndex..<body.endIndex, in: body)
            )
            guard markerMatches.count == unit.protectedValues.count else { return nil }

            var bodyWithoutMarkers = body
            for markerMatch in markerMatches.reversed() {
                guard let wholeRange = Range(markerMatch.range(at: 0), in: bodyWithoutMarkers) else { return nil }
                bodyWithoutMarkers.removeSubrange(wholeRange)
            }
            // 输入中除保护 span 外没有标签；响应若多出标签，说明接口改写了片段。
            guard !bodyWithoutMarkers.contains("<"), !bodyWithoutMarkers.contains(">") else { return nil }

            // 从后往前替换，避免较早的替换令 NSRange 失效。
            var seenMarkers = Set<Int>()
            for markerMatch in markerMatches.reversed() {
                guard let markerIDRange = Range(markerMatch.range(at: 1), in: body),
                      let markerID = Int(body[markerIDRange]),
                      unit.protectedValues.indices.contains(markerID),
                      seenMarkers.insert(markerID).inserted,
                      let wholeRange = Range(markerMatch.range(at: 0), in: body) else { return nil }
                body.replaceSubrange(wholeRange, with: unit.protectedValues[markerID])
            }
            guard seenMarkers.count == unit.protectedValues.count else { return nil }
            result[id] = body
        }

        return result.count == units.count ? result : nil
    }

    func render(translations: [Int: String]) -> String {
        var output = ""
        output.reserveCapacity(tokens.reduce(0) { $0 + $1.original.utf8.count })
        for token in tokens {
            guard let pieces = token.pieces else {
                output += token.original
                continue
            }
            for piece in pieces {
                switch piece {
                case let .literal(value):
                    output += value
                case let .unit(id):
                    guard let value = translations[id] else { return tokens.map(\.original).joined() }
                    output += value
                }
            }
        }
        return output
    }

    private static func wrapper(for unit: Unit) -> String {
        #"<div data-gr-unit="\#(unit.id)">\#(unit.protectedSource)</div>"#
    }

    private static func protectHTMLSyntax(in value: String) -> (text: String, values: [String]) {
        var output = ""
        var values: [String] = []
        var index = value.startIndex

        func marker(_ original: String) -> String {
            let id = values.count
            values.append(original)
            return #"<span data-gr-marker="\#(id)"></span>"#
        }

        while index < value.endIndex {
            let character = value[index]
            if character == "&" {
                var end = value.index(after: index)
                var candidateEnd: String.Index?
                var inspected = 0
                while end < value.endIndex, inspected < 32 {
                    if value[end] == ";" {
                        candidateEnd = value.index(after: end)
                        break
                    }
                    if value[end].isWhitespace || value[end] == "&" || value[end] == "<" || value[end] == ">" { break }
                    end = value.index(after: end)
                    inspected += 1
                }
                if let candidateEnd {
                    output += marker(String(value[index..<candidateEnd]))
                    index = candidateEnd
                } else {
                    output += marker("&")
                    index = value.index(after: index)
                }
            } else if character == "<" || character == ">" {
                output += marker(String(character))
                index = value.index(after: index)
            } else {
                output.append(character)
                index = value.index(after: index)
            }
        }
        return (output, values)
    }

    private static func translationBounds(in value: String) -> Range<String.Index>? {
        guard let first = value.firstIndex(where: { !$0.isWhitespace }),
              let last = value.lastIndex(where: { !$0.isWhitespace }) else { return nil }
        return first..<value.index(after: last)
    }

    private static func shouldTranslate(_ value: String) -> Bool {
        var searchable = value
        if let regex = try? NSRegularExpression(
            pattern: #"&(?:#[xX][0-9a-fA-F]+|#[0-9]+|[A-Za-z][A-Za-z0-9]+);"#
        ) {
            searchable = regex.stringByReplacingMatches(
                in: searchable,
                range: NSRange(searchable.startIndex..<searchable.endIndex, in: searchable),
                withTemplate: ""
            )
        }
        let trimmed = searchable.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("mailto:") { return false }
        if !trimmed.contains(where: { $0.isWhitespace }), trimmed.contains("@"), trimmed.contains(".") { return false }
        return trimmed.unicodeScalars.contains { CharacterSet.letters.contains($0) }
    }

    private static func chunks(_ value: String, maximumCharacters: Int) -> [String] {
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

    private struct RawToken {
        let value: String
        let isText: Bool
        let isSuppressed: Bool
    }

    private static let suppressedElements: Set<String> = [
        "head", "style", "script", "noscript", "template", "iframe", "object", "svg", "canvas", "xmp", "noembed"
    ]

    private static func tokenize(_ html: String) -> [RawToken] {
        var tokens: [RawToken] = []
        var index = html.startIndex
        var textStart = index
        var suppressedElement: String?

        func appendText(until end: String.Index) {
            guard textStart < end else { return }
            tokens.append(RawToken(
                value: String(html[textStart..<end]),
                isText: true,
                isSuppressed: suppressedElement != nil
            ))
        }

        while index < html.endIndex {
            guard html[index] == "<" else {
                index = html.index(after: index)
                continue
            }

            appendText(until: index)
            let markupEnd = endOfMarkup(in: html, from: index)
            guard markupEnd > index else {
                index = html.index(after: index)
                textStart = index
                continue
            }
            let markup = String(html[index..<markupEnd])
            tokens.append(RawToken(value: markup, isText: false, isSuppressed: suppressedElement != nil))

            if let tag = tagInfo(markup) {
                if let current = suppressedElement {
                    if tag.isClosing, tag.name == current { suppressedElement = nil }
                } else if !tag.isClosing, !tag.isSelfClosing, suppressedElements.contains(tag.name) {
                    suppressedElement = tag.name
                }
            }
            index = markupEnd
            textStart = index
        }
        appendText(until: html.endIndex)
        return tokens
    }

    private static func endOfMarkup(in html: String, from start: String.Index) -> String.Index {
        let remainder = html[start...]
        if remainder.hasPrefix("<!--") {
            if let end = html.range(of: "-->", range: start..<html.endIndex)?.upperBound { return end }
            return html.endIndex
        }
        if remainder.hasPrefix("<![CDATA[") {
            if let end = html.range(of: "]]>", range: start..<html.endIndex)?.upperBound { return end }
            return html.endIndex
        }

        var index = html.index(after: start)
        var quote: Character?
        while index < html.endIndex {
            let character = html[index]
            if let activeQuote = quote {
                if character == activeQuote { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == ">" {
                return html.index(after: index)
            }
            index = html.index(after: index)
        }
        return html.endIndex
    }

    private static func tagInfo(_ markup: String) -> (name: String, isClosing: Bool, isSelfClosing: Bool)? {
        guard let regex = try? NSRegularExpression(
            pattern: #"^<\s*(/?)\s*([A-Za-z][A-Za-z0-9:_-]*)"#,
            options: [.caseInsensitive]
        ) else { return nil }
        let range = NSRange(markup.startIndex..<markup.endIndex, in: markup)
        guard let match = regex.firstMatch(in: markup, range: range),
              let nameRange = Range(match.range(at: 2), in: markup),
              let closingRange = Range(match.range(at: 1), in: markup) else { return nil }
        return (
            String(markup[nameRange]).lowercased(),
            !markup[closingRange].isEmpty,
            markup.dropLast().trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("/")
        )
    }
}
