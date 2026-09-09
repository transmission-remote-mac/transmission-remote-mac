// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import XCTest
@testable import TransmissionRemoteMac

final class TorrentListProjectionTests: XCTestCase {
    func testProjectionMaterializesFilteringSortingCountsAndIndexes() {
        let torrents = [
            torrent(id: 4, name: "Slow", rateDownload: 10, path: "/b", tracker: "two.example"),
            torrent(id: 2, name: "Fast B", rateDownload: 30, path: "/a", tracker: "one.example"),
            torrent(id: 1, name: "Fast A", rateDownload: 30, path: "/a", tracker: "one.example"),
            torrent(id: 3, name: "Hidden", status: .stopped, path: "/b", tracker: "two.example")
        ]
        let projection = TorrentListProjection(
            torrents: torrents,
            filters: TorrentFilters(statuses: [.downloading]),
            sortOrder: [KeyPathComparator(\TorrentSummary.rateDownload, order: .reverse)]
        )

        XCTAssertEqual(projection.visibleRows.map(\.id), [1, 2, 4])
        XCTAssertEqual(projection.visibleIDs, [1, 2, 4])
        XCTAssertEqual(projection.filterCounts.statuses[.all], 4)
        XCTAssertEqual(projection.filterCounts.statuses[.downloading], 3)
        XCTAssertEqual(projection.filterCounts.paths, [
            TorrentFilterCount(value: "/a", count: 2),
            TorrentFilterCount(value: "/b", count: 2)
        ])
        XCTAssertEqual(projection.row(for: 3)?.name, "Hidden")
        XCTAssertNil(projection.row(for: 404))
    }

    func testProjectionReturnsSourceAndDisplayOrdersWithoutScanningRows() {
        let projection = TorrentListProjection(
            torrents: [
                torrent(id: 30, name: "Zulu"),
                torrent(id: 10, name: "Alpha"),
                torrent(id: 20, name: "Mike")
            ],
            filters: .empty,
            sortOrder: TorrentSorting.defaultSortOrder
        )

        XCTAssertEqual(projection.rows(for: [10, 30]).map(\.id), [30, 10])
        XCTAssertEqual(projection.visibleRows(for: [10, 30]).map(\.id), [10, 30])
        XCTAssertEqual(projection.selectedRowsInDisplayOrder(for: [20, 30]).map(\.id), [20, 30])
        XCTAssertTrue(projection.visibleRows(for: [10, 404]).isEmpty)
    }

    func testActivePollingActivityIndexTracksIncrementalStatusChangesAndRemovals() {
        let filters = TorrentFilters.empty
        let sortOrder = TorrentSorting.defaultSortOrder
        let filterEngine = TorrentFilterEngine()
        var projection = TorrentListProjection(
            torrents: [
                torrent(id: 1, name: "Stopped", status: .stopped),
                torrent(id: 2, name: "Queued", status: .downloadWait),
            ],
            filters: filters,
            sortOrder: sortOrder,
            filterEngine: filterEngine
        )

        XCTAssertTrue(projection.hasTorrentActivityRequiringActivePolling)

        _ = projection.apply(
            upserted: [torrent(id: 2, name: "Stopped too", status: .stopped)],
            removedIDs: [],
            filters: filters,
            sortOrder: sortOrder,
            filterEngine: filterEngine
        )
        XCTAssertFalse(projection.hasTorrentActivityRequiringActivePolling)

        _ = projection.apply(
            upserted: [torrent(id: 3, name: "Checking", status: .checking)],
            removedIDs: [],
            filters: filters,
            sortOrder: sortOrder,
            filterEngine: filterEngine
        )
        XCTAssertTrue(projection.hasTorrentActivityRequiringActivePolling)

        _ = projection.apply(
            upserted: [],
            removedIDs: [3],
            filters: filters,
            sortOrder: sortOrder,
            filterEngine: filterEngine
        )
        XCTAssertFalse(projection.hasTorrentActivityRequiringActivePolling)
    }

