// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation
import XCTest

final class DetailSplitResizeContractTests: XCTestCase {
    func testMovingDividerMeasuresDragOutsideItsOwnLocalCoordinates() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/TransmissionRemoteMac/Views/PersistedDetailSplitView.swift"
            ),
            encoding: .utf8
        )

        // This wiring contract guards the actual gesture, not an unrelated
        // arithmetic helper that would also pass with the moving-local-space bug.
        let gestures = try NSRegularExpression(pattern: #"DragGesture\s*\([^)]*\)"#)
            .matches(in: source, range: NSRange(source.startIndex..., in: source))
        XCTAssertEqual(gestures.count, 1)
        let gesture = try XCTUnwrap(gestures.first)
        let range = try XCTUnwrap(Range(gesture.range, in: source))
        XCTAssertTrue(source[range].contains("coordinateSpace: .global"))
        XCTAssertTrue(source.contains(".frame(maxWidth: .infinity, maxHeight: .infinity)\n        .contentShape(Rectangle())"))
    }
}
