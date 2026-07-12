import Foundation
import XCTest
@testable import GmailReaderApp

final class CurlTransportTests: XCTestCase {
    func testDecodeCombinedPageResponse() throws {
        let uid: UInt64 = 42
        let header = Data("From: Sender <sender@example.com>\r\nSubject: Hello\r\n\r\n".utf8)
        let fetch = Data("* 1 FETCH (UID 42 FLAGS (\\Seen) BODY[HEADER.FIELDS (FROM TO SUBJECT DATE MESSAGE-ID)] {\(header.count)}\r\n".utf8)
            + header
            + Data(")\r\nA004 OK FETCH completed\r\n".utf8)
        var data = Data("GRP1".utf8)
        data.appendBigEndian(UInt64(1))
        data.appendBigEndian(uid)
        data.append(fetch)

        let result = try CurlTransport.decodePage(data, page: 1, pageSize: 50)

        XCTAssertEqual(result.allUIDs, [uid])
        XCTAssertEqual(result.summaries[uid]?.header, header)
        XCTAssertEqual(result.summaries[uid]?.flags, Set(["\\Seen"]))
    }

    func testRejectsTruncatedCombinedPageResponse() {
        var data = Data("GRP1".utf8)
        data.appendBigEndian(UInt64(2))
        data.appendBigEndian(UInt64(1))

        XCTAssertThrowsError(try CurlTransport.decodePage(data, page: 1, pageSize: 50))
    }