    func testSummaryReusesProjectionTotalsForSelectionAndSessionChanges() {
        let projection = TorrentListProjection(
            torrents: [
                torrent(id: 1, name: "One", size: 100, rateDownload: 10, rateUpload: 20),
                torrent(id: 2, name: "Two", size: 200, rateDownload: 30, rateUpload: 40),
                torrent(id: 3, name: "Three", status: .stopped, size: 300)
            ],
            filters: TorrentFilters(statuses: [.downloading]),
            sortOrder: TorrentSorting.defaultSortOrder
        )

        let fallback = projection.makeSummary(selectedIDs: [2, 404], sessionStats: nil, sessionInfo: nil)
        XCTAssertEqual(fallback.filteredCount, 2)
        XCTAssertEqual(fallback.totalCount, 3)
        XCTAssertEqual(fallback.filteredSize, 300)
        XCTAssertEqual(fallback.selectedCount, 1)
        XCTAssertEqual(fallback.selectedSize, 200)
        XCTAssertEqual(fallback.downloadSpeed, 40)
        XCTAssertEqual(fallback.uploadSpeed, 60)

        let stats = SessionStats(arguments: [
            "downloadSpeed": .int(777),
            "uploadSpeed": .int(333)
        ])
        let session = SessionInfo(arguments: [
            "rpc-version": .int(18),
            "download-dir-free-space": .int(9_999)
        ])
        let updated = projection.makeSummary(selectedIDs: [1, 2], sessionStats: stats, sessionInfo: session)
        XCTAssertEqual(updated.selectedCount, 2)
        XCTAssertEqual(updated.selectedSize, 300)
        XCTAssertEqual(updated.downloadSpeed, 777)
        XCTAssertEqual(updated.uploadSpeed, 333)
        XCTAssertEqual(updated.freeSpace, 9_999)
    }

    func testIncrementalChangesPreserveSortFilterCountsAndIndexes() {
        let filters = TorrentFilters(statuses: [.downloading])
        let sortOrder = [KeyPathComparator(\TorrentSummary.rateDownload, order: .reverse)]
        let filterEngine = TorrentFilterEngine()
        var projection = TorrentListProjection(
            torrents: [
                torrent(id: 1, name: "One", rateDownload: 10, path: "/a"),
                torrent(id: 2, name: "Two", rateDownload: 20, path: "/a"),
                torrent(id: 3, name: "Three", rateDownload: 30, path: "/b"),
            ],
            filters: filters,
            sortOrder: sortOrder,
            filterEngine: filterEngine
        )

        let changed = projection.apply(
            upserted: [torrent(id: 1, name: "One", rateDownload: 40, path: "/c")],
            removedIDs: [],
            filters: filters,
            sortOrder: sortOrder,
            filterEngine: filterEngine
        )
        XCTAssertEqual(changed.evaluatedRowCount, 1)
        XCTAssertEqual(changed.authoritativeRowMutationCount, 1)
        XCTAssertEqual(changed.visibleIndexRebuildCount, 1)
        XCTAssertEqual(changed.sourceIndexRebuildCount, 0)
        XCTAssertTrue(changed.visibleRowsChanged)
        XCTAssertTrue(changed.filterCountsChanged)
        XCTAssertEqual(projection.visibleRows.map(\.id), [1, 3, 2])
        XCTAssertEqual(projection.filterCounts.paths, [
            TorrentFilterCount(value: "/a", count: 1),
            TorrentFilterCount(value: "/b", count: 1),
            TorrentFilterCount(value: "/c", count: 1),
        ])

        let filteredOut = projection.apply(
            upserted: [torrent(id: 2, name: "Two", status: .stopped, rateDownload: 0, path: "/a")],
            removedIDs: [3],
            filters: filters,
            sortOrder: sortOrder,
            filterEngine: filterEngine
        )
        XCTAssertEqual(filteredOut.evaluatedRowCount, 2)
        XCTAssertEqual(filteredOut.authoritativeRowMutationCount, 2)
        XCTAssertEqual(filteredOut.visibleIndexRebuildCount, 1)
        XCTAssertEqual(filteredOut.sourceIndexRebuildCount, 1)
        XCTAssertEqual(projection.visibleRows.map(\.id), [1])
        XCTAssertEqual(projection.visibleIDs, [1])
        XCTAssertEqual(projection.filterCounts.statuses[.all], 2)
        XCTAssertEqual(projection.filterCounts.statuses[.downloading], 1)
        XCTAssertEqual(projection.filterCounts.paths, [
            TorrentFilterCount(value: "/a", count: 1),
            TorrentFilterCount(value: "/c", count: 1),
        ])
        XCTAssertNil(projection.row(for: 3))
    }

