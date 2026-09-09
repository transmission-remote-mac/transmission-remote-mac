// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import XCTest
@testable import TransmissionRemoteMac

final class TorrentMapperPartialMergeTests: XCTestCase {
    func testPartialMergePreservesFieldsAbsentFromRefresh() {
        let existing = TorrentMapper.map(TorrentGetTorrent(json: [
            "id": .int(7),
            "name": .string("Existing"),
            "hashString": .string(String(repeating: "a", count: 40)),
            "status": .int(TorrentStatus.downloading.rawValue),
            "totalSize": .int(2_048),
            "sizeWhenDone": .int(2_048),
            "leftUntilDone": .int(1_024),
            "rateDownload": .int(100),
            "rateUpload": .int(50),
            "downloadDir": .string("/preserved/path"),
            "labels": .array([.string("preserved-label")]),
            "addedDate": .int(1_700_000_000),
        ]), rpcVersion: 18)

        let merged = TorrentMapper.merging(
            TorrentGetTorrent(json: [
                "id": .int(7),
                "rateDownload": .int(4_096),
            ]),
            into: existing,
            rpcVersion: 18
        )

        XCTAssertEqual(merged.rateDownload, 4_096)
        XCTAssertEqual(merged.name, existing.name)
        XCTAssertEqual(merged.hashString, existing.hashString)
        XCTAssertEqual(merged.totalSize, existing.totalSize)
        XCTAssertEqual(merged.downloadDir, existing.downloadDir)
        XCTAssertEqual(merged.labels, existing.labels)
        XCTAssertEqual(merged.addedDate, existing.addedDate)
    }

    func testDynamicMergeUpdatesDerivedStateWithoutDiscardingStaticState() {
        let existing = TorrentMapper.map(TorrentGetTorrent(json: [
            "id": .int(7),
            "name": .string("Existing"),
            "hashString": .string(String(repeating: "b", count: 40)),
            "status": .int(TorrentStatus.downloading.rawValue),
            "totalSize": .int(2_048),
            "sizeWhenDone": .int(2_048),
            "leftUntilDone": .int(1_024),
            "downloadDir": .string("/preserved/path"),
            "labels": .array([.string("preserved-label")]),
            "trackerStats": .array([.object([
                "announce": .string("https://old.example/announce"),
                "hasAnnounced": .bool(true),
                "lastAnnounceSucceeded": .bool(true),
                "seederCount": .int(10),
                "leecherCount": .int(20),
            ])]),
        ]), rpcVersion: 18)

        let merged = TorrentMapper.merging(
            TorrentGetTorrent(json: [
                "id": .int(7),
                "name": .string("Updated"),
                "hashString": .string(String(repeating: "b", count: 40)),
                "status": .int(TorrentStatus.seeding.rawValue),
                "metadataPercentComplete": .double(1),
                "percentDone": .double(1),
                "recheckProgress": .double(0),
                "totalSize": .int(2_048),
                "sizeWhenDone": .int(2_048),
                "leftUntilDone": .int(0),
                "rateDownload": .int(0),
                "rateUpload": .int(256),
                "errorString": .string(""),
                "trackerStats": .array([.object([
                    "announce": .string("https://new.example/announce"),
                    "hasAnnounced": .bool(true),
                    "lastAnnounceSucceeded": .bool(false),
                    "lastAnnounceResult": .string("Unavailable"),
                    "seederCount": .int(30),
                    "leecherCount": .int(40),
                ])]),
            ]),
            into: existing,
            rpcVersion: 18
        )

        XCTAssertEqual(merged.name, "Updated")
        XCTAssertEqual(merged.status, .seeding)
        XCTAssertEqual(merged.percentDone, 1)
        XCTAssertEqual(merged.rateUpload, 256)
        XCTAssertEqual(merged.trackerHost, "new.example")
        XCTAssertEqual(merged.trackerError, "Tracker error: Unavailable")
        XCTAssertEqual(merged.seedsTotal, 30)
        XCTAssertEqual(merged.peersTotal, 40)
        XCTAssertEqual(merged.downloadDir, existing.downloadDir)
        XCTAssertEqual(merged.labels, existing.labels)
    }

    func testTableBackedDynamicMergeUpdatesRowsAndPreservesOmittedStaticFields() throws {
        let hash = String(repeating: "a", count: 40)
        let existing = TorrentMapper.map(TorrentGetTorrent(json: [
            "id": .int(7),
            "name": .string("Existing"),
            "hashString": .string(hash),
            "status": .int(TorrentStatus.downloading.rawValue),
            "sizeWhenDone": .int(2_000),
            "leftUntilDone": .int(1_000),
            "downloadDir": .string("/preserved/path"),
            "labels": .array([.string("preserved-label")]),
        ]), rpcVersion: 18)
        let response = try TorrentGetResponse(validating: [
            "fields": .array([
                .string("id"),
                .string("hashString"),
                .string("status"),
                .string("percentDone"),
                .string("sizeWhenDone"),
                .string("leftUntilDone"),
                .string("rateDownload"),
            ]),
            "torrents": .array([.array([
                .int(7),
                .string(hash),
                .int(TorrentStatus.downloading.rawValue),
                .double(0.75),
                .int(2_000),
                .int(500),
                .int(4_096),
            ])]),
        ])
        let refreshed = try XCTUnwrap(response.torrents.first)

        let merged = TorrentMapper.merging(refreshed, into: existing, rpcVersion: 18)

        XCTAssertEqual(merged.percentDone, 0.75, accuracy: 0.0001)
        XCTAssertEqual(merged.rateDownload, 4_096)
        XCTAssertEqual(merged.downloadDir, "/preserved/path")
        XCTAssertEqual(merged.labels, ["preserved-label"])
    }

