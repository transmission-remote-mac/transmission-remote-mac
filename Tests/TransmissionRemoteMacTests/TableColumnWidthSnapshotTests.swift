// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import XCTest
@testable import TransmissionRemoteMac

final class TableColumnWidthSnapshotTests: XCTestCase {
    func testExplicitWidthsAreReadWithoutRequiringVisibilityOrOrder() {
        let data = Data(#"{"perColumnState":[{"base":{"explicit":{"_0":"size"}}},{"currentWidth":137},{"base":{"explicit":{"_0":"name"}}},{"visibility":{"automatic":{}},"currentWidth":553.5}]}"#.utf8)
        XCTAssertEqual(TableColumnWidthSnapshot.widths(in: data), ["size": 137, "name": 553.5])
    }

    func testMalformedAbsentAndNonpositiveWidthsDoNotBecomeRestorationTargets() {
        for text in ["invalid", "{}", #"{"perColumnState":[{"currentWidth":137}]}"#,
                     #"{"perColumnState":[{"base":{"explicit":{"_0":"size"}}},{"currentWidth":0}]}"#,
                     #"{"perColumnState":[{"base":{"explicit":{"_0":"size"}}},{"currentWidth":-1}]}"#] {
            XCTAssertEqual(TableColumnWidthSnapshot.widths(in: Data(text.utf8)), [:])
        }
    }
}
