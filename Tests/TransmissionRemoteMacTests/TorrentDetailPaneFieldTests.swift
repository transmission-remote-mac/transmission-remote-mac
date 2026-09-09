// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import XCTest
@testable import TransmissionRemoteMac

final class TorrentDetailPaneFieldTests: XCTestCase {
    private let unversionedOverviewFields: Set<String> = [
        "activityDate",
        "addedDate",
        "bandwidthPriority",
        "comment",
        "corruptEver",
        "creator",
        "dateCreated",
        "desiredAvailable",
        "doneDate",
        "downloadDir",
        "downloadLimit",
        "downloadedEver",
        "error",
        "errorString",
        "eta",
        "hashString",
        "haveUnchecked",
        "haveValid",
        "id",
        "isPrivate",
        "leftUntilDone",
        "maxConnectedPeers",
        "peersGettingFromUs",
        "peersSendingToUs",
        "pieceCount",
        "pieceSize",
        "queuePosition",
        "rateDownload",
        "rateUpload",
        "secondsDownloading",
        "secondsSeeding",
        "sizeWhenDone",
        "status",
        "totalSize",
        "uploadLimit",
        "uploadRatio",
        "uploadedEver",
    ]

    private let legacyTrackerFields: Set<String> = [
        "announceResponse", "leechers", "nextAnnounceTime", "seeders", "trackers",
    ]

    func testOverviewFieldsUseExactRPC4LegacyLimitAndTrackerGates() {
        assertFields(
            .overview,
            rpcVersion: 4,
            expected: unversionedOverviewFields.union(legacyTrackerFields).union([
                "downloadLimitMode", "uploadLimitMode",
            ])
        )
    }

    func testOverviewFieldsUseExactRPC5AndRPC6Gates() {
        let expected = unversionedOverviewFields.union(legacyTrackerFields).union([
            "downloadLimited", "pieces", "uploadLimited",
        ])
        assertFields(.overview, rpcVersion: 5, expected: expected)
        assertFields(.overview, rpcVersion: 6, expected: expected)
    }

    func testRPC6UsesOnlyLegacyTrackerFields() {
        assertFields(
            .trackers,
            rpcVersion: 6,
            expected: ["hashString", "id", "nextAnnounceTime", "trackers"]
        )
    }

    func testOverviewFieldsUseExactRPC7Gates() {
        assertFields(
            .overview,
            rpcVersion: 7,
            expected: unversionedOverviewFields.union([
                "downloadLimited", "magnetLink", "metadataPercentComplete", "pieces",
                "trackerStats", "uploadLimited",
            ])
        )
    }

    func testRPC7UsesOnlyTrackerStats() {
        assertFields(.trackers, rpcVersion: 7, expected: ["hashString", "id", "trackerStats"])
    }

    func testOverviewFieldsUseExactRPC16AndRPC18Gates() {
        let expected = unversionedOverviewFields.union([
            "downloadLimited", "labels", "magnetLink", "metadataPercentComplete", "pieces",
            "trackerStats", "uploadLimited",
        ])
        assertFields(.overview, rpcVersion: 16, expected: expected)
        assertFields(.overview, rpcVersion: 18, expected: expected)
    }

    func testRPC17RetainsTheCurrentTrackerGenerationWithoutTrackerList() {
        assertFields(
            .overview,
            rpcVersion: 17,
            expected: unversionedOverviewFields.union([
                "downloadLimited", "labels", "magnetLink", "metadataPercentComplete", "pieces",
                "trackerStats", "uploadLimited",
            ])
        )
        assertFields(.trackers, rpcVersion: 17, expected: ["hashString", "id", "trackerStats"])
    }

    func testRPC18RetainsTheCurrentTrackerGenerationWithoutTrackerList() {
        assertFields(
            .overview,
            rpcVersion: 18,
            expected: unversionedOverviewFields.union([
                "downloadLimited", "labels", "magnetLink", "metadataPercentComplete", "pieces",
                "trackerStats", "uploadLimited",
            ])
        )
        assertFields(.trackers, rpcVersion: 18, expected: ["hashString", "id", "trackerStats"])
    }

    func testFilesAndPeersContractsIncludeIdentityAcrossRPCGenerations() {
        let files: Set<String> = [
            "downloadDir", "fileStats", "files", "hashString", "id", "priorities", "wanted",
        ]
        let peers: Set<String> = ["hashString", "id", "peers"]

        for rpcVersion in [6, 7, 17, 18] {
            assertFields(.files, rpcVersion: rpcVersion, expected: files)
            assertFields(.peers, rpcVersion: rpcVersion, expected: peers)
            assertFields(.statistics, rpcVersion: rpcVersion, expected: [])
        }
    }

    func testEveryRPCDetailPaneRequestsNumericAndCanonicalIdentity() {
        for rpcVersion in [4, 5, 6, 7, 17, 18] {
            for pane in [
                TorrentDetailPane.overview,
                .files,
                .peers,
                .trackers,
            ] {
                let fields = pane.rpcFields(rpcVersion: rpcVersion)

                XCTAssertTrue(fields.contains("id"), "Missing numeric identity for \(pane)")
                XCTAssertTrue(fields.contains("hashString"), "Missing canonical identity for \(pane)")
            }
        }
    }

    func testPiecesAreRequestedOnlyForRPC5AndNewerOverviewDetails() {
        XCTAssertFalse(TorrentDetailPane.overview.rpcFields(rpcVersion: 4).contains("pieces"))
        for rpcVersion in [5, 6, 7, 16, 18] {
            XCTAssertTrue(TorrentDetailPane.overview.rpcFields(rpcVersion: rpcVersion).contains("pieces"))
            for pane in [
                TorrentDetailPane.files,
                .peers,
                .trackers,
                .statistics,
            ] {
                XCTAssertFalse(pane.rpcFields(rpcVersion: rpcVersion).contains("pieces"))
            }
        }
    }

    private func assertFields(
        _ pane: TorrentDetailPane,
        rpcVersion: Int,
        expected: Set<String>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let fields = pane.rpcFields(rpcVersion: rpcVersion)

        XCTAssertEqual(fields, fields.sorted(), file: file, line: line)
        XCTAssertEqual(fields.count, Set(fields).count, file: file, line: line)
        XCTAssertEqual(Set(fields), expected, file: file, line: line)
        XCTAssertFalse(fields.contains("trackerList"), file: file, line: line)
        XCTAssertFalse(
            fields.contains("trackers") && fields.contains("trackerStats"),
            file: file,
            line: line
        )
    }
}