    func testRateStoppingWithoutETAFieldClearsPreviouslyDerivedETA() {
        let existing = TorrentMapper.map(TorrentGetTorrent(json: [
            "id": .int(7),
            "status": .int(TorrentStatus.downloading.rawValue),
            "sizeWhenDone": .int(2_000),
            "leftUntilDone": .int(1_000),
            "rateDownload": .int(100),
        ]), rpcVersion: 18)
        XCTAssertEqual(existing.eta, 10)

        let merged = TorrentMapper.merging(
            TorrentGetTorrent(json: [
                "id": .int(7),
                "rateDownload": .int(0),
            ]),
            into: existing,
            rpcVersion: 18
        )

        XCTAssertEqual(merged.eta, TorrentMapper.unknownETA)
    }

    func testCheckingMergeFallsBackToPercentDoneWhenRecheckProgressIsAbsent() {
        let existing = TorrentMapper.map(TorrentGetTorrent(json: [
            "id": .int(7),
            "status": .int(TorrentStatus.downloading.rawValue),
            "percentDone": .double(0.25),
            "sizeWhenDone": .int(1_000),
            "leftUntilDone": .int(750),
        ]), rpcVersion: 18)

        let merged = TorrentMapper.merging(
            TorrentGetTorrent(json: [
                "id": .int(7),
                "status": .int(TorrentStatus.checking.rawValue),
                "percentDone": .double(0.6),
            ]),
            into: existing,
            rpcVersion: 18
        )

        XCTAssertEqual(merged.status, .checking)
        XCTAssertEqual(merged.percentDone, 0.6, accuracy: 0.0001)
    }

    func testMetadataCompletionWithoutSizesKeepsUnknownSize() {
        let existing = TorrentMapper.map(TorrentGetTorrent(json: [
            "id": .int(7),
            "metadataPercentComplete": .double(0.5),
        ]), rpcVersion: 18)
        XCTAssertEqual(existing.sizeWhenDone, TorrentMapper.unknownSize)

        let merged = TorrentMapper.merging(
            TorrentGetTorrent(json: [
                "id": .int(7),
                "metadataPercentComplete": .double(1),
            ]),
            into: existing,
            rpcVersion: 18
        )

        XCTAssertTrue(merged.isMetadataComplete)
        XCTAssertEqual(merged.sizeWhenDone, TorrentMapper.unknownSize)
        XCTAssertEqual(merged.sizeToDownload, TorrentMapper.unknownSize)
        XCTAssertEqual(merged.totalSize, TorrentMapper.unknownSize)
    }

    func testErrorOnlyMergePreservesExistingTrackerFailure() {
        let existing = TorrentMapper.map(TorrentGetTorrent(json: [
            "id": .int(7),
            "status": .int(TorrentStatus.downloading.rawValue),
            "errorString": .string("Disk full"),
            "trackerStats": .array([.object([
                "hasAnnounced": .bool(true),
                "lastAnnounceSucceeded": .bool(false),
                "lastAnnounceResult": .string("Unavailable"),
            ])]),
        ]), rpcVersion: 18)

        let merged = TorrentMapper.merging(
            TorrentGetTorrent(json: [
                "id": .int(7),
                "errorString": .string("Permission denied"),
            ]),
            into: existing,
            rpcVersion: 18
        )

        XCTAssertEqual(merged.trackerError, existing.trackerError)
        XCTAssertEqual(merged.globalError, "Permission denied")
        XCTAssertEqual(merged.errorString, existing.trackerError)
    }

    func testLegacyTrackerMetadataWithoutCountsPreservesKnownPeerTotals() {
        let existing = TorrentMapper.map(TorrentGetTorrent(json: [
            "id": .int(7),
            "seeders": .int(12),
            "leechers": .int(34),
        ]), rpcVersion: 6)

        let merged = TorrentMapper.merging(
            TorrentGetTorrent(json: [
                "id": .int(7),
                "trackers": .array([.object([
                    "announce": .string("https://tracker.example/announce"),
                ])]),
            ]),
            into: existing,
            rpcVersion: 6
        )

        XCTAssertEqual(merged.seedsTotal, 12)
        XCTAssertEqual(merged.peersTotal, 34)
        XCTAssertEqual(merged.trackerHost, "example")
    }

    func testPresentZeroDatesClearPreviouslyKnownDates() {
        let existing = TorrentMapper.map(TorrentGetTorrent(json: [
            "id": .int(7),
            "addedDate": .int(1_700_000_000),
            "doneDate": .int(1_700_000_100),
            "activityDate": .int(1_700_000_200),
        ]), rpcVersion: 18)

        let merged = TorrentMapper.merging(
            TorrentGetTorrent(json: [
                "id": .int(7),
                "addedDate": .int(0),
                "doneDate": .int(0),
                "activityDate": .int(0),
            ]),
            into: existing,
            rpcVersion: 18
        )

        XCTAssertNil(merged.addedDate)
        XCTAssertNil(merged.completedDate)
        XCTAssertNil(merged.activityDate)
    }
}
