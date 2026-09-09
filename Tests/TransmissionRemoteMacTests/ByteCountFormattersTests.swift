// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation
import XCTest
@testable import TransmissionRemoteMac

final class ByteCountFormattersTests: XCTestCase {
    func testNonpositiveSpeedUsesPlaceholderWithoutRateSuffix() {
        for bytesPerSecond in [Int64.min, -1, 0] {
            XCTAssertEqual(ByteCountFormatters.speed(bytesPerSecond), "—")
            XCTAssertEqual(ByteCountFormatters.speed(bytesPerSecond, zeroValue: ""), "")
            XCTAssertEqual(ByteCountFormatters.speed(bytesPerSecond, zeroValue: "Unavailable"), "Unavailable")
        }
    }

    func testTransferSizeUsesPlaceholderForZeroAndUnavailableValues() {
        for bytes in [Int64.min, -1, 0] {
            XCTAssertEqual(ByteCountFormatters.transferSize(bytes), "—")
        }
    }

    func testPhysicalFileSizeKeepsNumericZero() {
        XCTAssertFalse(ByteCountFormatters.fileSize.allowsNonnumericFormatting)
        let zero = ByteCountFormatters.fileSize(0)
        XCTAssertNotEqual(zero, "—")
        XCTAssertFalse(zero.localizedCaseInsensitiveContains("Zero"))
        XCTAssertTrue(zero.unicodeScalars.contains { CharacterSet.decimalDigits.contains($0) })
    }

    func testPreciseFileSizePreservesByteUnitsAndUsesNumericZero() {
        XCTAssertEqual(ByteCountFormatters.preciseFileSize(0), ByteCountFormatters.fileSize(0))
        for bytes in [Int64(1), 999, 1_000, 1_000_000] {
            XCTAssertEqual(
                ByteCountFormatters.preciseFileSize(bytes),
                ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            )
        }
    }

    func testPositiveSizesAndRatesKeepExistingUnitFormatting() {
        let previousFormatter = ByteCountFormatter()
        previousFormatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        previousFormatter.countStyle = .file

        for bytes in [Int64(1), 999, 1_000, 1_024, 1_000_000, 1_000_000_000, 1_000_000_000_000] {
            let expected = previousFormatter.string(fromByteCount: bytes)
            XCTAssertEqual(ByteCountFormatters.fileSize(bytes), expected)
            XCTAssertEqual(ByteCountFormatters.transferSize(bytes), expected)
            XCTAssertEqual(ByteCountFormatters.speed(bytes), "\(expected)/s")
            XCTAssertEqual(ByteCountFormatters.speed(bytes, zeroValue: ""), "\(expected)/s")
        }
    }

    func testTinyPositiveTransferValuesNeverBecomeEmptyOrUnavailable() {
        XCTAssertNotEqual(ByteCountFormatters.transferSize(1), "—")
        XCTAssertFalse(ByteCountFormatters.transferSize(1).isEmpty)
        XCTAssertNotEqual(ByteCountFormatters.speed(1), "—")
        XCTAssertFalse(ByteCountFormatters.speed(1, zeroValue: "").isEmpty)
    }
}
