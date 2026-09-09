// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import XCTest
@testable import TransmissionRemoteMac

final class TorrentCommentWebURLTests: XCTestCase {
    func testAcceptsHTTPAndHTTPSCommentsWithoutChangingTheDisplayedValue() throws {
        let comments = [
            "http://example.com/release-notes",
            "HTTPS://example.com:8443/path?q=one%20two#section",
            "  https://example.com/original-spacing  "
        ]

        for comment in comments {
            let linkTarget = try XCTUnwrap(TorrentCommentWebURL(comment))
            let row = TorrentDetailRow(
                "Comment",
                comment,
                isLongText: true,
                linkTarget: linkTarget
            )

            XCTAssertEqual(row.linkTarget, linkTarget)
            XCTAssertEqual(row.value, comment)
            XCTAssertEqual(row.displayValue, comment)
            XCTAssertEqual(row.id, "Comment")
        }
    }

    func testRejectsCredentialsMalformedURLsUnsupportedSchemesAndNonWebValues() {
        let rejectedComments = [
            "https://user@example.com/private",
            "https://user:password@example.com/private",
            "https://example.com/path with spaces",
            "https://example.com/path\\segment",
            "https:///missing-host",
            "https://example.com:70000/path",
            "javascript:alert(1)",
            "file:///Users/example/file",
            "data:text/plain,hello",
            "magnet:?xt=urn:btih:0123456789",
            "Release notes at https://example.com"
        ]

        for comment in rejectedComments {
            XCTAssertNil(TorrentCommentWebURL(comment), comment)
        }
    }

    func testRowsNeverInferLinkBehaviorFromTheirDisplayLabelOrValue() {
        let value = "https://example.com/value"

        XCTAssertNil(TorrentDetailRow("Comment", value, isLongText: true).linkTarget)
        XCTAssertNil(TorrentDetailRow("Magnet link", value, isLongText: true).linkTarget)
        XCTAssertNil(TorrentDetailRow("Full path", value, isLongText: true).linkTarget)
    }
}
