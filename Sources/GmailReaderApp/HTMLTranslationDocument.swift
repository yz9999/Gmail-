import Foundation

/// 只把 HTML 的可见文本节点交给翻译服务。邮件原有标签、属性、CSS、URL 和
/// 图片始终逐字复用，译文按纯文本消毒后写回，因此无法改变 DOM 或邮件排版。
struct HTMLTranslationDocument: Sendable {
    struct Unit: Sendable, Equatable {
        let id: Int
        let source: String
    }

    private enum Piece: Sendable {
        case literal(String)
        case unit(id: Int, original: String)
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
            for chunk in Self.chunks(rawToken.value, maximumCharacters: 4_000) {
                guard let bounds = Self.translationBounds(in: chunk),
                      Self.shouldTranslate(String(chunk[bounds])) else {
                    pieces.append(.literal(chunk))
                    continue
                }
                let prefix = String(chunk[..<bounds.lowerBound])
                let source = String(chunk[bounds])
                let suffix = String(chunk[bounds.upperBound...])
                if !prefix.isEmpty { pieces.append(.literal(prefix)) }
                builtUnits.append(Unit(id: nextID, source: source))
                pieces.append(.unit(id: nextID, original: source))
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

    func batches(maximumItems: Int = 50, maximumCharacters: Int = 12_000) -> [[Unit]] {
        guard !units.isEmpty else { return [] }
        var result: [[Unit]] = []
        var current: [Unit] = []
        var characterCount = 0
        for unit in units {
            if !current.isEmpty,
               (current.count >= maximumItems || characterCount + unit.source.count > maximumCharacters) {
                result.append(current)
                current = []
                characterCount = 0
            }
            current.append(unit)
            characterCount += unit.source.count
        }
        if !current.isEmpty { result.append(current) }
        return result
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
                case let .unit(id, original):
                    output += translations[id] ?? original
                }
            }
        }
        return output
    }

    /// 翻译返回值只能作为文本写回：保留合法 HTML 实体，转义所有裸露的 &、<、>。
    static func sanitizeTranslatedText(_ value: String) -> String {
        var output = ""
        var index = value.startIndex
        while index < value.endIndex {
            let character = value[index]
            if character == "&" {
                if let end = htmlEntityEnd(in: value, from: index) {
                    output += value[index..<end]
                    index = end
                } else {
                    output += "&amp;"
                    index = value.index(after: index)
                }
            } else if character == "<" || character == ">" {
                output += character == "<" ? "&lt;" : "&gt;"
                index = value.index(after: index)
            } else {
                output.append(character)
                index = value.index(after: index)
            }
        }
        return output
    }

    private static func htmlEntityEnd(in value: String, from start: String.Index) -> String.Index? {
        var index = value.index(after: start)
        var body = ""
        while index < value.endIndex, body.count <= 32 {
            let character = value[index]
            if character == ";" {
                guard validEntityBody(body) else { return nil }
                return value.index(after: index)
            }
            if character.isWhitespace || character == "&" || character == "<" || character == ">" { return nil }
            body.append(character)
            index = value.index(after: index)
        }
        return nil
    }

    private static func validEntityBody(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        if value.hasPrefix("#x") || value.hasPrefix("#X") {
            return value.dropFirst(2).allSatisfy { $0.isHexDigit } && value.count > 2
        }
        if value.hasPrefix("#") {
            return value.dropFirst().allSatisfy { $0.isNumber } && value.count > 1
        }
        guard value.first?.isLetter == true else { return false }
        return value.allSatisfy { $0.isLetter || $0.isNumber }
    }

    private static func translationBounds(in value: String) -> Range<String.Index>? {
        guard let first = value.firstIndex(where: { !$0.isWhitespace }),
              let last = value.lastIndex(where: { !$0.isWhitespace }) else { return nil }
        return first..<value.index(after: last)
    }

    private static func shouldTranslate(_ value: String) -> Bool {
        let withoutEntities: String
        if let regex = try? NSRegularExpression(
            pattern: #"&(?:#[xX][0-9a-fA-F]+|#[0-9]+|[A-Za-z][A-Za-z0-9]+);"#
        ) {
            withoutEntities = regex.stringByReplacingMatches(
                in: value,
                range: NSRange(value.startIndex..<value.endIndex, in: value),
                withTemplate: ""
            )
        } else {
            withoutEntities = value
        }
        let trimmed = withoutEntities.trimmingCharacters(in: .whitespacesAndNewlines)
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

    private static func entitySafeBoundary(in value: String, start: String.Index,
                                           proposedEnd: String.Index) -> String.Index {
        guard start < proposedEnd else { return proposedEnd }
        let prefix = value[start..<proposedEnd]
        guard let ampersand = prefix.lastIndex(of: "&") else { return proposedEnd }
        if let semicolon = prefix.lastIndex(of: ";"), semicolon > ampersand { return proposedEnd }
        if ampersand > start { return ampersand }
        if let end = htmlEntityEnd(in: value, from: ampersand) { return end }
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
            return html.range(of: "-->", range: start..<html.endIndex)?.upperBound ?? html.endIndex
        }
        if remainder.hasPrefix("<![CDATA[") {
            return html.range(of: "]]>", range: start..<html.endIndex)?.upperBound ?? html.endIndex
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
