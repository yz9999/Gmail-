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

    func testPreservesTranslatedHTMLLayout() throws {
        let response = Data(#"[[["<table><tr><td><h2>Mac 上的新登录</h2><a href=\"https://example.com\">检查活动</a></td></tr></table>","<table>...</table>",null,null,10]],null,"en"]"#.utf8)

        let translated = try CurlTransport.parseTranslation(response)
        XCTAssertTrue(translated.contains("<table>"))
        XCTAssertTrue(translated.contains("<h2>Mac 上的新登录</h2>"))
        XCTAssertTrue(translated.contains("href=\"https://example.com\""))
    }
}

private extension Data {
    mutating func appendBigEndian(_ value: UInt64) {
        var encoded = value.bigEndian
        Swift.withUnsafeBytes(of: &encoded) { append(contentsOf: $0) }
    }
}
