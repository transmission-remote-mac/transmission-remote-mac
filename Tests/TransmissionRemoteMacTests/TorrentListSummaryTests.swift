// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import XCTest
@testable import TransmissionRemoteMac

final class TorrentListSummaryTests: XCTestCase {
    func testSummaryCountsSizesAndSpeedsUseVisibleSelectedAndSessionStats() {
        let torrents = [
            torrent(id: 1, sizeWhenDone: 1_000, rateDownload: 10, rateUpload: 20),
            torrent(id: 2, sizeWhenDone: 2_000, rateDownload: 30, rateUpload: 40),
            torrent(id: 3, sizeWhenDone: 3_000, rateDownload: 50, rateUpload: 60)
        ]
        let stats = SessionStats(arguments: [
            "downloadSpeed": .int(777),
            "uploadSpeed": .int(333)
        ])
        let session = SessionInfo(arguments: [
            "rpc-version": .int(17),
            "download-dir-free-space": .int(9_999)
        ])

        let summary = TorrentListSummary(
            visibleTorrents: Array(torrents.prefix(2)),
            totalTorrents: torrents,
            selectedIDs: [2, 3],
            sessionStats: stats,
            sessionInfo: session
        )

        XCTAssertEqual(summary.filteredCount, 2)
        XCTAssertEqual(summary.totalCount, 3)
        XCTAssertEqual(summary.selectedCount, 2)
        XCTAssertEqual(summary.filteredSize, 3_000)
        XCTAssertEqual(summary.selectedSize, 5_000)
        XCTAssertEqual(summary.downloadSpeed, 777)
        XCTAssertEqual(summary.uploadSpeed, 333)
        XCTAssertEqual(summary.freeSpace, 9_999)
        XCTAssertEqual(summary.countDisplay, "2 of 3 torrents")
        XCTAssertTrue(summary.selectedDisplay.contains("2 selected torrents"))
        XCTAssertTrue(summary.freeSpaceDisplay?.hasPrefix("Free: ") == true)
    }

    func testSummaryFallsBackToTorrentSpeedTotalsAndNoSelectionCopy() {
        let torrents = [
            torrent(id: 1, totalSize: 4_000, rateDownload: 10, rateUpload: 20),
            torrent(id: 2, sizeToDownload: 6_000, rateDownload: 30, rateUpload: 40)
        ]

        let summary = TorrentListSummary(
            visibleTorrents: torrents,
            totalTorrents: torrents,
            selectedIDs: [],
            sessionStats: nil,
            sessionInfo: nil
        )

        XCTAssertEqual(summary.filteredCount, 2)
        XCTAssertEqual(summary.totalCount, 2)
        XCTAssertEqual(summary.selectedCount, 0)
        XCTAssertEqual(summary.filteredSize, 10_000)
        XCTAssertEqual(summary.selectedSize, 0)
        XCTAssertEqual(summary.downloadSpeed, 40)
        XCTAssertEqual(summary.uploadSpeed, 60)
        XCTAssertEqual(summary.countDisplay, "2 torrents")
        XCTAssertEqual(summary.selectedDisplay, "No selection")
        XCTAssertNil(summary.freeSpaceDisplay)
    }

    func testIdleSummaryUsesDashRatesButPreservesKnownZeroFreeSpace() {
        let summary = TorrentListSummary(
            visibleTorrents: [],
            totalTorrents: [],
            selectedIDs: [],
            sessionStats: nil,
            sessionInfo: SessionInfo(arguments: [
                "rpc-version": .int(17),
                "download-dir-free-space": .int(0)
            ])
        )

        XCTAssertEqual(summary.speedDisplay, "↓ —  ↑ —")
        XCTAssertEqual(summary.freeSpace, 0)
        XCTAssertEqual(summary.freeSpaceDisplay, "Free: \(ByteCountFormatters.fileSize(0))")
        XCTAssertEqual(summary.filteredSizeDisplay, "Filtered: \(ByteCountFormatters.fileSize(0))")
        XCTAssertFalse(summary.freeSpaceDisplay?.contains("—") ?? true)
        XCTAssertFalse(summary.freeSpaceDisplay?.contains("Zero") ?? true)
        XCTAssertEqual(summary.countDisplay, "0 torrents")
    }

    private func torrent(
        id: Int,
        sizeWhenDone: Int64 = 0,
        totalSize: Int64 = 0,
        sizeToDownload: Int64 = 0,
        rateDownload: Int64 = 0,
        rateUpload: Int64 = 0
    ) -> TorrentSummary {
        TorrentSummary(
            id: id,
            name: "Torrent \(id)",
            status: .downloading,
            errorString: "",
            trackerError: "",
            globalError: "",
            trackerStatus: "",
            percentDone: 0.5,
            totalSize: totalSize,
            sizeWhenDone: sizeWhenDone,
            sizeToDownload: sizeToDownload,
            leftUntilDone: 0,
            rateDownload: rateDownload,
            rateUpload: rateUpload,
            eta: -1,
            uploadRatio: 0,
            downloadedEver: 0,
            uploadedEver: 0,
            downloadDir: "/srv/downloads",
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
