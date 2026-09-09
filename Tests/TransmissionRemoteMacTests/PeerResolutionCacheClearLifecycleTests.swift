// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import XCTest
@testable import TransmissionRemoteMac

final class PeerResolutionCacheClearLifecycleTests: XCTestCase {
    func testOnlyCurrentUncancelledGenerationConfirmsCompletion() {
        var lifecycle = PeerResolutionCacheClearLifecycle()
        let supersededGeneration = lifecycle.begin()
        let currentGeneration = lifecycle.begin()

        XCTAssertEqual(
            lifecycle.completionOutcome(
                for: supersededGeneration,
                isCancelled: false
            ),
            .superseded
        )
        XCTAssertEqual(
            lifecycle.completionOutcome(
                for: currentGeneration,
                isCancelled: true
            ),
            .cancelled
        )
        XCTAssertEqual(
            lifecycle.completionOutcome(
                for: currentGeneration,
                isCancelled: false
            ),
            .completed
        )
    }

    func testOnlyCompletedOutcomeConfirmsCompletion() {
        XCTAssertTrue(PeerResolutionCacheClearOutcome.completed.confirmsCompletion)
        XCTAssertFalse(PeerResolutionCacheClearOutcome.cancelled.confirmsCompletion)
        XCTAssertFalse(PeerResolutionCacheClearOutcome.superseded.confirmsCompletion)
    }
}