    func testRatesAndBytesOnlyBatchDoesNotMutateOneThousandDistinctFacets() {
        let initial = (0..<1_000).map { id in
            var row = torrent(
                id: id,
                name: "Torrent \(id)",
                size: 1_000,
                rateDownload: 1,
                path: "/downloads/\(id)",
                tracker: "tracker-\(id).example"
            )
            row.labels = ["label-\(id)"]
            return row
        }
        let updated = initial.map { row in
            var row = row
            row.rateDownload = 2
            row.rateUpload = 3
            row.downloadedEver = 100
            row.uploadedEver = 200
            return row
        }
        let engine = TorrentFilterEngine()
        var projection = TorrentListProjection(
            torrents: initial,
            filters: .empty,
            sortOrder: TorrentSorting.defaultSortOrder
        )
        let counts = projection.filterCounts

        let changes = projection.apply(
            upserted: updated,
            removedIDs: [],
            filters: .empty,
            sortOrder: TorrentSorting.defaultSortOrder,
            filterEngine: engine
        )

        XCTAssertEqual(changes.evaluatedRowCount, 1_000)
        XCTAssertEqual(changes.pathCountMutationCount, 0)
        XCTAssertEqual(changes.trackerCountMutationCount, 0)
        XCTAssertEqual(changes.labelCountMutationCount, 0)
        XCTAssertFalse(changes.filterCountsChanged)
        XCTAssertEqual(projection.filterCounts, counts)
        XCTAssertEqual(projection.row(for: 999)?.downloadedEver, 100)
        let summary = projection.makeSummary(selectedIDs: [], sessionStats: nil, sessionInfo: nil)
        XCTAssertEqual(summary.downloadSpeed, 2_000)
        XCTAssertEqual(summary.uploadSpeed, 3_000)
    }

    func testRatesOnlyActivityTransitionStillUpdatesStatusCountsAndVisibility() {
        let initial = torrent(id: 1, name: "One", size: .max)
        var updated = initial
        updated.rateDownload = 1
        let filters = TorrentFilters(statuses: [.active])
        var projection = TorrentListProjection(
            torrents: [initial],
            filters: filters,
            sortOrder: TorrentSorting.defaultSortOrder
        )

        let changes = projection.apply(
            upserted: [updated],
            removedIDs: [],
            filters: filters,
            sortOrder: TorrentSorting.defaultSortOrder,
            filterEngine: TorrentFilterEngine()
        )

        XCTAssertEqual(changes.pathCountMutationCount, 0)
        XCTAssertEqual(changes.trackerCountMutationCount, 0)
        XCTAssertEqual(changes.labelCountMutationCount, 0)
        XCTAssertTrue(changes.filterCountsChanged)
        XCTAssertEqual(projection.filterCounts.statuses[.active], 1)
        XCTAssertEqual(projection.filterCounts.statuses[.inactive], 0)
        XCTAssertEqual(projection.visibleRows.map(\.id), [1])
        XCTAssertEqual(
            projection.makeSummary(selectedIDs: [1], sessionStats: nil, sessionInfo: nil).filteredSize,
            .max
        )
    }

