// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import XCTest
@testable import TransmissionRemoteMac

final class TorrentMapperTests: XCTestCase {
    func testMapsLegacyBitmaskStatusesBeforeRPC14() {
        XCTAssertEqual(TorrentStatus.mapped(rawStatus: 1, rpcVersion: 13), .checkWait)
        XCTAssertEqual(TorrentStatus.mapped(rawStatus: 2, rpcVersion: 13), .checking)
        XCTAssertEqual(TorrentStatus.mapped(rawStatus: 4, rpcVersion: 13), .downloading)
        XCTAssertEqual(TorrentStatus.mapped(rawStatus: 8, rpcVersion: 13), .seeding)
        XCTAssertEqual(TorrentStatus.mapped(rawStatus: 16, rpcVersion: 13), .stopped)
    }

    func testMapsModernStatusesFromRPC14() {
        XCTAssertEqual(TorrentStatus.mapped(rawStatus: 0, rpcVersion: 14), .stopped)
        XCTAssertEqual(TorrentStatus.mapped(rawStatus: 1, rpcVersion: 14), .checkWait)
        XCTAssertEqual(TorrentStatus.mapped(rawStatus: 2, rpcVersion: 14), .checking)
        XCTAssertEqual(TorrentStatus.mapped(rawStatus: 3, rpcVersion: 14), .downloadWait)
        XCTAssertEqual(TorrentStatus.mapped(rawStatus: 4, rpcVersion: 14), .downloading)
        XCTAssertEqual(TorrentStatus.mapped(rawStatus: 5, rpcVersion: 14), .seedWait)
        XCTAssertEqual(TorrentStatus.mapped(rawStatus: 6, rpcVersion: 14), .seeding)
    }

    func testDonePercentUsesRecheckProgressWhileChecking() {
        let summary = TorrentMapper.map(torrent([
            "id": .int(1),
            "name": .string("Checking"),
            "status": .int(2),
            "recheckProgress": .double(0.42),
            "sizeWhenDone": .int(100),
            "leftUntilDone": .int(90)
        ]), rpcVersion: 14)

        XCTAssertEqual(summary.status, .checking)
        XCTAssertEqual(summary.percentDone, 0.42, accuracy: 0.0001)
    }

    func testDonePercentUsesSizeAndLeftAndMarksFinishedStoppedTorrent() {
        let summary = TorrentMapper.map(torrent([
            "id": .int(2),
            "name": .string("Complete"),
            "status": .int(0),
            "sizeWhenDone": .int(1_000),
            "leftUntilDone": .int(0)
        ]), rpcVersion: 14)

        XCTAssertEqual(summary.status, .finished)
        XCTAssertEqual(summary.percentDone, 1.0, accuracy: 0.0001)
        XCTAssertEqual(summary.totalSize, summary.sizeWhenDone)
    }

    func testStoppedIncompleteTorrentStaysStopped() {
        let summary = TorrentMapper.map(torrent([
            "id": .int(3),
            "name": .string("Partial"),
            "status": .int(0),
            "sizeWhenDone": .int(1_000),
            "leftUntilDone": .int(250)
        ]), rpcVersion: 14)

        XCTAssertEqual(summary.status, .stopped)
        XCTAssertEqual(summary.percentDone, 0.75, accuracy: 0.0001)
    }

    func testMetadataIncompleteMakesSizesUnknown() {
        let summary = TorrentMapper.map(torrent([
            "id": .int(4),
            "name": .string("Magnet"),
            "status": .int(4),
            "metadataPercentComplete": .double(0.5),
            "totalSize": .int(10_000),
            "sizeWhenDone": .int(10_000),
            "leftUntilDone": .int(9_000)
        ]), rpcVersion: 17)

        XCTAssertFalse(summary.isMetadataComplete)
        XCTAssertEqual(summary.totalSize, TorrentMapper.unknownSize)
        XCTAssertEqual(summary.sizeToDownload, TorrentMapper.unknownSize)
    }

    func testETARecomputesFromDownloadRateAndDefaultsToUnknown() {
        let summary = TorrentMapper.map(torrent([
            "id": .int(5),
            "name": .string("ETA"),
            "status": .int(4),
            "leftUntilDone": .int(600),
            "rateDownload": .int(20),
            "eta": .int(-1)
        ]), rpcVersion: 14)
        let unknown = TorrentMapper.map(torrent([
            "id": .int(6),
            "name": .string("No ETA"),
            "status": .int(4),
            "eta": .int(-1)
        ]), rpcVersion: 14)

        XCTAssertEqual(summary.eta, 30)
        XCTAssertEqual(unknown.eta, TorrentMapper.unknownETA)
    }

    func testRatioDefaultsAndInfinity() {
        let infinite = TorrentMapper.map(torrent([
            "id": .int(7),
            "name": .string("Ratio"),
            "status": .int(6),
            "uploadRatio": .double(-2)
        ]), rpcVersion: 14)
        let missing = TorrentMapper.map(torrent([
            "id": .int(8),
            "name": .string("Missing Ratio"),
            "status": .int(6)
        ]), rpcVersion: 14)

        XCTAssertTrue(infinite.uploadRatio.isInfinite)
        XCTAssertEqual(missing.uploadRatio, 0)
    }

    func testTrackerStatsErrorSuppressesDuplicateGlobalError() {
        let summary = TorrentMapper.map(torrent([
            "id": .int(9),
            "name": .string("Tracker Error"),
            "status": .int(4),
            "errorString": .string("Connection timed out"),
            "trackerStats": .array([
                .object([
                    "announce": .string("https://tracker.example.test/announce"),
                    "hasAnnounced": .bool(true),
                    "lastAnnounceSucceeded": .bool(false),
                    "lastAnnounceResult": .string("Connection timed out")
                ])
            ])
        ]), rpcVersion: 17)

        XCTAssertEqual(summary.trackerError, "Tracker error: Connection timed out")
        XCTAssertEqual(summary.globalError, "")
        XCTAssertEqual(summary.errorString, "Tracker error: Connection timed out")
        XCTAssertEqual(summary.trackerHost, "example.test")
    }

    func testWorkingTrackerClearsTrackerErrorButKeepsGlobalError() {
        let summary = TorrentMapper.map(torrent([
            "id": .int(10),
            "name": .string("Global Error"),
            "status": .int(4),
            "errorString": .string("Permission denied"),
            "trackerStats": .array([
                .object([
                    "announce": .string("https://tracker.example.test/announce"),
                    "hasAnnounced": .bool(true),
                    "lastAnnounceSucceeded": .bool(true),
                    "lastAnnounceResult": .string("Success")
                ])
            ])
        ]), rpcVersion: 17)

        XCTAssertEqual(summary.trackerError, "")
        XCTAssertEqual(summary.globalError, "Permission denied")
        XCTAssertEqual(summary.errorString, "Permission denied")
        XCTAssertEqual(summary.trackerStatus, "Working")
    }

    func testLegacyAnnounceErrorAndTrackerDisplay() {
        let summary = TorrentMapper.map(torrent([
            "id": .int(11),
            "name": .string("Legacy"),
            "status": .int(4),
            "announceResponse": .string("Not Found (404)"),
            "trackers": .array([
                .object(["announce": .string("http://bt1.legacy.example/announce")])
            ])
        ]), rpcVersion: 13)

        XCTAssertEqual(summary.status, .downloading)
        XCTAssertEqual(summary.errorString, "Tracker error: Not Found")
        XCTAssertEqual(summary.trackerHost, "legacy.example")
    }

    private func torrent(_ json: RPCArguments) -> TorrentGetTorrent {
        TorrentGetTorrent(json: json)
    }
}
