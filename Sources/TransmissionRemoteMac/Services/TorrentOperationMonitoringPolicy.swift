// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation

struct TorrentOperationMonitoringSchedule: Equatable, Sendable {
    let pollInterval: Duration
    let maximumPollCount: Int

    init(pollInterval: Duration, maximumPollCount: Int) {
        self.pollInterval = pollInterval
        self.maximumPollCount = max(1, maximumPollCount)
    }
}

struct TorrentOperationMonitoringPolicy: Equatable, Sendable {
    static let standard = TorrentOperationMonitoringPolicy(
        locationAndRename: TorrentOperationMonitoringSchedule(
            pollInterval: .seconds(1),
            maximumPollCount: 20
        ),
        verify: TorrentOperationMonitoringSchedule(
            pollInterval: .seconds(5),
            maximumPollCount: 360
        )
    )

    let locationAndRename: TorrentOperationMonitoringSchedule
    let verify: TorrentOperationMonitoringSchedule

    func schedule(for kind: TorrentOperationKind) -> TorrentOperationMonitoringSchedule {
        switch kind {
        case .verify:
            verify
        case .setLocation, .moveData, .rename:
            locationAndRename
        }
    }

    func pollUnitScale(targetCount: Int, completedPollCount: Int) -> Int {
        let targetScale: Int
        switch targetCount {
        case 1_000...:
            targetScale = 4
        case 250...:
            targetScale = 2
        default:
            targetScale = 1
        }

        let ageScale: Int
        switch completedPollCount {
        case 12...:
            ageScale = 4
        case 4...:
            ageScale = 2
        default:
            ageScale = 1
        }
        return min(16, targetScale * ageScale)
    }
}

struct TorrentOperationMonitoringBatch: Equatable, Sendable {
    let torrentIDs: [TorrentSummary.ID]
    let exhaustedOperationIDs: Set<UUID>
}

/// Connection-scoped fallback schedule. Normal list updates remain the primary
/// completion signal; this only coalesces due targeted refreshes.
struct TorrentOperationMonitoringCoordinator: Sendable {
    private struct Entry: Sendable {
        let kind: TorrentOperationKind
        let torrentIDs: [TorrentSummary.ID]
        var completedPollCount = 0
        var consumedPollUnits = 0
        var deadline: Duration
        var dueWillExhaust = false
    }

    private let policy: TorrentOperationMonitoringPolicy
    private var entries: [UUID: Entry] = [:]

    init(policy: TorrentOperationMonitoringPolicy) {
        self.policy = policy
    }

    var nextDeadline: Duration? {
        entries.values.map(\.deadline).min()
    }

    mutating func register(
        operationID: UUID,
        kind: TorrentOperationKind,
        torrentIDs: [TorrentSummary.ID],
        now: Duration
    ) {
        let normalizedIDs = Array(Set(torrentIDs.filter { $0 > 0 })).sorted()
        guard !normalizedIDs.isEmpty else { return }
        let schedule = policy.schedule(for: kind)
        let scale = policy.pollUnitScale(
            targetCount: normalizedIDs.count,
            completedPollCount: 0
        )
        entries[operationID] = Entry(
            kind: kind,
            torrentIDs: normalizedIDs,
            deadline: now + Self.scaled(schedule.pollInterval, by: scale)
        )
    }

    mutating func remove(operationID: UUID) {
        entries[operationID] = nil
    }

    mutating func removeAll() {
        entries = [:]
    }

    mutating func advance(at now: Duration) -> TorrentOperationMonitoringBatch {
        guard !entries.isEmpty else {
            return TorrentOperationMonitoringBatch(
                torrentIDs: [],
                exhaustedOperationIDs: []
            )
        }

        var exhaustedOperationIDs = Set<UUID>()
        var dueTorrentIDs = Set<TorrentSummary.ID>()
        for operationID in Array(entries.keys) {
            guard var entry = entries[operationID], entry.deadline <= now else {
                continue
            }
            if entry.dueWillExhaust {
                exhaustedOperationIDs.insert(operationID)
                entries[operationID] = nil
                continue
            }

            dueTorrentIDs.formUnion(entry.torrentIDs)
            let schedule = policy.schedule(for: entry.kind)
            let completedScale = policy.pollUnitScale(
                targetCount: entry.torrentIDs.count,
                completedPollCount: entry.completedPollCount
            )
            entry.consumedPollUnits += completedScale
            entry.completedPollCount += 1

            let remainingUnits = schedule.maximumPollCount - entry.consumedPollUnits
            if remainingUnits <= 0 {
                if entry.kind == .verify {
                    let maximumBackoffScale = policy.pollUnitScale(
                        targetCount: entry.torrentIDs.count,
                        completedPollCount: Int.max
                    )
                    entry.deadline = now + Self.scaled(
                        schedule.pollInterval,
                        by: maximumBackoffScale
                    )
                } else {
                    entry.deadline = now
                    entry.dueWillExhaust = true
                }
            } else {
                let nextScale = policy.pollUnitScale(
                    targetCount: entry.torrentIDs.count,
                    completedPollCount: entry.completedPollCount
                )
                let nextUnits = min(nextScale, remainingUnits)
                entry.deadline = now + Self.scaled(schedule.pollInterval, by: nextUnits)
                entry.dueWillExhaust = entry.kind != .verify && nextScale > remainingUnits
            }
            entries[operationID] = entry
        }

        return TorrentOperationMonitoringBatch(
            torrentIDs: dueTorrentIDs.sorted(),
            exhaustedOperationIDs: exhaustedOperationIDs
        )
    }

    private static func scaled(_ duration: Duration, by multiplier: Int) -> Duration {
        (0..<max(0, multiplier)).reduce(into: Duration.zero) { result, _ in
            result += duration
        }
    }
}
