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
            for chunk in Self.requestSizedChunks(rawToken.value) {
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

    /// 每个请求只包含由本类生成的 gr-unit/gr-entity 片段，不包含邮件本身的任何标签。
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
        let result = parseAvailableResponse(response, expected: units)
        return result.count == units.count ? result : nil
    }

    /// Google 偶尔只改写一个边界标记。有效节点仍可使用，失败节点再走纯文本回退，
    /// 不能因为一段隐藏预览文字失败就放弃整封营销邮件。
    static func parseAvailableResponse(_ response: String, expected units: [Unit]) -> [Int: String] {
        var result: [Int: String] = [:]
        for unit in units {
            if let body = parsedBody(in: response, for: unit) { result[unit.id] = body }
        }
        return result
    }

    /// HTML 包装片段无法识别时使用。请求中以长标记代替实体，响应必须完整带回标记；
    /// 普通译文会进行 HTML 转义，原始实体则逐字放回，因此回退也不会破坏 DOM。
    static func plainFallbackRequest(for unit: Unit) -> String {
        var result = unit.protectedSource
        for id in unit.protectedValues.indices {
            result = result.replacingOccurrences(of: markerTag(id), with: plainMarker(unitID: unit.id, markerID: id))
        }
        return result
    }

    static func plainFallbackRequest(for units: [Unit]) -> String {
        units.map { unit in
            "\(plainUnitBoundary(unit.id, isStart: true))\(plainFallbackRequest(for: unit))\(plainUnitBoundary(unit.id, isStart: false))"
        }.joined(separator: "\n")
    }

    static func parsePlainFallbackResponse(_ response: String, expected units: [Unit]) -> [Int: String] {
        var result: [Int: String] = [:]
        let fullRange = NSRange(response.startIndex..<response.endIndex, in: response)
        for unit in units {
            let start = NSRegularExpression.escapedPattern(for: plainUnitBoundary(unit.id, isStart: true))
            let end = NSRegularExpression.escapedPattern(for: plainUnitBoundary(unit.id, isStart: false))
            guard let regex = try? NSRegularExpression(
                pattern: start + "(.*?)" + end,
                options: [.dotMatchesLineSeparators]
            ) else { continue }
            let matches = regex.matches(in: response, range: fullRange)
            guard matches.count == 1,
                  let bodyRange = Range(matches[0].range(at: 1), in: response),
                  let value = parsePlainFallbackResponse(String(response[bodyRange]), for: unit) else { continue }
            result[unit.id] = value
        }
        return result
    }

    static func parsePlainFallbackResponse(_ response: String, for unit: Unit) -> String? {
        let value = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        guard !unit.protectedValues.isEmpty else { return escapeHTMLText(value) }

        let markerPrefix = "__GMAIL_READER_HTML_\(unit.id)_"
        let pattern = NSRegularExpression.escapedPattern(for: markerPrefix) + #"(\d+)__"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let matches = regex.matches(in: value, range: NSRange(value.startIndex..<value.endIndex, in: value))
        guard matches.count == unit.protectedValues.count else { return nil }

        var seen = Set<Int>()
        var cursor = value.startIndex
        var output = ""
        for match in matches {
            guard let wholeRange = Range(match.range(at: 0), in: value),
                  let idRange = Range(match.range(at: 1), in: value),
                  let id = Int(value[idRange]),
                  unit.protectedValues.indices.contains(id),
                  seen.insert(id).inserted else { return nil }
            output += escapeHTMLText(String(value[cursor..<wholeRange.lowerBound]))
            output += unit.protectedValues[id]
            cursor = wholeRange.upperBound
        }
        guard seen.count == unit.protectedValues.count else { return nil }
        output += escapeHTMLText(String(value[cursor...]))
        return output
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
        #"<gr-unit data-id="\#(unit.id)">\#(unit.protectedSource)</gr-unit>"#
    }

    private static func protectHTMLSyntax(in value: String) -> (text: String, values: [String]) {
        var output = ""
        var values: [String] = []
        var index = value.startIndex

        func marker(_ original: String) -> String {
            let id = values.count
            values.append(original)
            return markerTag(id)
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

    private static func parsedBody(in response: String, for unit: Unit) -> String? {
        let id = unit.id
        let exactID = #"(?:["']\#(id)["']|\#(id)(?=[\s>]))"#
        // 自定义标签已经过线上接口验证；\s* 同时兼容接口偶发输出的 <gr-unitdata-id=...>。
        let customPattern = #"<gr-unit\s*data-id\s*=\s*\#(exactID)[^>]*>(.*?)</gr-unit\s*>"#
        // 兼容 1.2.3 的返回格式，同时容忍 Google 偶尔删掉标签与属性间的空格。
        let legacyPattern = #"<div\s*data-gr-unit\s*=\s*\#(exactID)[^>]*>(.*?)</div\s*>"#
        guard let body = singleCapturedBody(in: response, patterns: [customPattern, legacyPattern]) else { return nil }

        let customMarkerPattern = #"<gr-entity\s*data-id\s*=\s*["']?(\d+)["']?[^>]*>\s*</gr-entity\s*>"#
        let customSelfClosingPattern = #"<gr-entity\s*data-id\s*=\s*["']?(\d+)["']?[^>]*/>"#
        let legacyMarkerPattern = #"<span\s*data-gr-marker\s*=\s*["']?(\d+)["']?[^>]*>\s*</span\s*>"#
        guard let markerMatches = matches(
            in: body,
            patterns: [customMarkerPattern, customSelfClosingPattern, legacyMarkerPattern]
        ), markerMatches.count == unit.protectedValues.count else { return nil }

        var bodyWithoutMarkers = body
        for markerMatch in markerMatches.reversed() {
            guard let wholeRange = Range(markerMatch.wholeRange, in: bodyWithoutMarkers) else { return nil }
            bodyWithoutMarkers.removeSubrange(wholeRange)
        }
        // 输入中除保护标记外没有标签；响应若多出标签，说明接口改写了片段。
        guard !bodyWithoutMarkers.contains("<"), !bodyWithoutMarkers.contains(">") else { return nil }

        var translated = body
        var seenMarkers = Set<Int>()
        for markerMatch in markerMatches.reversed() {
            guard let markerIDRange = Range(markerMatch.idRange, in: translated),
                  let markerID = Int(translated[markerIDRange]),
                  unit.protectedValues.indices.contains(markerID),
                  seenMarkers.insert(markerID).inserted,
                  let wholeRange = Range(markerMatch.wholeRange, in: translated) else { return nil }
            translated.replaceSubrange(wholeRange, with: unit.protectedValues[markerID])
        }
        guard seenMarkers.count == unit.protectedValues.count else { return nil }
        let cleaned = translated.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    private struct MarkerMatch {
        let wholeRange: NSRange
        let idRange: NSRange
    }

    private static func matches(in value: String, patterns: [String]) -> [MarkerMatch]? {
        let fullRange = NSRange(value.startIndex..<value.endIndex, in: value)
        var result: [MarkerMatch] = []
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(
                pattern: pattern,
                options: [.caseInsensitive, .dotMatchesLineSeparators]
            ) else { continue }
            let found = regex.matches(in: value, range: fullRange).compactMap { match -> MarkerMatch? in
                guard match.numberOfRanges > 1, match.range(at: 1).location != NSNotFound else { return nil }
                return MarkerMatch(wholeRange: match.range(at: 0), idRange: match.range(at: 1))
            }
            for match in found where !result.contains(where: { NSEqualRanges($0.wholeRange, match.wholeRange) }) {
                result.append(match)
            }
        }
        return result.sorted { $0.wholeRange.location < $1.wholeRange.location }
    }

    private static func singleCapturedBody(in value: String, patterns: [String]) -> String? {
        let fullRange = NSRange(value.startIndex..<value.endIndex, in: value)
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(
                pattern: pattern,
                options: [.caseInsensitive, .dotMatchesLineSeparators]
            ) else { continue }
            let found = regex.matches(in: value, range: fullRange)
            guard found.count <= 1 else { return nil }
            if let match = found.first,
               match.numberOfRanges > 1,
               let bodyRange = Range(match.range(at: 1), in: value) {
                return String(value[bodyRange])
            }
        }
        return nil
    }

    private static func markerTag(_ id: Int) -> String {
        #"<gr-entity data-id="\#(id)"></gr-entity>"#
    }

    private static func plainMarker(unitID: Int, markerID: Int) -> String {
        "__GMAIL_READER_HTML_\(unitID)_\(markerID)__"
    }

    private static func plainUnitBoundary(_ unitID: Int, isStart: Bool) -> String {
        "__GMAIL_READER_UNIT_\(unitID)_\(isStart ? "BEGIN" : "END")__"
    }

    private static func escapeHTMLText(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
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
                end = entitySafeBoundary(in: value, start: start, proposedEnd: end)
            }
            result.append(String(value[start..<end]))
            start = end
        }
        return result
    }

    private static func requestSizedChunks(_ value: String) -> [String] {
        var pending = Array(chunks(value, maximumCharacters: 1_600).reversed())
        var result: [String] = []

        while let candidate = pending.popLast() {
            guard let bounds = translationBounds(in: candidate),
                  shouldTranslate(String(candidate[bounds])) else {
                result.append(candidate)
                continue
            }
            let source = String(candidate[bounds])
            let estimatedRequestLength = protectHTMLSyntax(in: source).text.count + 80
            guard estimatedRequestLength > 3_400, candidate.count > 1 else {
                result.append(candidate)
                continue
            }

            var split = candidate.index(candidate.startIndex, offsetBy: candidate.count / 2)
            let leftCandidate = candidate.startIndex..<split
            if let whitespace = candidate[leftCandidate].lastIndex(where: { $0.isWhitespace }),
               candidate.distance(from: candidate.startIndex, to: whitespace) >= candidate.count / 4 {
                split = candidate.index(after: whitespace)
            }
            split = entitySafeBoundary(in: candidate, start: candidate.startIndex, proposedEnd: split)
            guard split > candidate.startIndex, split < candidate.endIndex else {
                result.append(candidate)
                continue
            }
            // 栈按左到右处理，最终拼接仍与原始文本逐字一致。
            pending.append(String(candidate[split...]))
            pending.append(String(candidate[..<split]))
        }
        return result
    }

    /// 不从 `&zwnj;`、`&#8204;` 等实体中间切开。否则半个实体里的 zwnj 会被误判成
    /// 可见英文文字，营销邮件的隐藏填充区就会产生大量无意义翻译请求。
    private static func entitySafeBoundary(in value: String, start: String.Index,
                                           proposedEnd: String.Index) -> String.Index {
        guard start < proposedEnd else { return proposedEnd }
        let prefix = value[start..<proposedEnd]
        guard let ampersand = prefix.lastIndex(of: "&") else { return proposedEnd }
        if let semicolon = prefix.lastIndex(of: ";"), semicolon > ampersand { return proposedEnd }
        if ampersand > start { return ampersand }
        if let semicolon = value[proposedEnd...].firstIndex(of: ";"),
           value.distance(from: proposedEnd, to: semicolon) <= 32 {
            return value.index(after: semicolon)
        }
        return proposedEnd
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
