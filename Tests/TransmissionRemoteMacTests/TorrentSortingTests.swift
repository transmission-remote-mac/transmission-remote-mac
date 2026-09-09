// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import XCTest
@testable import TransmissionRemoteMac

final class TorrentSortingTests: XCTestCase {
    func testDefaultSortsByNameWithIDTieBreak() {
        let torrents = [
            torrent(id: 3, name: "Zulu"),
            torrent(id: 2, name: "Alpha"),
            torrent(id: 1, name: "Alpha")
        ]

        let sorted = TorrentSorting.sorted(torrents, using: TorrentSorting.defaultSortOrder)

        XCTAssertEqual(sorted.map(\.id), [1, 2, 3])
    }

    func testColumnSortsUseRequestedOrderAndIDTieBreak() {
        let torrents = [
            torrent(id: 4, name: "Slow", rateDownload: 10),
            torrent(id: 2, name: "Fast B", rateDownload: 30),
            torrent(id: 1, name: "Fast A", rateDownload: 30)
        ]

        let sorted = TorrentSorting.sorted(
            torrents,
            using: [KeyPathComparator(\TorrentSummary.rateDownload, order: .reverse)]
        )

        XCTAssertEqual(sorted.map(\.id), [1, 2, 4])
    }

    func testEmptySortFallsBackToDefaultSort() {
        let torrents = [
            torrent(id: 2, name: "Beta"),
            torrent(id: 1, name: "Alpha")
        ]

        let sorted = TorrentSorting.sorted(torrents, using: [])

        XCTAssertEqual(sorted.map(\.id), [1, 2])
    }

    private func torrent(
        id: Int,
        name: String,
        status: TorrentStatus = .stopped,
        percentDone: Double = 0,
        rateDownload: Int64 = 0,
        rateUpload: Int64 = 0,
        eta: Int = -1,
        uploadRatio: Double = 0,
        trackerHost: String = "tracker.example"
    ) -> TorrentSummary {
        TorrentSummary(
            id: id,
            name: name,
            status: status,
            errorString: "",
            trackerError: "",
            globalError: "",
            trackerStatus: "",
            percentDone: percentDone,
            totalSize: 0,
            sizeWhenDone: 0,
            sizeToDownload: 0,
            leftUntilDone: 0,
            rateDownload: rateDownload,
            rateUpload: rateUpload,
            eta: eta,
            uploadRatio: uploadRatio,
            downloadedEver: 0,
            uploadedEver: 0,
            downloadDir: "",
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
            trackerHost: trackerHost,
            addedDate: nil,
            completedDate: nil,
            activityDate: nil
        )
    }
}
