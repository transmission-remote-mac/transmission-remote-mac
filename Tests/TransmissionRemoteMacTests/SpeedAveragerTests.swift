// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation
import XCTest
@testable import TransmissionRemoteMac

final class SpeedAveragerTests: XCTestCase {
    func testArithmeticAverageUsesOnlyTheBoundedSampleWindow() {
        var averager = SpeedAverager(policy: SpeedAveragingPolicy(
            isEnabled: true,
            sampleLimit: 3,
            windowSeconds: 100
        ))

        XCTAssertEqual(averager.update(bytesPerSecond: 10, at: 1).averageBytesPerSecond, 10)
        XCTAssertEqual(averager.update(bytesPerSecond: 20, at: 2).averageBytesPerSecond, 15)
        XCTAssertEqual(
            averager.update(bytesPerSecond: 30, at: 3),
            SpeedAverageSnapshot(
                latestBytesPerSecond: 30,
                averageBytesPerSecond: 20,
                sampleCount: 3
            )
        )
        XCTAssertEqual(
            averager.update(bytesPerSecond: 50, at: 4),
            SpeedAverageSnapshot(
                latestBytesPerSecond: 50,
                averageBytesPerSecond: 100.0 / 3.0,
                sampleCount: 3
            )
        )
        XCTAssertEqual(averager.retainedSampleCount, 3)
    }

    func testElapsedWindowRetainsBoundaryAndEvictsOlderSamples() {
        var averager = SpeedAverager(policy: SpeedAveragingPolicy(
            isEnabled: true,
            sampleLimit: 10,
            windowSeconds: 10
        ))

        averager.update(bytesPerSecond: 10, at: 0)
        averager.update(bytesPerSecond: 20, at: 5)
        XCTAssertEqual(averager.update(bytesPerSecond: 30, at: 10).sampleCount, 3)

        let snapshot = averager.update(bytesPerSecond: 40, at: 11)

        XCTAssertEqual(snapshot.sampleCount, 3)
        XCTAssertEqual(snapshot.averageBytesPerSecond, 30)
    }

    func testRepeatedTimestampReplacesAndOlderOrInvalidTimestampIsRejected() {
        var averager = SpeedAverager()

        averager.update(bytesPerSecond: 10, at: 5)
        let replacement = averager.update(bytesPerSecond: 30, at: 5)
        let stale = averager.update(bytesPerSecond: 100, at: 4)
        let invalid = averager.update(bytesPerSecond: 200, at: .nan)

        XCTAssertEqual(
            replacement,
            SpeedAverageSnapshot(
                latestBytesPerSecond: 30,
                averageBytesPerSecond: 30,
                sampleCount: 1
            )
        )
        XCTAssertEqual(stale, replacement)
        XCTAssertEqual(invalid, replacement)
        XCTAssertEqual(averager.retainedSampleCount, 1)
    }

    func testNegativeSpeedNormalizesToZeroAndDisabledPolicyKeepsLatestOnly() {
        var averager = SpeedAverager(policy: SpeedAveragingPolicy(
            isEnabled: false,
            sampleLimit: 20,
            windowSeconds: 120
        ))

        averager.update(bytesPerSecond: 100, at: 1)
        let snapshot = averager.update(bytesPerSecond: -50, at: 2)

        XCTAssertEqual(snapshot, SpeedAverageSnapshot(
            latestBytesPerSecond: 0,
            averageBytesPerSecond: 0,
            sampleCount: 1
        ))
        XCTAssertEqual(averager.retainedSampleCount, 1)
    }

    func testPolicyReplacementAndExplicitResetHaveDeterministicSemantics() {
        let policy = SpeedAveragingPolicy(isEnabled: true, sampleLimit: 5, windowSeconds: 30)
        var averager = SpeedAverager(policy: policy)
        averager.update(bytesPerSecond: 10, at: 1)

        averager.replacePolicy(policy)
        XCTAssertEqual(averager.retainedSampleCount, 1)

        averager.replacePolicy(SpeedAveragingPolicy(
            isEnabled: true,
            sampleLimit: 2,
            windowSeconds: 30
        ))
        XCTAssertEqual(averager.snapshot, .empty)

        averager.update(bytesPerSecond: 20, at: 2)
        averager.reset()
        XCTAssertEqual(averager.snapshot, .empty)
        XCTAssertEqual(averager.retainedSampleCount, 0)
    }

    func testMaximumConfiguredSampleCountBoundsRetainedMemory() {
        var averager = SpeedAverager(policy: SpeedAveragingPolicy(
            isEnabled: true,
            sampleLimit: Int.max,
            windowSeconds: Int.max
        ))

        for index in 0 ..< 500 {
            averager.update(bytesPerSecond: Int64(index), at: TimeInterval(index))
        }

        XCTAssertEqual(
            averager.retainedSampleCount,
            SpeedAveragingPolicy.allowedSampleLimit.upperBound
        )
        XCTAssertEqual(averager.snapshot.sampleCount, 120)
        XCTAssertEqual(averager.snapshot.latestBytesPerSecond, 499)
    }
}
