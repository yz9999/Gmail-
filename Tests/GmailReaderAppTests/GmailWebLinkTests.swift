import Foundation
import XCTest
@testable import GmailReaderApp

final class GmailWebLinkTests: XCTestCase {
    func testBuildsExactGmailMessageSearchURL() throws {
        let url = try XCTUnwrap(GmailWebLink.messageURL(
            account: "reader@example.com",
            messageID: "<message.123@example.net>",
            subject: "Ignored subject"
        ))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "mail.google.com")
        XCTAssertEqual(components.path, "/mail/u/")
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "authuser" })?.value, "reader@example.com")
        XCTAssertEqual(components.percentEncodedFragment, "search/rfc822msgid%3A%3Cmessage.123%40example.net%3E")
    }

    func testFallsBackToSubjectWhenMessageIDIsMissing() throws {
        let url = try XCTUnwrap(GmailWebLink.messageURL(
            account: "reader@example.com",
            messageID: " \r\n ",
            subject: "Surface student bundle"
        ))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

        XCTAssertEqual(components.percentEncodedFragment, "search/subject%3A%22Surface%20student%20bundle%22")
    }

    func testRejectsMessageWithoutSearchableIdentity() {
        XCTAssertNil(GmailWebLink.messageURL(account: "reader@example.com", messageID: "", subject: ""))
    }
}
