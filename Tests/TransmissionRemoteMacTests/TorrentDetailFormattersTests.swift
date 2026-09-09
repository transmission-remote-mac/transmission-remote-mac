// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation
import XCTest
@testable import TransmissionRemoteMac

final class TorrentDetailFormattersTests: XCTestCase {
    private let referenceDate = Date(timeIntervalSince1970: 1_704_110_400)

    func testOptionalTransferSizeUsesPlaceholderButPhysicalFileSizeKeepsZero() {
        XCTAssertEqual(TorrentDetailFormatters.optionalSize(nil), "—")
        XCTAssertEqual(TorrentDetailFormatters.optionalSize(-1), "—")
        XCTAssertEqual(TorrentDetailFormatters.optionalSize(0), "—")
        XCTAssertEqual(TorrentDetailFormatters.optionalSize(1_024), ByteCountFormatters.fileSize(1_024))
        XCTAssertEqual(TorrentDetailFormatters.size(-1), "—")
        XCTAssertEqual(TorrentDetailFormatters.size(0), ByteCountFormatters.fileSize(0))
        XCTAssertNotEqual(TorrentDetailFormatters.size(0), "—")
    }

    func testZeroCountRatioAndPercentRemainNumeric() {
        XCTAssertEqual(TorrentDetailFormatters.count(0), "0")
        XCTAssertEqual(TorrentDetailFormatters.ratio(0), 0.0.formatted(.number.precision(.fractionLength(2))))
        XCTAssertEqual(TorrentDetailFormatters.percent(0), 0.0.formatted(.percent.precision(.fractionLength(1))))
    }

    func testUpdateCountdownRejectsInvalidAndUnsupportedDates() {
        for date in [
            Date(timeIntervalSince1970: .infinity),
            Date(timeIntervalSince1970: -.infinity),
            Date(timeIntervalSince1970: .nan),
            Date(timeIntervalSince1970: 1e300),
            Date(timeIntervalSince1970: -1e300),
            Date.distantFuture.addingTimeInterval(1),
            Date.distantPast.addingTimeInterval(-1),
        ] {
            XCTAssertEqual(TorrentDetailFormatters.updateIn(date, relativeTo: referenceDate), "—")
        }
        XCTAssertEqual(TorrentDetailFormatters.updateIn(nil, relativeTo: referenceDate), "—")
        for reference in [Date(timeIntervalSince1970: .nan), Date(timeIntervalSince1970: 1e300)] {
            XCTAssertEqual(TorrentDetailFormatters.updateIn(referenceDate, relativeTo: reference), "—")
        }
    }

    func testUpdateCountdownPreservesNormalAndPastDates() {
        XCTAssertEqual(
            TorrentDetailFormatters.updateIn(referenceDate.addingTimeInterval(120), relativeTo: referenceDate),
            "2m"
        )
        XCTAssertEqual(
            TorrentDetailFormatters.updateIn(referenceDate.addingTimeInterval(-10), relativeTo: referenceDate),
            "Now"
        )
    }

    func testGeneralTransferFormattersPreserveUnknownZeroAndLimitSemantics() {
        XCTAssertEqual(TorrentDetailFormatters.eta(nil), "—")
        XCTAssertEqual(TorrentDetailFormatters.eta(-1), "∞")
        XCTAssertEqual(TorrentDetailFormatters.speed(nil), "—")
        XCTAssertEqual(TorrentDetailFormatters.speed(0), "—")
        XCTAssertEqual(
            TorrentDetailFormatters.speed(1_024),
            ByteCountFormatters.speed(1_024)
        )
        XCTAssertEqual(TorrentDetailFormatters.optionalRatio(nil), "—")
        XCTAssertEqual(TorrentDetailFormatters.optionalRatio(.infinity), "∞")
        XCTAssertEqual(TorrentDetailFormatters.priority(nil), "—")
        XCTAssertEqual(TorrentDetailFormatters.priority(-1), "Low")
        XCTAssertEqual(TorrentDetailFormatters.priority(0), "Normal")
        XCTAssertEqual(TorrentDetailFormatters.priority(1), "High")
        XCTAssertEqual(TorrentDetailFormatters.count(Optional<Int>.none), "—")
        XCTAssertEqual(TorrentDetailFormatters.count(0), "0")
        XCTAssertEqual(TorrentDetailFormatters.speedLimit(nil), "—")
        XCTAssertEqual(TorrentDetailFormatters.speedLimit(.global), "—")
        XCTAssertEqual(TorrentDetailFormatters.speedLimit(.unlimited), "∞")
        XCTAssertEqual(TorrentDetailFormatters.speedLimit(.limited(512)), "512 KB/s")
    }

    func testWastedAverageAndTrackerUpdateFormattingUsesDetailValues() {
        XCTAssertEqual(TorrentDetailFormatters.wasted(bytes: nil, pieceSize: 1_024), "—")
        XCTAssertEqual(TorrentDetailFormatters.wasted(bytes: 0, pieceSize: 1_024), "—")
        XCTAssertEqual(
            TorrentDetailFormatters.wasted(bytes: 2_048, pieceSize: 1_024),
            "\(ByteCountFormatters.transferSize(2_048)) (2 hash failures)"
        )
        XCTAssertEqual(TorrentDetailFormatters.averageSpeed(bytes: nil, seconds: 2), "—")
        XCTAssertEqual(
            TorrentDetailFormatters.averageSpeed(bytes: 2_048, seconds: 2),
            ByteCountFormatters.speed(1_024)
        )
        XCTAssertEqual(TorrentDetailFormatters.trackerUpdate(nil, relativeTo: referenceDate), "—")
        XCTAssertEqual(TorrentDetailFormatters.trackerUpdate(.updating, relativeTo: referenceDate), "Updating")
        XCTAssertEqual(
            TorrentDetailFormatters.trackerUpdate(
                .scheduled(referenceDate.addingTimeInterval(120)),
                relativeTo: referenceDate
            ),
            "2m"
        )
    }
}
