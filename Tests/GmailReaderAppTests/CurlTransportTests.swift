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

}

private extension Data {
    mutating func appendBigEndian(_ value: UInt64) {
        var encoded = value.bigEndian
        Swift.withUnsafeBytes(of: &encoded) { append(contentsOf: $0) }
    }
}