    func testBatchFacetSwapAppliesNoNetCountMutationsButUpdatesLabelMatching() {
        var first = torrent(id: 1, name: "One", path: "/a", tracker: "a.example")
        first.labels = ["linux", "iso", "linux", ""]
        var second = torrent(id: 2, name: "Two", path: "/b", tracker: "b.example")
        second.labels = ["movie"]
        var changedFirst = first
        changedFirst.downloadDir = second.downloadDir
        changedFirst.trackerHost = second.trackerHost
        changedFirst.labels = second.labels
        var changedSecond = second
        changedSecond.downloadDir = first.downloadDir
        changedSecond.trackerHost = first.trackerHost
        changedSecond.labels = first.labels
        let filters = TorrentFilters(labels: ["ux, is"])
        var projection = TorrentListProjection(
            torrents: [first, second],
            filters: filters,
            sortOrder: TorrentSorting.defaultSortOrder
        )
        let counts = projection.filterCounts
        XCTAssertEqual(projection.visibleRows.map(\.id), [1])

        let changes = projection.apply(
            upserted: [changedFirst, changedSecond],
            removedIDs: [],
            filters: filters,
            sortOrder: TorrentSorting.defaultSortOrder,
            filterEngine: TorrentFilterEngine()
        )

        XCTAssertEqual(changes.pathCountMutationCount, 0)
        XCTAssertEqual(changes.trackerCountMutationCount, 0)
        XCTAssertEqual(changes.labelCountMutationCount, 0)
        XCTAssertEqual(projection.filterCounts, counts)
        XCTAssertEqual(projection.visibleRows.map(\.id), [2])
    }

    func testFacetChangesRemovalAndInsertionMatchFullRebuildIncludingDuplicateLabels() {
        var first = torrent(id: 1, name: "One", path: "/one")
        first.labels = ["shared", "duplicate", "duplicate", "", "A"]
        var second = torrent(id: 2, name: "Two", path: "/two")
        second.labels = ["shared", "a"]
        var updated = first
        updated.downloadDir = "/renamed"
        updated.trackerHost = ""
        updated.labels = ["shared", "duplicate", "a"]
        updated.status = .seeding
        var added = torrent(id: 3, name: "Three", status: .downloadWait, path: "/three", tracker: "new.example")
        added.labels = ["new"]
        added.errorString = "Tracker unavailable"
        let engine = TorrentFilterEngine()
        var projection = TorrentListProjection(
            torrents: [first, second],
            filters: .empty,
            sortOrder: TorrentSorting.defaultSortOrder
        )

        let changes = projection.apply(
            upserted: [updated, added],
            removedIDs: [2, 2, 404],
            filters: .empty,
            sortOrder: TorrentSorting.defaultSortOrder,
            filterEngine: engine
        )
        let rebuilt = TorrentListProjection(
            torrents: [updated, added],
            filters: .empty,
            sortOrder: TorrentSorting.defaultSortOrder
        )

        XCTAssertEqual(changes.pathCountMutationCount, 4)
        XCTAssertEqual(changes.trackerCountMutationCount, 2)
        XCTAssertEqual(changes.labelCountMutationCount, 4)
        XCTAssertEqual(projection.filterCounts, rebuilt.filterCounts)
        XCTAssertEqual(projection.visibleRows, rebuilt.visibleRows)
        XCTAssertEqual(projection.filterCounts.statuses[.done], 1)
        XCTAssertEqual(projection.filterCounts.statuses[.waiting], 1)
        XCTAssertEqual(projection.filterCounts.statuses[.error], 1)
    }

