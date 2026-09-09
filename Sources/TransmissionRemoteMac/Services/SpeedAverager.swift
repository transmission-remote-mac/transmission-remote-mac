// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation

struct SpeedAverageSnapshot: Equatable, Sendable {
    let latestBytesPerSecond: Int64
    let averageBytesPerSecond: Double
    let sampleCount: Int

    static let empty = SpeedAverageSnapshot(
        latestBytesPerSecond: 0,
        averageBytesPerSecond: 0,
        sampleCount: 0
    )
}

struct SpeedAverager: Sendable {
    private struct Sample: Sendable {
        let timestamp: TimeInterval
        let bytesPerSecond: Int64
    }

    private(set) var policy: SpeedAveragingPolicy
    private var samples: [Sample] = []

    init(policy: SpeedAveragingPolicy = .defaults) {
        self.policy = policy
    }

    var retainedSampleCount: Int {
        samples.count
    }

    var snapshot: SpeedAverageSnapshot {
        guard let latest = samples.last else { return .empty }
        let total = samples.reduce(0.0) { result, sample in
            result + Double(sample.bytesPerSecond)
        }
        return SpeedAverageSnapshot(
            latestBytesPerSecond: latest.bytesPerSecond,
            averageBytesPerSecond: total / Double(samples.count),
            sampleCount: samples.count
        )
    }

    /// Accepts monotonic samples. A repeated timestamp replaces its sample;
    /// an older or non-finite timestamp is rejected without mutation.
    @discardableResult
    mutating func update(
        bytesPerSecond: Int64,
        at timestamp: TimeInterval
    ) -> SpeedAverageSnapshot {
        guard timestamp.isFinite else { return snapshot }

        let normalizedSpeed = max(0, bytesPerSecond)
        if let latest = samples.last {
            guard timestamp >= latest.timestamp else { return snapshot }
            if timestamp == latest.timestamp {
                samples[samples.count - 1] = Sample(
                    timestamp: timestamp,
                    bytesPerSecond: normalizedSpeed
                )
            } else {
                samples.append(Sample(timestamp: timestamp, bytesPerSecond: normalizedSpeed))
            }
        } else {
            samples.append(Sample(timestamp: timestamp, bytesPerSecond: normalizedSpeed))
        }

        if policy.isEnabled {
            prune(relativeTo: timestamp)
        } else if samples.count > 1 {
            samples.removeFirst(samples.count - 1)
        }
        return snapshot
    }

    mutating func reset() {
        samples.removeAll(keepingCapacity: true)
    }

    mutating func replacePolicy(_ newPolicy: SpeedAveragingPolicy) {
        guard newPolicy != policy else { return }
        policy = newPolicy
        reset()
    }

    private mutating func prune(relativeTo timestamp: TimeInterval) {
        let earliestTimestamp = timestamp - TimeInterval(policy.windowSeconds)
        if let firstRetainedIndex = samples.firstIndex(where: { $0.timestamp >= earliestTimestamp }) {
            if firstRetainedIndex > samples.startIndex {
                samples.removeFirst(firstRetainedIndex)
            }
        } else {
            samples.removeAll(keepingCapacity: true)
        }

        if samples.count > policy.sampleLimit {
            samples.removeFirst(samples.count - policy.sampleLimit)
        }
    }
}
