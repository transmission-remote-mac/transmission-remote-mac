// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import XCTest
@testable import TransmissionRemoteMac

final class AddTorrentInputValidatorTests: XCTestCase {
    func testRemoteSourceValidationAcceptsSupportedInputsAndTrimsWhitespace() throws {
        XCTAssertEqual(
            try AddTorrentInputValidator.normalizedRemoteSource("  magnet:?xt=urn:btih:abc  "),
            "magnet:?xt=urn:btih:abc"
        )
        XCTAssertEqual(
            try AddTorrentInputValidator.normalizedRemoteSource("https://example.com/file.torrent"),
            "https://example.com/file.torrent"
        )
        XCTAssertEqual(
            try AddTorrentInputValidator.normalizedRemoteSource("/srv/watch/file.torrent"),
            "/srv/watch/file.torrent"
        )
        XCTAssertEqual(
            try AddTorrentInputValidator.normalizedRemoteSource(#"C:\watch\file.torrent"#),
            #"C:\watch\file.torrent"#
        )
    }

    func testRemoteSourceValidationDistinguishesEmptyAndUnsupportedInputs() {
        XCTAssertThrowsError(try AddTorrentInputValidator.normalizedRemoteSource("  ")) { error in
            XCTAssertEqual(error as? AddTorrentInputValidationError, .emptyRemoteSource)
        }
        XCTAssertThrowsError(try AddTorrentInputValidator.normalizedRemoteSource("example.com/file.torrent")) { error in
            XCTAssertEqual(error as? AddTorrentInputValidationError, .unsupportedRemoteSource)
        }
        XCTAssertThrowsError(try AddTorrentInputValidator.normalizedRemoteSource("ftp://example.com/file.torrent")) { error in
            XCTAssertEqual(error as? AddTorrentInputValidationError, .unsupportedRemoteSource)
        }
    }

    func testRemoteSourceValidationExposesMalformedInfoHashes() {
        XCTAssertThrowsError(
            try AddTorrentInputValidator.normalizedRemoteSource("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA0")
        ) { error in
            XCTAssertEqual(error as? AddTorrentInputValidationError, .malformedInfoHash)
        }
    }

    func testLocalTorrentDataValidationDistinguishesMissingAndEmptyFiles() throws {
        XCTAssertThrowsError(try AddTorrentInputValidator.validatedLocalTorrentData(nil)) { error in
            XCTAssertEqual(error as? AddTorrentInputValidationError, .missingLocalTorrentFile)
        }
        XCTAssertThrowsError(try AddTorrentInputValidator.validatedLocalTorrentData(Data())) { error in
            XCTAssertEqual(error as? AddTorrentInputValidationError, .emptyLocalTorrentFile)
        }
        XCTAssertEqual(try AddTorrentInputValidator.validatedLocalTorrentData(Data([1, 2, 3])), Data([1, 2, 3]))
    }

    func testDestinationNormalizationTrimsAndOmitsBlankInput() {
        XCTAssertEqual(
            AddTorrentDestinationHistory.normalizedDestination(" /downloads "),
            "/downloads"
        )
        XCTAssertNil(AddTorrentDestinationHistory.normalizedDestination("  "))
    }

    func testDestinationHistoryNormalizesDeduplicatesAndCapsRecentDestinations() {
        var history = AddTorrentDestinationHistory(
            destinations: [" /one ", "", "/two", "/one", "/three"],
            limit: 3
        )

        XCTAssertEqual(history.destinations, ["/one", "/two", "/three"])

        history.record(" /two ")
        XCTAssertEqual(history.destinations, ["/two", "/one", "/three"])

        history.record("/four")
        XCTAssertEqual(history.destinations, ["/four", "/two", "/one"])

        history.record(" ")
        XCTAssertEqual(history.destinations, ["/four", "/two", "/one"])
    }
}
