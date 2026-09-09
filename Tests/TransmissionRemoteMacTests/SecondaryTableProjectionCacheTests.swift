// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Combine
import XCTest
@testable import TransmissionRemoteMac

final class SecondaryTableProjectionCacheTests: XCTestCase {
    @MainActor
    func testRenderAndSynchronizationShareOneBuildWithoutPublishing() {
        let cache = SecondaryTableProjectionCache<Int, [Int]>()
        var publications = 0
        let observation = cache.objectWillChange.sink { publications += 1 }
        var sorts = 0
        for _ in 0..<10 {
            let rows = cache.value(for: 1, sort: SecondaryTableDefaults.peerSort) {
                sorts += 1
                return [3, 1, 2].sorted()
            }
            XCTAssertEqual(rows, [1, 2, 3])
        }
        XCTAssertEqual(sorts, 1)
        XCTAssertEqual(publications, 0)
        withExtendedLifetime(observation) {}
    }

    @MainActor
    func testSnapshotAndSortEachInvalidateOnceIncludingEmptyResults() {
        let cache = SecondaryTableProjectionCache<Int, [Int]>()
        let ascending = SecondaryTableDefaults.trackerSort
        let descending = SecondaryTableSortPreference(columnID: ascending.columnID, direction: .descending)
        var builds = 0
        for _ in 0..<2 {
            XCTAssertEqual(cache.value(for: 1, sort: ascending) {
                builds += 1
                return []
            }, [])
        }
        XCTAssertEqual(builds, 1)
        _ = cache.value(for: 2, sort: ascending) {
            builds += 1
            return []
        }
        XCTAssertEqual(builds, 2)
        _ = cache.value(for: 2, sort: descending) {
            builds += 1
            return []
        }
        _ = cache.value(for: 2, sort: descending) { XCTFail("Repeated sort key rebuilt"); return [] }
        XCTAssertEqual(builds, 3)
    }

    @MainActor
    func testFilesPlannerAndRowsShareImmutableProjectionAndStaleGuard() throws {
        let detail = TorrentDetail(
            id: 7,
            files: [
                TorrentFile(id: 0, path: "", name: "z.bin", length: 10, bytesCompleted: 0, wanted: true, priority: 0),
                TorrentFile(id: 1, path: "", name: "a.bin", length: 20, bytesCompleted: 0, wanted: true, priority: 0)
            ],
            filesSnapshotRevision: TorrentFilesSnapshotRevision()
        )
        let identity = try XCTUnwrap(TorrentFilesProjectionIdentity(detail: detail))
        let cache = SecondaryTableProjectionCache<TorrentFilesProjectionIdentity, TorrentFilesTableProjection>()
        var builds = 0
        let render = cache.value(for: identity, sort: SecondaryTableDefaults.fileSort) {
            builds += 1
            let rows = SecondaryTableSorting.files(detail.fileTree, by: SecondaryTableDefaults.fileSort)
            return TorrentFilesTableProjection(tree: rows, planner: TorrentFileSelectionPlanner(tree: rows))
        }
        let synchronization = cache.value(for: identity, sort: SecondaryTableDefaults.fileSort) {
            XCTFail("Synchronization rebuilt the already rendered file projection")
            return TorrentFilesTableProjection(tree: [], planner: TorrentFileSelectionPlanner())
        }
        XCTAssertEqual(render.tree.map(\.name), ["a.bin", "z.bin"])
        XCTAssertEqual(synchronization.planner.fileIndexes(in: synchronization.planner.allNodeIDs), [1, 0])
        XCTAssertEqual(builds, 1)
        let replacement = TorrentDetail(id: 7, filesSnapshotRevision: TorrentFilesSnapshotRevision())
        XCTAssertFalse(TorrentFilesProjectionCommitGuard.canCommit(
            expectedIdentity: identity,
            projectionOwnerIdentity: identity,
            currentIdentity: TorrentFilesProjectionIdentity(detail: replacement)
        ))
    }
}
