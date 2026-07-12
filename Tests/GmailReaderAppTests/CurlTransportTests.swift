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

    func testParsesBatchedSimplifiedChineseTranslations() throws {
        let response = Data(#"""
        [
          {"detectedLanguage":{"language":"en","score":1.0},"translations":[{"text":"最高可享9折优惠","to":"zh-Hans"}]},
          {"detectedLanguage":{"language":"en","score":1.0},"translations":[{"text":"立即购买","to":"zh-Hans"}]}
        ]
        """#.utf8)

        let result = try CurlTransport.parseSimplifiedChineseTranslations(response, expectedCount: 2)

        XCTAssertEqual(result, ["最高可享9折优惠", "立即购买"])
    }

    func testRejectsIncompleteTranslationBatch() {
        let response = Data(#"[{"translations":[{"text":"你好","to":"zh-Hans"}]}]"#.utf8)

        XCTAssertThrowsError(try CurlTransport.parseSimplifiedChineseTranslations(response, expectedCount: 2))
    }

}

private extension Data {
    mutating func appendBigEndian(_ value: UInt64) {
        var encoded = value.bigEndian
        Swift.withUnsafeBytes(of: &encoded) { append(contentsOf: $0) }
    }
}
