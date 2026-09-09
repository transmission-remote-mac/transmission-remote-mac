// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import XCTest
@testable import TransmissionRemoteMac

final class TorrentDetailInstantCacheTests: XCTestCase {
    func testCanonicalHashLookupAndLRUEvictionDoNotReuseNumericIdentity() {
        var cache = TorrentDetailCache(maximumEntryCount: 2)
        cache.store(snapshot(id: 1), pane: .overview, hash: hash(1))
        cache.store(snapshot(id: 2), pane: .overview, hash: hash(2))
        XCTAssertNotNil(cache.snapshots(hash: hash(1).uppercased(), torrentID: 1)[.overview])
        cache.store(snapshot(id: 3), pane: .overview, hash: hash(3))
        XCTAssertEqual(cache.count, 2)
        XCTAssertTrue(cache.snapshots(hash: hash(2), torrentID: 2).isEmpty)
        XCTAssertTrue(cache.snapshots(hash: hash(1), torrentID: 2).isEmpty)
        XCTAssertTrue(cache.snapshots(hash: "invalid", torrentID: 1).isEmpty)
    }

    func testInvalidationPrunesNonselectedPanesAndReusedOrRemovedIDs() {
        var cache = TorrentDetailCache()
        cache.store(snapshot(id: 1), pane: .overview, hash: hash(1))
        cache.store(snapshot(id: 1), pane: .files, hash: hash(1))
        cache.store(snapshot(id: 2), pane: .overview, hash: hash(2))
        cache.invalidate(torrentIDs: [1], panes: [.files])
        XCTAssertNil(cache.snapshots(hash: hash(1), torrentID: 1)[.files])
        XCTAssertNotNil(cache.snapshots(hash: hash(1), torrentID: 1)[.overview])
        cache.reconcile { $0 == 1 ? self.hash(3) : nil }
        XCTAssertEqual(cache.count, 0)
        XCTAssertEqual(cache.retainedPayloadCost, 0)
    }

    func testPayloadLimitRejectsHugeTextAndBoundsCombinedPanes() {
        var cache = TorrentDetailCache(maximumPayloadCost: 4_096)
        var large = snapshot(id: 1)
        large.generalInfo?.comment = String(repeating: "x", count: 5_000)
        cache.store(large, pane: .overview, hash: hash(1))
        XCTAssertEqual(cache.count, 0)
        cache.store(snapshot(id: 1), pane: .overview, hash: hash(1))
        let firstCost = cache.retainedPayloadCost
        cache.store(snapshot(id: 1), pane: .overview, hash: hash(1))
        XCTAssertEqual(cache.retainedPayloadCost, firstCost)
        for id in 2...10 { cache.store(snapshot(id: id), pane: .overview, hash: hash(id)) }
        XCTAssertLessThanOrEqual(cache.retainedPayloadCost, cache.maximumPayloadCost)
        cache.removeAll()
        XCTAssertEqual(cache.retainedPayloadCost, 0)
    }

    func testTenThousandFileSnapshotIsBoundedAndUnrelatedOverviewPreservesFilesRevision() {
        let files = (0..<10_000).map {
            TorrentFile(id: $0, path: "folder", name: "file-\($0)", length: 100, bytesCompleted: 50, wanted: true, priority: 0)
        }
        let detail = TorrentDetail(id: 1, files: files, filesSnapshotRevision: .init())
        var cache = TorrentDetailCache()
        cache.store(detail, pane: .files, hash: hash(1))
        let revision = cache.snapshots(hash: hash(1), torrentID: 1)[.files]?.filesSnapshotRevision
        XCTAssertEqual(revision, detail.filesSnapshotRevision)
        cache.store(snapshot(id: 1), pane: .overview, hash: hash(1))
        XCTAssertEqual(cache.snapshots(hash: hash(1), torrentID: 1)[.files]?.filesSnapshotRevision, revision)
        XCTAssertLessThanOrEqual(cache.retainedPayloadCost, cache.maximumPayloadCost)
    }

    func testUnchangedPanePayloadPreservesRevisionsButChangedValuesDoNot() {
        let previous = snapshot(id: 1)
        for pane in [TorrentDetailPane.files, .peers, .trackers] {
            let fetched = snapshot(id: 1)
            let merged = fetched.preservingUnchangedRevision(from: previous, pane: pane)
            XCTAssertTrue(merged.hasSamePayload(as: previous, pane: pane))
            switch pane {
            case .files: XCTAssertEqual(merged.filesSnapshotRevision, previous.filesSnapshotRevision)
            case .peers: XCTAssertEqual(merged.peersSnapshotRevision, previous.peersSnapshotRevision)
            case .trackers: XCTAssertEqual(merged.trackersSnapshotRevision, previous.trackersSnapshotRevision)
            default: XCTFail("Unexpected pane")
            }
        }
        var changed = snapshot(id: 1)
        changed.files[0].bytesCompleted += 1
        changed.peers[0].rateToClient += 1
        changed.trackers[0].seederCount += 1
        for pane in [TorrentDetailPane.files, .peers, .trackers] {
            XCTAssertFalse(changed.preservingUnchangedRevision(from: previous, pane: pane).hasSamePayload(as: previous, pane: pane))
        }
    }

    func testPeerStatisticsRefreshRetainsResolvedMetadataButChangedEndpointDoesNot() {
        var previous = snapshot(id: 1)
        previous.peers[0].resolvedHostName = "peer.example"
        var fetched = snapshot(id: 1)
        fetched.peers[0].rateToClient = 100
        let merged = fetched.preservingUnchangedRevision(from: previous, pane: .peers)
        XCTAssertEqual(merged.peers[0].resolvedHostName, "peer.example")
        XCTAssertEqual(merged.peers[0].rateToClient, 100)
        XCTAssertNotEqual(merged.peersSnapshotRevision, previous.peersSnapshotRevision)
        fetched.peers[0].host = "127.0.0.3"
        XCTAssertNil(fetched.preservingUnchangedRevision(from: previous, pane: .peers).peers[0].resolvedHostName)
    }

    func testOverviewMergeRetainsOnlyIntentionallyOmittedFields() {
        var previous = snapshot(id: 1).generalInfo!
        previous.comment = "old comment"
        previous.creator = "creator"
        previous.haveValid = 100
        let fresh = snapshot(id: 1).generalInfo!
        let merged = fresh.retainingOmittedFields(["creator"], from: previous)
        XCTAssertEqual(merged.creator, "creator")
        XCTAssertEqual(merged.comment, fresh.comment)
        XCTAssertNil(merged.haveValid)
    }

    private func hash(_ id: Int) -> String { String(format: "%040x", id) }

    private func snapshot(id: Int) -> TorrentDetail {
        TorrentDetail(torrent: TorrentGetTorrent(json: [
            "id": .int(id), "hashString": .string(hash(id)), "comment": .string("detail"),
            "files": .array([.object(["name": .string("folder/file.bin"), "length": .int(100), "bytesCompleted": .int(50)])]),
            "peers": .array([.object(["address": .string("127.0.0.2"), "port": .int(51413)])]),
            "trackerStats": .array([.object(["id": .int(1), "host": .string("tracker.example"), "seederCount": .int(2)])]),
        ]))
    }
}
