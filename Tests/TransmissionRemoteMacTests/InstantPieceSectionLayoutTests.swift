// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import TransmissionRemoteMac

final class InstantPieceSectionLayoutTests: XCTestCase {
    @MainActor
    func testPieceSectionKeepsItsHeightFromFirstSelectionThroughLoadedAndInvalidStates() throws {
        _ = NSApplication.shared
        let partial = try TorrentPieceMap(
            base64Encoded: Data([0b1100_0000]).base64EncodedString(),
            pieceCount: 4
        )
        let states: [TorrentPieceMapState] = [
            .unavailable, .complete(pieceCount: 4), .available(partial),
            .invalid(.malformedBase64),
        ]
        for width in [CGFloat(500), CGFloat(1_200)] {
            let heights = states.map { state in
                let host = NSHostingView(rootView: TorrentPieceMapSectionView(state: state)
                    .frame(width: width))
                host.frame = NSRect(x: 0, y: 0, width: width, height: 200)
                host.layoutSubtreeIfNeeded()
                return host.fittingSize.height
            }
            let firstHeight = try XCTUnwrap(heights.first)
            XCTAssertGreaterThan(firstHeight, 50)
            for height in heights.dropFirst() {
                XCTAssertEqual(height, firstHeight, accuracy: 0.5)
            }
        }
    }

    @MainActor
    func testPieceSectionEqualityTracksOnlyDisplayedPieceState() {
        XCTAssertEqual(
            TorrentPieceMapSectionView(state: .complete(pieceCount: 5_973)),
            TorrentPieceMapSectionView(state: .complete(pieceCount: 5_973))
        )
        XCTAssertNotEqual(
            TorrentPieceMapSectionView(state: .complete(pieceCount: 5_973)),
            TorrentPieceMapSectionView(state: .unavailable)
        )
    }

    func testDateRowEqualityIncludesPreferenceAndAlternateTimestampChanges() {
        let formatter = DateDisplayFormattingService(
            locale: Locale(identifier: "en_US_POSIX"),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        let date = Date(timeIntervalSince1970: 1_000_000)
        let referenceDate = date.addingTimeInterval(120)
        let absolute = TorrentDetailRow.date(
            "Added", date, relativeTo: referenceDate,
            preferences: DateDisplayPreferences(mode: .absolute), formatter: formatter
        )
        let relative = TorrentDetailRow.date(
            "Added", date, relativeTo: referenceDate,
            preferences: DateDisplayPreferences(mode: .relative), formatter: formatter
        )
        XCTAssertNotEqual(absolute, relative)
        XCTAssertEqual(absolute.value, relative.help)
        XCTAssertEqual(relative.value, absolute.help)
        XCTAssertNotEqual(absolute.accessibilityValue, relative.accessibilityValue)

        let laterAbsolute = TorrentDetailRow.date(
            "Added", date, relativeTo: referenceDate.addingTimeInterval(120),
            preferences: DateDisplayPreferences(mode: .absolute), formatter: formatter
        )
        XCTAssertEqual(absolute.value, laterAbsolute.value)
        XCTAssertNotEqual(absolute, laterAbsolute, "An unchanged visible timestamp must still refresh its relative help")
    }
}
