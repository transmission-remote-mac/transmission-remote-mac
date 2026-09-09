// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import XCTest
@testable import TransmissionRemoteMac

final class ApplicationPollingVisibilityResolverTests: XCTestCase {
    private let resolver = ApplicationPollingVisibilityResolver()

    func testActiveOcclusionVisibleMainWindowIsForeground() {
        XCTAssertEqual(
            resolver.visibility(
                isApplicationActive: true,
                windows: [snapshot(isOcclusionVisible: true)]
            ),
            .foreground
        )
    }

    func testActiveOccludedMainWindowIsBackground() {
        XCTAssertEqual(
            resolver.visibility(
                isApplicationActive: true,
                windows: [snapshot(isOcclusionVisible: false)]
            ),
            .background
        )
    }

    func testInactiveApplicationIsBackgroundEvenWithVisibleWindow() {
        XCTAssertEqual(
            resolver.visibility(
                isApplicationActive: false,
                windows: [snapshot(isOcclusionVisible: true)]
            ),
            .background
        )
    }

    func testNonMainWindowCannotPromotePollingToForeground() {
        XCTAssertEqual(
            resolver.visibility(
                isApplicationActive: true,
                windows: [snapshot(
                    isMainApplicationWindow: false,
                    isOcclusionVisible: true
                )]
            ),
            .background
        )
    }

    func testHiddenOrMiniaturizedMainWindowIsBackground() {
        XCTAssertEqual(
            resolver.visibility(
                isApplicationActive: true,
                windows: [snapshot(isVisible: false, isOcclusionVisible: true)]
            ),
            .background
        )
        XCTAssertEqual(
            resolver.visibility(
                isApplicationActive: true,
                windows: [snapshot(isMiniaturized: true, isOcclusionVisible: true)]
            ),
            .background
        )
    }

    private func snapshot(
        isMainApplicationWindow: Bool = true,
        isVisible: Bool = true,
        isMiniaturized: Bool = false,
        isOcclusionVisible: Bool = false
    ) -> ApplicationWindowVisibilitySnapshot {
        ApplicationWindowVisibilitySnapshot(
            isMainApplicationWindow: isMainApplicationWindow,
            isVisible: isVisible,
            isMiniaturized: isMiniaturized,
            isOcclusionVisible: isOcclusionVisible
        )
    }
}
