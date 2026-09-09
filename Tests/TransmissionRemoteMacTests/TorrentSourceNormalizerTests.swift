// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import XCTest
@testable import TransmissionRemoteMac

final class TorrentSourceNormalizerTests: XCTestCase {
    func testNormalizesUppercaseAndLowercaseBase32SHA1() throws {
        let uppercase = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        let lowercase = uppercase.lowercased()
        let expected = "magnet:?xt=urn:btih:0000000000000000000000000000000000000000"

        XCTAssertEqual(try TorrentSourceNormalizer.normalize(uppercase), expected)
        XCTAssertEqual(try TorrentSourceNormalizer.normalize(lowercase), expected)
        XCTAssertEqual(
            try TorrentSourceNormalizer.normalize("77777777777777777777777777777777"),
            "magnet:?xt=urn:btih:ffffffffffffffffffffffffffffffffffffffff"
        )
    }

    func testNormalizesUppercaseAndLowercaseHexSHA1() throws {
        let uppercase = "0123456789ABCDEF0123456789ABCDEF01234567"
        let lowercase = uppercase.lowercased()
        let expected = "magnet:?xt=urn:btih:\(lowercase)"

        XCTAssertEqual(try TorrentSourceNormalizer.normalize(uppercase), expected)
        XCTAssertEqual(try TorrentSourceNormalizer.normalize(lowercase), expected)
    }

    func testNormalizesUppercaseAndLowercaseHexSHA256() throws {
        let uppercase = "0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF"
        let lowercase = uppercase.lowercased()
        let expected = "magnet:?xt=urn:btmh:1220\(lowercase)"

        XCTAssertEqual(try TorrentSourceNormalizer.normalize(uppercase), expected)
        XCTAssertEqual(try TorrentSourceNormalizer.normalize(lowercase), expected)
    }

    func testRejectsInvalidBase32AlphabetAndLength() {
        assertMalformed("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA0")
        assertMalformed("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")
        assertMalformed("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")
    }

    func testRejectsMalformedHex() {
        assertMalformed("0123456789abcdef0123456789abcdef0123456g")
        assertMalformed("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdeg")
        assertMalformed("0123456789abcdef0123456789abcdef0123456")
        assertMalformed("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcde")
    }

    func testTrimsOnceBeforeNormalizingInfoHash() throws {
        XCTAssertEqual(
            try TorrentSourceNormalizer.normalize(" \n0123456789ABCDEF0123456789ABCDEF01234567\t "),
            "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567"
        )
    }

    func testPreservesSupportedNonHashSourcesAfterTrimming() throws {
        let sources = [
            "magnet:?xt=urn:btih:abc",
            "http://example.com/file.torrent",
            "https://example.com/file.torrent",
            "/srv/watch/file.torrent",
            #"\\server\watch\file.torrent"#,
            #"C:\watch\file.torrent"#
        ]

        for source in sources {
            XCTAssertEqual(try TorrentSourceNormalizer.normalize("  \(source)  "), source)
        }
    }

    func testRejectsUnsupportedNonHashSource() {
        XCTAssertThrowsError(try TorrentSourceNormalizer.normalize("example.com/file.torrent")) { error in
            XCTAssertEqual(error as? TorrentSourceNormalizationError, .unsupportedSource)
        }
    }

    private func assertMalformed(_ source: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try TorrentSourceNormalizer.normalize(source), file: file, line: line) { error in
            XCTAssertEqual(
                error as? TorrentSourceNormalizationError,
                .malformedInfoHash,
                file: file,
                line: line
            )
        }
    }
}
