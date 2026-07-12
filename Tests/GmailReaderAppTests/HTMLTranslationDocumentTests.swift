import XCTest
@testable import GmailReaderApp

final class HTMLTranslationDocumentTests: XCTestCase {
    func testReplacesOnlyVisibleTextAndPreservesCompleteLayout() {
        let html = #"""
        <!DOCTYPE html><html lang="en"><head><title>Original title</title>
        <meta name="viewport" content="width=device-width"><style>.button > a { color: #fff; }</style></head>
        <body><table width="100%" style="border-collapse:collapse"><tr><td>
        <h2>Get up to 10% off</h2><a class="button" href="https://example.com?a=1&amp;b=2">Check &amp; save</a>
        <img src="https://example.com/image.png" alt="Original alt text"></td></tr></table></body></html>
        """#
        let document = HTMLTranslationDocument(html: html)

        XCTAssertEqual(document.units.map(\.source), ["Get up to 10% off", "Check &amp; save"])
        let translated = document.render(translations: [
            document.units[0].id: "最高可享9折优惠",
            document.units[1].id: "检查并节省",
        ])

        XCTAssertTrue(translated.contains("<head><title>Original title</title>"))
        XCTAssertTrue(translated.contains(#"<meta name="viewport" content="width=device-width">"#))
        XCTAssertTrue(translated.contains(".button > a { color: #fff; }"))
        XCTAssertTrue(translated.contains(#"<table width="100%" style="border-collapse:collapse">"#))
        XCTAssertTrue(translated.contains(#"href="https://example.com?a=1&amp;b=2""#))
        XCTAssertTrue(translated.contains(#"src="https://example.com/image.png" alt="Original alt text""#))
        XCTAssertTrue(translated.contains("<h2>最高可享9折优惠</h2>"))
        XCTAssertTrue(translated.contains(">检查并节省</a>"))
    }

    func testEscapesTranslatedTextBeforeWritingItIntoHTML() {
        let document = HTMLTranslationDocument(html: "<p>Hello</p>")
        let escaped = HTMLTranslationDocument.sanitizeTranslatedText("中文 <优惠> & 更多&nbsp;")

        let translated = document.render(translations: [document.units[0].id: escaped])

        XCTAssertEqual(translated, "<p>中文 &lt;优惠&gt; &amp; 更多&nbsp;</p>")
    }

    func testEntityOnlyPreviewPaddingIsNeverTranslated() {
        let padding = String(repeating: "&zwnj;&nbsp;", count: 500)
        let document = HTMLTranslationDocument(html: "<div style=\"display:none\">\(padding)</div>")

        XCTAssertTrue(document.units.isEmpty)
        XCTAssertEqual(document.render(translations: [:]), "<div style=\"display:none\">\(padding)</div>")
    }

    func testMissingTranslationKeepsThatTextNodeOriginal() {
        let document = HTMLTranslationDocument(html: "<p>Hello</p><p>World</p>")

        let translated = document.render(translations: [document.units[0].id: "你好"])

        XCTAssertEqual(translated, "<p>你好</p><p>World</p>")
    }
}