    private func torrent(
        id: Int,
        name: String,
        status: TorrentStatus = .downloading,
        size: Int64 = 0,
        rateDownload: Int64 = 0,
        rateUpload: Int64 = 0,
        path: String = "/downloads",
        tracker: String = "tracker.example"
    ) -> TorrentSummary {
        TorrentSummary(
            id: id,
            name: name,
            status: status,
            errorString: "",
            trackerError: "",
            globalError: "",
            trackerStatus: "",
            percentDone: status == .stopped ? 1 : 0.5,
            totalSize: size,
            sizeWhenDone: size,
            sizeToDownload: size,
            leftUntilDone: status == .stopped ? 0 : size / 2,
            rateDownload: rateDownload,
            rateUpload: rateUpload,
            eta: -1,
            uploadRatio: 0,
            downloadedEver: 0,
            uploadedEver: 0,
            downloadDir: path,
            bandwidthPriority: 0,
            queuePosition: 0,
            secondsSeeding: 0,
            isPrivate: false,
            isMetadataComplete: true,
            seedsConnected: 0,
            seedsTotal: 0,
            peersConnected: 0,
            peersTotal: 0,
            labels: [],
            trackerHost: tracker,
            addedDate: nil,
            completedDate: nil,
            activityDate: nil
        )
    }
}

@MainActor
final class AppStoreTorrentListProjectionTests: XCTestCase {
    func testStoreInvalidatesProjectionOnlyForListDependenciesAndPrunesSelection() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "AppStoreTorrentListProjectionTests.\(UUID().uuidString)"))
        let profileStore = ConnectionProfileStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("projection-\(UUID().uuidString).json"),
            passwordStore: ProjectionTestPasswordStore()
        )
        let store = AppStore(
            profileStore: profileStore,
            userDefaults: defaults,
            downloadCompletionNotifier: ProjectionTestDownloadCompletionNotifier()
        )
        store.torrents = [
            projectionTorrent(id: 2, name: "Beta", size: 200),
            projectionTorrent(id: 1, name: "Alpha", size: 100)
        ]

        XCTAssertEqual(store.visibleTorrents.map(\.id), [1, 2])
        XCTAssertEqual(store.torrentListSummary.filteredSize, 300)

        store.selectedTorrentIDs = [2]
        XCTAssertEqual(store.torrentListSummary.selectedSize, 200)
        store.sessionStats = SessionStats(arguments: ["downloadSpeed": .int(123)])
        XCTAssertEqual(store.torrentListSummary.downloadSpeed, 123)
        XCTAssertEqual(store.visibleTorrents.map(\.id), [1, 2])

        store.filterText = "Alpha"
        XCTAssertEqual(store.visibleTorrents.map(\.id), [1])
        XCTAssertTrue(store.selectedTorrentIDs.isEmpty)
        XCTAssertEqual(store.torrentListSummary.selectedCount, 0)

        store.filterText = ""
        store.torrentSortOrder = [KeyPathComparator(\TorrentSummary.name, order: .reverse)]
        XCTAssertEqual(store.visibleTorrents.map(\.id), [2, 1])
    }

    private func projectionTorrent(id: Int, name: String, size: Int64) -> TorrentSummary {
        TorrentSummary(
            id: id,
            name: name,
            status: .downloading,
            errorString: "",
            trackerError: "",
            globalError: "",
            trackerStatus: "",
            percentDone: 0.5,
            totalSize: size,
            sizeWhenDone: size,
            sizeToDownload: size,
            leftUntilDone: size / 2,
            rateDownload: 0,
            rateUpload: 0,
            eta: -1,
            uploadRatio: 0,
            downloadedEver: 0,
            uploadedEver: 0,
            downloadDir: "/downloads",
            bandwidthPriority: 0,
            queuePosition: 0,
            secondsSeeding: 0,
            isPrivate: false,
            isMetadataComplete: true,
            seedsConnected: 0,
            seedsTotal: 0,
            peersConnected: 0,
            peersTotal: 0,
            labels: [],
            trackerHost: "tracker.example",
            addedDate: nil,
            completedDate: nil,
            activityDate: nil
        )
    }
}

private final class ProjectionTestPasswordStore: ConnectionPasswordStoring {
    func password(for profileID: UUID) throws -> String? { nil }
    func setPassword(_ password: String, for profileID: UUID) throws {}
    func removePassword(for profileID: UUID) throws {}
}

private struct ProjectionTestDownloadCompletionNotifier: DownloadCompletionNotifying {
    func notifyDownloadCompleted(torrentName: String) {}
}
