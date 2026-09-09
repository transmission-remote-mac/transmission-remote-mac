// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import XCTest
@testable import TransmissionRemoteMac

final class TorrentSelectionCopyTextTests: XCTestCase {
    func testUsesVisibleDisplayOrderInsteadOfSelectionOrder() {
        let visibleTorrents = [
            torrent(id: 30, name: "Third"),
            torrent(id: 10, name: "First"),
            torrent(id: 20, name: "Second")
        ]

        let text = TorrentSelectionCopyText.make(
            visibleTorrents: visibleTorrents,
            selectedIDs: [10, 20, 30]
        )

        XCTAssertEqual(text, "Third\nFirst\nSecond")
    }

    func testRejectsSelectionOutsideFilteredVisibleResults() {
        let visibleTorrents = [
            torrent(id: 2, name: "Visible B"),
            torrent(id: 1, name: "Visible A")
        ]

        let text = TorrentSelectionCopyText.make(
            visibleTorrents: visibleTorrents,
            selectedIDs: [1, 2, 99]
        )

        XCTAssertNil(text)
    }

    func testEmptySelectionProducesNoCopyText() {
        let text = TorrentSelectionCopyText.make(
            visibleTorrents: [torrent(id: 1, name: "Ignored")],
            selectedIDs: []
        )

        XCTAssertNil(text)
    }

    func testFormattingUsesSingleNewlinesWithoutTrailingNewline() {
        let text = TorrentSelectionCopyText.make(
            visibleTorrents: [
                torrent(id: 1, name: "Alpha"),
                torrent(id: 2, name: "Beta")
            ],
            selectedIDs: [1, 2]
        )

        XCTAssertEqual(text, "Alpha\nBeta")
        XCTAssertFalse(text?.hasSuffix("\n") ?? true)
    }

    private func torrent(id: Int, name: String) -> TorrentSummary {
        TorrentSummary(
            id: id,
            name: name,
            status: .stopped,
            errorString: "",
            trackerError: "",
            globalError: "",
            trackerStatus: "",
            percentDone: 0,
            totalSize: 0,
            sizeWhenDone: 0,
            sizeToDownload: 0,
            leftUntilDone: 0,
            rateDownload: 0,
            rateUpload: 0,
            eta: -1,
            uploadRatio: 0,
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
            trackerHost: "",
            addedDate: nil,
            completedDate: nil,
            activityDate: nil
        )
    }
}
