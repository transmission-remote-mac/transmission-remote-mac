// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation

enum TorrentListFetchMode: Equatable, Sendable {
    case fullSnapshot
    case recentlyActive
    case targeted([Int])
}

struct TorrentListUpdate: Equatable, Sendable {
    var mode: TorrentListFetchMode
    var torrents: [TorrentGetTorrent]
    var removedIDs: [Int]
    var fieldPlanRevision: Int? = nil

    func mergingBootstrap(
        _ bootstrap: TorrentListUpdate,
        requestedIDs: [Int]
    ) -> TorrentListUpdate? {
        guard
            mode == .recentlyActive,
            case .targeted(let bootstrapRequestIDs) = bootstrap.mode,
            fieldPlanRevision == bootstrap.fieldPlanRevision
        else {
            return nil
        }

        let requested = Set(requestedIDs.filter { $0 > 0 })
        guard requested == Set(bootstrapRequestIDs.filter { $0 > 0 }) else { return nil }

        var deltaRows = Self.indexedTorrents(torrents)
        let bootstrapRows = Self.indexedTorrents(bootstrap.torrents)
        let bootstrapRemoved = Set(bootstrap.removedIDs.filter { requested.contains($0) })
            .union(requested.subtracting(bootstrapRows.keys))

        for id in requested {
            guard !bootstrapRemoved.contains(id), let completeRow = bootstrapRows[id] else {
                deltaRows[id] = nil
                continue
            }
            guard
                let deltaRow = deltaRows[id],
                let deltaHash = deltaRow.canonicalHash,
                let completeHash = completeRow.canonicalHash,
                deltaHash == completeHash
            else {
                return nil
            }
            deltaRows[id] = deltaRow.merging(completeRow)
        }

        let removed = Set(removedIDs.filter { $0 > 0 }).union(bootstrapRemoved)
        for removedID in removed {
            deltaRows[removedID] = nil
        }

        return TorrentListUpdate(
            mode: .recentlyActive,
            torrents: deltaRows.keys.sorted().compactMap { deltaRows[$0] },
            removedIDs: removed.sorted(),
            fieldPlanRevision: fieldPlanRevision
        )
    }

    private static func indexedTorrents(
        _ torrents: [TorrentGetTorrent]
    ) -> [TorrentGetTorrent.ID: TorrentGetTorrent] {
        torrents.reduce(into: [:]) { result, torrent in
            guard torrent.id > 0 else { return }
            result[torrent.id] = torrent
        }
    }
}

struct TorrentListRequestOwner: Equatable, Sendable {
    var connectionGeneration: UUID
    var fieldPlanRevision: Int

    func isCurrent(
        connectionGeneration: UUID,
        fieldPlanRevision: Int?
    ) -> Bool {
        self.connectionGeneration == connectionGeneration
            && self.fieldPlanRevision == fieldPlanRevision
    }
}

enum TorrentListApplyResult: Equatable {
    case full([TorrentSummary])
    case changes(upserted: [TorrentSummary], removedIDs: [Int])

    var mappedRowCount: Int {
        switch self {
        case .full(let torrents):
            torrents.count
        case .changes(let upserted, _):
            upserted.count
        }
    }
}

struct TorrentListDeltaAccumulator: Sendable {
    private var connectionGeneration: UUID?
    // Retain the typed domain value needed for partial-row merges, not the
    // decoded JSON dictionaries and nested tracker payload from every torrent.
    private var summariesByID: [TorrentSummary.ID: TorrentSummary] = [:]
    private var nextRepairDeadline: ContinuousClock.Instant?
    private var hasFullSnapshot = false

    mutating func reset(for connectionGeneration: UUID?) {
        self.connectionGeneration = connectionGeneration
        summariesByID = [:]
        nextRepairDeadline = nil
        hasFullSnapshot = false
    }

    mutating func requireFullSnapshot() {
        nextRepairDeadline = nil
        hasFullSnapshot = false
    }

