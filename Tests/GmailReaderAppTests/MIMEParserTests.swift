import XCTest
@testable import GmailReaderApp

final class MIMEParserTests: XCTestCase {
    func testDecodesRFC2047Header() {
        XCTAssertEqual(MIMEParser.decodeHeader("=?utf-8?b?5rWL6K+V5Li76aKY?="), "测试主题")
    }

    func testParsesPlainMessage() {
        let raw = Data("From: Sender <sender@example.com>\r\nTo: me@example.com\r\nSubject: Hello\r\nContent-Type: text/plain; charset=UTF-8\r\n\r\nBody text".utf8)
        let message = MIMEParser.message(uid: 42, raw: raw, flags: ["\\Seen"])
        XCTAssertEqual(message.subject, "Hello")
        XCTAssertEqual(message.plainBody, "Body text")
        XCTAssertTrue(message.isRead)
    }

    func testRejectsNoDataLossInQuotedPrintableHeader() {
        XCTAssertEqual(MIMEParser.decodeHeader("=?UTF-8?Q?Hello_=E4=B8=96=E7=95=8C?="), "Hello 世界")
    }
}
