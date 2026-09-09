// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation

/// Connection-local, display-only LRU. A cache hit never grants mutation ownership.
/// Both entry count and retained payload cost are bounded, including file trees.
struct TorrentDetailCache {
    private struct CachedPane {
        var snapshot: TorrentDetail
        var cost: Int
    }

    private struct Entry {
        var torrentID: Int
        var panes: [TorrentDetailPane: CachedPane]
        var cost: Int
    }

    let maximumEntryCount: Int
    let maximumPayloadCost: Int
    private var entries: [String: Entry] = [:]
    private var recency: [String] = []
    private(set) var retainedPayloadCost = 0

    var count: Int { entries.count }

    init(maximumEntryCount: Int = 16, maximumPayloadCost: Int = 8 * 1_024 * 1_024) {
        self.maximumEntryCount = max(0, maximumEntryCount)
        self.maximumPayloadCost = max(0, maximumPayloadCost)
    }

    mutating func snapshots(hash: String, torrentID: Int) -> [TorrentDetailPane: TorrentDetail] {
        guard let hash = CanonicalTransmissionTorrentHash.normalize(hash),
              let entry = entries[hash], entry.torrentID == torrentID else { return [:] }
        touch(hash)
        return entry.panes.mapValues(\.snapshot)
    }

    mutating func store(_ snapshot: TorrentDetail, pane: TorrentDetailPane, hash: String) {
        guard let hash = CanonicalTransmissionTorrentHash.normalize(hash) else { return }
        var entry = entries[hash].flatMap { $0.torrentID == snapshot.id ? $0 : nil }
            ?? Entry(torrentID: snapshot.id, panes: [:], cost: 0)
        // A server may return extra fields. Retain only this pane, not duplicate
        // copies of large Files/Peers arrays in every cached pane.
        var scoped = TorrentDetail(id: snapshot.id).replacing(pane, with: snapshot)
        scoped.generalInfo = snapshot.generalInfo
        if let previous = entry.panes[pane], previous.snapshot.hasSamePayload(as: scoped, pane: pane) {
            touch(hash)
            return
        }
        let paneCost = Self.payloadCost(scoped)
        entry.cost += paneCost - (entry.panes[pane]?.cost ?? 0)
        entry.panes[pane] = CachedPane(snapshot: scoped, cost: paneCost)
        remove(hash: hash)
        guard maximumEntryCount > 0, entry.cost <= maximumPayloadCost else { return }
        entries[hash] = entry
        retainedPayloadCost += entry.cost
        touch(hash)
        while entries.count > maximumEntryCount || retainedPayloadCost > maximumPayloadCost {
            guard let oldest = recency.first else { break }
            remove(hash: oldest)
        }
    }

    mutating func invalidate(torrentIDs: Set<Int>, panes: Set<TorrentDetailPane>) {
        for hash in Array(entries.keys) {
            guard var entry = entries[hash], torrentIDs.contains(entry.torrentID) else { continue }
            retainedPayloadCost -= entry.cost
            for pane in panes {
                entry.cost -= entry.panes.removeValue(forKey: pane)?.cost ?? 0
            }
            retainedPayloadCost += entry.cost
            entries[hash] = entry
            if entry.panes.isEmpty { remove(hash: hash) }
        }
    }

    mutating func reconcile(identityForTorrentID: (Int) -> String?) {
        for (hash, entry) in entries {
            guard identityForTorrentID(entry.torrentID)
                .flatMap(CanonicalTransmissionTorrentHash.normalize) == hash else {
                remove(hash: hash)
                continue
            }
        }
    }

    mutating func remove(hash: String) {
        guard let hash = CanonicalTransmissionTorrentHash.normalize(hash) else { return }
        if let entry = entries.removeValue(forKey: hash) { retainedPayloadCost -= entry.cost }
        recency.removeAll { $0 == hash }
    }

    mutating func removeAll() {
        entries = [:]
        recency = []
        retainedPayloadCost = 0
    }

    private mutating func touch(_ hash: String) {
        recency.removeAll { $0 == hash }
        recency.append(hash)
    }

    private static func payloadCost(_ detail: TorrentDetail) -> Int {
        // Conservative accounting rather than expanding/serializing payloads.
        // File paths occur in both the flat snapshot and hierarchical tree.
        var cost = 1_024
        for file in detail.files {
            cost += 256 + file.path.utf8.count + file.name.utf8.count
        }
        cost += treeCost(detail.fileTree)
        for peer in detail.peers {
            cost += 512 + peer.id.utf8.count + peer.host.utf8.count + peer.clientName.utf8.count
                + peer.flags.utf8.count + peer.country.utf8.count + peer.countryCode.utf8.count
                + peer.countryFlag.utf8.count + peer.clearingResolution.country.utf8.count
                + (peer.resolvedHostName?.utf8.count ?? 0)
        }
        for tracker in detail.trackers {
            cost += 512 + tracker.id.utf8.count + tracker.announce.utf8.count
                + tracker.host.utf8.count + tracker.status.utf8.count
        }
        if let info = detail.generalInfo {
            cost += info.hashString.utf8.count + info.errorString.utf8.count
                + info.comment.utf8.count + info.creator.utf8.count + info.magnetLink.utf8.count
                + (info.downloadDir?.utf8.count ?? 0)
                + (info.labels?.reduce(0) { $0 + $1.utf8.count } ?? 0)
            if case .available(let map) = info.pieceMapState { cost += map.packedByteCount }
        }
        return cost
    }

    private static func treeCost(_ nodes: [TorrentFileNode]) -> Int {
        nodes.reduce(0) { cost, node in
            cost + 256 + node.id.utf8.count + node.path.utf8.count + node.name.utf8.count
                + treeCost(node.children ?? [])
        }
    }
}