    func fetchMode(at now: ContinuousClock.Instant = ContinuousClock().now) -> TorrentListFetchMode {
        guard hasFullSnapshot, let nextRepairDeadline, now < nextRepairDeadline else {
            return .fullSnapshot
        }
        return .recentlyActive
    }

    func bootstrapIDs(for update: TorrentListUpdate) -> [TorrentGetTorrent.ID] {
        guard hasFullSnapshot, update.mode == .recentlyActive else { return [] }
        let removed = Set(update.removedIDs.filter { $0 > 0 })
        return Set(update.torrents.lazy.compactMap { torrent in
            guard torrent.id > 0, !removed.contains(torrent.id) else { return nil }
            guard
                let refreshedHash = torrent.canonicalHash,
                let existing = summariesByID[torrent.id],
                let existingHash = CanonicalTransmissionTorrentHash.normalize(existing.hashString),
                refreshedHash == existingHash
            else {
                return torrent.id
            }
            return nil
        }).sorted()
    }

    mutating func apply(
        _ update: TorrentListUpdate,
        connectionGeneration: UUID,
        rpcVersion: Int,
        repairInterval: Duration,
        now: ContinuousClock.Instant = ContinuousClock().now
    ) -> TorrentListApplyResult? {
        guard self.connectionGeneration == connectionGeneration else { return nil }

        switch update.mode {
        case .fullSnapshot:
            summariesByID = Dictionary(
                update.torrents.lazy.compactMap { torrent in
                    guard torrent.id > 0 else { return nil }
                    return (torrent.id, TorrentMapper.map(torrent, rpcVersion: rpcVersion))
                },
                uniquingKeysWith: { _, latest in latest }
            )
            nextRepairDeadline = now.advanced(by: repairInterval)
            hasFullSnapshot = true
            return .full(summariesByID.keys.sorted().compactMap { summariesByID[$0] })
        case .recentlyActive, .targeted(_):
            guard hasFullSnapshot else { return nil }
            guard update.torrents.allSatisfy({
                $0.id > 0 && $0.canonicalHash != nil
            }) else {
                requireFullSnapshot()
                return nil
            }
        }

        let responseRowsByID = Self.indexedTorrents(update.torrents)
        var removedIDs = Set(update.removedIDs.filter { $0 > 0 })
        if case .targeted(let requestedIDs) = update.mode {
            let requested = Set(requestedIDs.filter { $0 > 0 })
            removedIDs.formUnion(requested.subtracting(Set(responseRowsByID.keys)))
        }

        for removedID in removedIDs {
            summariesByID[removedID] = nil
        }

        var upserted: [TorrentSummary] = []
        upserted.reserveCapacity(responseRowsByID.count)
        for id in responseRowsByID.keys.sorted() where !removedIDs.contains(id) {
            guard let refreshed = responseRowsByID[id] else { continue }
            let merged: TorrentSummary
            if let existing = summariesByID[id] {
                let existingHash = CanonicalTransmissionTorrentHash.normalize(existing.hashString)
                let refreshedHash = refreshed.canonicalHash
                if existingHash == refreshedHash {
                    merged = TorrentMapper.merging(refreshed, into: existing, rpcVersion: rpcVersion)
                    guard merged != existing else { continue }
                } else {
                    merged = TorrentMapper.map(refreshed, rpcVersion: rpcVersion)
                }
            } else {
                merged = TorrentMapper.map(refreshed, rpcVersion: rpcVersion)
            }
            summariesByID[id] = merged
            upserted.append(merged)
        }

        return .changes(upserted: upserted, removedIDs: removedIDs.sorted())
    }

    private static func indexedTorrents(
        _ torrents: [TorrentGetTorrent]
    ) -> [TorrentGetTorrent.ID: TorrentGetTorrent] {
        torrents.reduce(into: [:]) { result, torrent in
            guard torrent.id > 0 else { return }
            result[torrent.id] = torrent
        }
    }
}

private extension TorrentGetTorrent {
    var canonicalHash: String? {
        hashString.flatMap(CanonicalTransmissionTorrentHash.normalize)
    }
}
