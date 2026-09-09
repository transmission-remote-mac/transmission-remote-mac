// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import XCTest
@testable import TransmissionRemoteMac

final class DownloadCompletionTrackerTests: XCTestCase {
    func testInitialRefreshDoesNotNotifyAlreadyCompleteTorrents() {
        var tracker = DownloadCompletionTracker()

        let transitions = tracker.transitions(afterRefreshing: [
            torrent(id: 1, name: "Already Done", status: .seeding, percentDone: 1, leftUntilDone: 0)
        ])

        XCTAssertTrue(transitions.isEmpty)
    }

    func testIncompleteToCompleteTransitionNotifiesOnce() {
        var tracker = DownloadCompletionTracker()

        XCTAssertTrue(tracker.transitions(afterRefreshing: [
            torrent(id: 1, name: "Ubuntu", status: .downloading, percentDone: 0.9, leftUntilDone: 100)
        ]).isEmpty)

        XCTAssertEqual(tracker.transitions(afterRefreshing: [
            torrent(id: 1, name: "Ubuntu", status: .seeding, percentDone: 1, leftUntilDone: 0)
        ]), [
            DownloadCompletionTransition(torrentID: 1, torrentName: "Ubuntu")
        ])

        XCTAssertTrue(tracker.transitions(afterRefreshing: [
            torrent(id: 1, name: "Ubuntu", status: .seeding, percentDone: 1, leftUntilDone: 0)
        ]).isEmpty)
    }

    func testStoppedDoneTransitionUsesProgressAndRemainingBytes() {
        var tracker = DownloadCompletionTracker()

        _ = tracker.transitions(afterRefreshing: [
            torrent(id: 2, name: "Archive", status: .downloading, percentDone: 0.5, leftUntilDone: 500)
        ])

        let transitions = tracker.transitions(afterRefreshing: [
            torrent(id: 2, name: "Archive", status: .stopped, percentDone: 1, leftUntilDone: 0)
        ])

        XCTAssertEqual(transitions, [
            DownloadCompletionTransition(torrentID: 2, torrentName: "Archive")
        ])
    }

    func testResetSuppressesAlreadyCompleteRowsAfterReconnect() {
        var tracker = DownloadCompletionTracker()

        _ = tracker.transitions(afterRefreshing: [
            torrent(id: 3, name: "Movie", status: .downloading, percentDone: 0.8, leftUntilDone: 200)
        ])
        tracker.reset()

        XCTAssertTrue(tracker.transitions(afterRefreshing: [
            torrent(id: 3, name: "Movie", status: .seeding, percentDone: 1, leftUntilDone: 0)
        ]).isEmpty)
    }

    private func torrent(
        id: Int,
        name: String,
        status: TorrentStatus,
        percentDone: Double,
        leftUntilDone: Int64
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
            totalSize: 1_000,
            sizeWhenDone: 1_000,
            sizeToDownload: 1_000,
            leftUntilDone: leftUntilDone,
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
            trackerHost: "tracker.example",
            addedDate: nil,
            completedDate: nil,
            activityDate: nil
        )
    }
}