    func testParsesGoogleChineseTranslation() throws {
        let response = Data(#"[[["\u60a8\u597d\uff0c","Hello,",null,null,10],["\u8fd9\u662f\u4e00\u5c01\u90ae\u4ef6。"," this is an email.",null,null,10]],null,"en"]"#.utf8)

        XCTAssertEqual(try CurlTransport.parseTranslation(response), "您好，这是一封邮件。")
    }

    func testTranslatesOnlyVisibleHTMLTextNodes() throws {
        let html = #"""
        <!DOCTYPE html><html lang="en"><head><title>Never translate this</title>
        <meta name="viewport" content="width=device-width"><style>.button > a { color: #fff; }</style></head>
        <body><table width="100%" style="border-collapse:collapse"><tr><td>
        <h2>New sign-in on Mac</h2><a class="button" href="https://accounts.google.com/check?a=1&amp;b=2">Check activity</a>
        <img src="https://example.com/pixel?q=hello" alt="Original alt text"></td></tr></table></body></html>
        """#
        let document = HTMLTranslationDocument(html: html)

        XCTAssertEqual(document.units.map(\.source), ["New sign-in on Mac", "Check activity"])
        let translated = document.render(translations: [
            document.units[0].id: "Mac 上的新登录",
            document.units[1].id: "检查活动",
        ])

        XCTAssertTrue(translated.contains("<head><title>Never translate this</title>"))
        XCTAssertTrue(translated.contains(#"<meta name="viewport" content="width=device-width">"#))
        XCTAssertTrue(translated.contains(".button > a { color: #fff; }"))
        XCTAssertTrue(translated.contains(#"<table width="100%" style="border-collapse:collapse">"#))
        XCTAssertTrue(translated.contains(#"href="https://accounts.google.com/check?a=1&amp;b=2""#))
        XCTAssertTrue(translated.contains(#"src="https://example.com/pixel?q=hello" alt="Original alt text""#))
        XCTAssertTrue(translated.contains("<h2>Mac 上的新登录</h2>"))
        XCTAssertTrue(translated.contains(">检查活动</a>"))
    }

    func testParsesBatchedTextWhilePreservingEntities() throws {
        let html = #"<table><tr><td>Hello&nbsp;world &amp; friends</td><td>Shop now</td></tr></table>"#
        let document = HTMLTranslationDocument(html: html)
        let request = HTMLTranslationDocument.requestHTML(for: document.units)
        XCTAssertFalse(request.contains("<table>"))
        XCTAssertFalse(request.contains("&nbsp;"))
        XCTAssertTrue(request.contains(#"<gr-entity data-id="0">"#))

        let firstID = document.units[0].id
        let secondID = document.units[1].id
        let response = #"<gr-unit data-id="\#(firstID)">你好<gr-entity data-id="0"></gr-entity>世界<gr-entity data-id="1"></gr-entity>朋友</gr-unit><gr-unit data-id="\#(secondID)">立即购买</gr-unit>"#
        let parsed = try XCTUnwrap(HTMLTranslationDocument.parseResponse(response, expected: document.units))
        let translated = document.render(translations: parsed)

        XCTAssertEqual(translated, #"<table><tr><td>你好&nbsp;世界&amp;朋友</td><td>立即购买</td></tr></table>"#)
    }

    func testRejectsTranslationWhenGoogleChangesGeneratedWrappers() {
        let document = HTMLTranslationDocument(html: "<p>Hello</p>")
        let response = #"<分区 data-gr-unit="0">你好</分区>"#
        XCTAssertNil(HTMLTranslationDocument.parseResponse(response, expected: document.units))
    }

    func testKeepsValidUnitsWhenOneWrapperIsDamaged() {
        let document = HTMLTranslationDocument(html: "<p>Hello</p><p>World</p>")
        let response = #"<gr-unitdata-id="0">你好</gr-unit><损坏-1>世界</损坏-1>"#

        let parsed = HTMLTranslationDocument.parseAvailableResponse(response, expected: document.units)

        XCTAssertEqual(parsed, [document.units[0].id: "你好"])
    }

    func testUnitIDsDoNotPrefixMatchOtherUnits() {
        let html = (0..<12).map { "<p>Text \($0)</p>" }.joined()
        let document = HTMLTranslationDocument(html: html)
        let response = document.units.map { #"<gr-unit data-id="\#($0.id)">译文\#($0.id)</gr-unit>"# }.joined()

        let parsed = HTMLTranslationDocument.parseAvailableResponse(response, expected: document.units)

        XCTAssertEqual(parsed.count, 12)
        XCTAssertEqual(parsed[1], "译文1")
        XCTAssertEqual(parsed[10], "译文10")
    }

    func testPlainFallbackEscapesTextAndRestoresOriginalEntities() throws {
        let document = HTMLTranslationDocument(html: "<p>Hello&nbsp;world &amp; friends</p>")
        let unit = try XCTUnwrap(document.units.first)
        let request = HTMLTranslationDocument.plainFallbackRequest(for: unit)
        XCTAssertFalse(request.contains("&nbsp;"))
        XCTAssertFalse(request.contains("<gr-entity"))
        XCTAssertTrue(request.contains("__GMAIL_READER_HTML_0_0__"))

        let response = "你好__GMAIL_READER_HTML_0_0__世界__GMAIL_READER_HTML_0_1__<朋友>"
        let parsed = HTMLTranslationDocument.parsePlainFallbackResponse(response, for: unit)

        XCTAssertEqual(parsed, "你好&nbsp;世界&amp;&lt;朋友&gt;")
    }

    func testPlainFallbackRejectsMissingEntityMarker() throws {
        let document = HTMLTranslationDocument(html: "<p>Hello&nbsp;world</p>")
        let unit = try XCTUnwrap(document.units.first)

        XCTAssertNil(HTMLTranslationDocument.parsePlainFallbackResponse("你好世界", for: unit))
    }

    func testBatchedPlainFallbackRecoversOnlyCompleteUnits() {
        let document = HTMLTranslationDocument(html: "<p>Hello</p><p>World &amp; friends</p>")
        let request = HTMLTranslationDocument.plainFallbackRequest(for: document.units)
        XCTAssertTrue(request.contains("__GMAIL_READER_UNIT_0_BEGIN__"))
        XCTAssertTrue(request.contains("__GMAIL_READER_UNIT_1_END__"))

        let response = """
        __GMAIL_READER_UNIT_0_BEGIN__你好<用户>__GMAIL_READER_UNIT_0_END__
        __GMAIL_READER_UNIT_1_BEGIN__世界和朋友__GMAIL_READER_UNIT_1_END__
        """
        let parsed = HTMLTranslationDocument.parsePlainFallbackResponse(response, expected: document.units)

        XCTAssertEqual(parsed, [document.units[0].id: "你好&lt;用户&gt;"])
    }

    func testEntityHeavyTextIsSplitBelowTranslationRequestLimit() {
        let html = "<p>Preview offer" + String(repeating: "&zwnj;&nbsp;", count: 500) + "available now</p>"
        let document = HTMLTranslationDocument(html: html)

        XCTAssertFalse(document.units.isEmpty)
        XCTAssertTrue(document.batches().allSatisfy {
            HTMLTranslationDocument.requestHTML(for: $0).count <= 3_500
        })
    }
}

private extension Data {
    mutating func appendBigEndian(_ value: UInt64) {
        var encoded = value.bigEndian
        Swift.withUnsafeBytes(of: &encoded) { append(contentsOf: $0) }
    }
}
