// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation
import XCTest
@testable import TransmissionRemoteMac

final class TorrentGeneralInfoTests: XCTestCase {
    func testMissingTorrentCardFieldsRemainAbsent() throws {
        let info = try makeGeneralInfo([:])

        XCTAssertNil(info.metadataPercentComplete)
        XCTAssertNil(info.isMetadataComplete)
        XCTAssertNil(info.isPrivate)
        XCTAssertNil(info.labels)
        XCTAssertNil(info.totalSize)
        XCTAssertNil(info.sizeWhenDone)
        XCTAssertNil(info.leftUntilDone)
        XCTAssertNil(info.completedSize)
        XCTAssertNil(info.downloadDir)
        XCTAssertNil(info.fullPath(torrentName: "Example"))
        XCTAssertNil(info.addedDate)
        XCTAssertNil(info.completedDate)
        XCTAssertNil(info.activityDate)
        XCTAssertNil(info.downloadedEver)
        XCTAssertNil(info.uploadedEver)
        XCTAssertNil(info.corruptEver)
        XCTAssertNil(info.rateDownload)
        XCTAssertNil(info.rateUpload)
        XCTAssertNil(info.downloadSpeedLimit)
        XCTAssertNil(info.uploadSpeedLimit)
        XCTAssertNil(info.maxConnectedPeers)
        XCTAssertNil(info.eta)
        XCTAssertNil(info.uploadRatio)
        XCTAssertNil(info.bandwidthPriority)
        XCTAssertNil(info.queuePosition)
        XCTAssertNil(info.secondsSeeding)
        XCTAssertNil(info.trackerUpdate)
    }

    func testZeroFalseAndEmptyCollectionValuesRemainPresent() throws {
        let info = try makeGeneralInfo([
            "metadataPercentComplete": .double(0),
            "isPrivate": .bool(false),
            "labels": .array([]),
            "totalSize": .int(0),
            "sizeWhenDone": .int(0),
            "leftUntilDone": .int(0),
            "downloadDir": .string("/srv/downloads"),
        ])

        XCTAssertEqual(info.metadataPercentComplete, 0)
        XCTAssertEqual(info.isMetadataComplete, false)
        XCTAssertEqual(info.isPrivate, false)
        XCTAssertEqual(info.labels, [])
        XCTAssertEqual(info.totalSize, 0)
        XCTAssertEqual(info.sizeWhenDone, 0)
        XCTAssertEqual(info.leftUntilDone, 0)
        XCTAssertEqual(info.completedSize, 0)
        XCTAssertEqual(info.downloadDir, "/srv/downloads")
        XCTAssertEqual(info.fullPath(torrentName: "Example"), "/srv/downloads/Example")
    }

    func testTableResponsePreservesTypedTorrentCardPresence() throws {
        let response = try TorrentGetResponse(validating: [
            "fields": .array([
                .string("id"),
                .string("metadataPercentComplete"),
                .string("isPrivate"),
                .string("labels"),
                .string("totalSize"),
                .string("downloadDir"),
            ]),
            "data": .array([.array([
                .int(1),
                .double(1),
                .bool(false),
                .array([]),
                .int(0),
                .string(""),
            ])]),
        ])
        let info = try XCTUnwrap(TorrentDetail(torrent: response.torrents[0]).generalInfo)

        XCTAssertEqual(info.metadataPercentComplete, 1)
        XCTAssertEqual(info.isMetadataComplete, true)
        XCTAssertEqual(info.isPrivate, false)
        XCTAssertEqual(info.labels, [])
        XCTAssertEqual(info.totalSize, 0)
        XCTAssertEqual(info.downloadDir, "")
        XCTAssertNil(info.fullPath(torrentName: "Example"))
    }

    func testDatesAndCompletedSizeUseOnlyDetailResponseValues() throws {
        let info = try makeGeneralInfo([
            "sizeWhenDone": .int(1_024),
            "leftUntilDone": .int(256),
            "addedDate": .int(100),
            "doneDate": .int(200),
            "activityDate": .int(300),
        ])

        XCTAssertEqual(info.completedSize, 768)
        XCTAssertEqual(info.addedDate, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(info.completedDate, Date(timeIntervalSince1970: 200))
        XCTAssertEqual(info.activityDate, Date(timeIntervalSince1970: 300))
    }

    func testDerivedValuesFailClosedForMissingOrInconsistentInputs() throws {
        let missingLeft = try makeGeneralInfo(["sizeWhenDone": .int(100)])
        let negativeSize = try makeGeneralInfo([
            "sizeWhenDone": .int(-1),
            "leftUntilDone": .int(0),
        ])
        let excessiveLeft = try makeGeneralInfo([
            "sizeWhenDone": .int(100),
            "leftUntilDone": .int(101),
        ])
        let missingDirectory = try makeGeneralInfo([:])
        let whitespaceDirectory = try makeGeneralInfo(["downloadDir": .string(" \n ")])
        let directory = try makeGeneralInfo(["downloadDir": .string("/srv/downloads/")])

        XCTAssertNil(missingLeft.completedSize)
        XCTAssertNil(negativeSize.completedSize)
        XCTAssertNil(excessiveLeft.completedSize)
        XCTAssertNil(missingDirectory.fullPath(torrentName: "Example"))
        XCTAssertNil(whitespaceDirectory.fullPath(torrentName: "Example"))
        XCTAssertNil(directory.fullPath(torrentName: ""))
        XCTAssertNil(directory.fullPath(torrentName: " \t "))
        XCTAssertEqual(directory.fullPath(torrentName: "Example"), "/srv/downloads/Example")
    }

    func testModernTransferValuesAreTypedWithoutSummaryFallbacks() throws {
        let updateDate = Date(timeIntervalSince1970: 1_735_704_000)
        let info = try makeGeneralInfo([
            "downloadedEver": .int(0),
            "uploadedEver": .int(2_048),
            "corruptEver": .int(1_024),
            "rateDownload": .int(2_500),
            "rateUpload": .int(1_500),
            "downloadLimited": .bool(true),
            "downloadLimit": .int(750),
            "uploadLimited": .int(0),
            "uploadLimit": .int(25),
            "maxConnectedPeers": .int(60),
            "eta": .int(120),
            "uploadRatio": .double(-2),
            "bandwidthPriority": .int(1),
            "queuePosition": .int(7),
            "peersSendingToUs": .int(2),
            "peersGettingFromUs": .int(3),
            "secondsSeeding": .int(3_600),
            "trackerStats": .array([.object([
                "announce": .string("https://tracker.example/announce"),
                "announceState": .int(0),
                "nextAnnounceTime": .int(1_735_704_000),
                "seederCount": .int(11),
                "leecherCount": .int(12),
            ])]),
        ], rpcVersion: 18)

        XCTAssertEqual(info.downloadedEver, 0)
        XCTAssertEqual(info.uploadedEver, 2_048)
        XCTAssertEqual(info.corruptEver, 1_024)
        XCTAssertEqual(info.rateDownload, 2_500)
        XCTAssertEqual(info.rateUpload, 1_500)
        XCTAssertEqual(info.downloadSpeedLimit, .limited(750))
        XCTAssertEqual(info.uploadSpeedLimit, .global)
        XCTAssertEqual(info.maxConnectedPeers, 60)
        XCTAssertEqual(info.eta, 120)
        XCTAssertEqual(info.uploadRatio, .infinity)
        XCTAssertEqual(info.bandwidthPriority, 1)
        XCTAssertEqual(info.queuePosition, 7)
        XCTAssertEqual(info.seedsDisplay, "2 of 11 connected")
        XCTAssertEqual(info.peersDisplay, "3 of 12 connected")
        XCTAssertEqual(info.secondsSeeding, 3_600)
        XCTAssertEqual(info.trackerHost, "example")
        XCTAssertEqual(info.trackerUpdate, .scheduled(updateDate))
    }

    func testLegacyTransferLimitAndTrackerStatesPreserveModeSemantics() throws {
        let updating = try makeGeneralInfo([
            "downloadLimitMode": .int(TorrentPropertiesLimitMode.global.rawValue),
            "downloadLimit": .int(100),
            "uploadLimitMode": .int(TorrentPropertiesLimitMode.unlimited.rawValue),
            "uploadLimit": .int(200),
            "nextAnnounceTime": .int(1),
            "trackers": .array([.object(["announce": .string("https://tracker.example/announce")])]),
        ], rpcVersion: 4)
        let limited = try makeGeneralInfo([
            "downloadLimitMode": .int(TorrentPropertiesLimitMode.single.rawValue),
            "downloadLimit": .int(333),
            "uploadLimitMode": .int(TorrentPropertiesLimitMode.single.rawValue),
            "uploadLimit": .int(-1),
        ], rpcVersion: 4)

        XCTAssertEqual(updating.downloadSpeedLimit, .global)
        XCTAssertEqual(updating.uploadSpeedLimit, .unlimited)
        XCTAssertEqual(updating.trackerUpdate, .updating)
        XCTAssertEqual(limited.downloadSpeedLimit, .limited(333))
        XCTAssertEqual(limited.uploadSpeedLimit, .unlimited)
    }

    func testModernUpdatingTrackerStateWinsOverItsScheduledTimestamp() throws {
        let info = try makeGeneralInfo([
            "trackerStats": .array([.object([
                "announceState": .int(2),
                "nextAnnounceTime": .int(1_735_704_000),
            ])]),
        ], rpcVersion: 7)

        XCTAssertEqual(info.trackerUpdate, .updating)
    }

    func testCachedSummaryOverlayCannotReplaceProjectionIndependentTransferValues() throws {
        let info = try makeGeneralInfo([
            "downloadedEver": .int(4_096),
            "uploadedEver": .int(8_192),
            "corruptEver": .int(512),
            "rateDownload": .int(128),
            "rateUpload": .int(256),
            "downloadLimited": .bool(true),
            "downloadLimit": .int(400),
            "maxConnectedPeers": .int(80),
            "secondsSeeding": .int(600),
        ], rpcVersion: 18)
        let summary = TorrentMapper.map(
            TorrentGetTorrent(json: ["id": .int(1), "status": .int(0)]),
            rpcVersion: 18
        )
        let overlaid = info.overlayingCachedDisplay(with: summary)

        XCTAssertEqual(overlaid.downloadedEver, 4_096)
        XCTAssertEqual(overlaid.uploadedEver, 8_192)
        XCTAssertEqual(overlaid.corruptEver, 512)
        XCTAssertEqual(overlaid.rateDownload, 128)
        XCTAssertEqual(overlaid.rateUpload, 256)
        XCTAssertEqual(overlaid.downloadSpeedLimit, .limited(400))
        XCTAssertEqual(overlaid.maxConnectedPeers, 80)
        XCTAssertEqual(overlaid.secondsSeeding, 600)
    }

    private func makeGeneralInfo(
        _ fields: RPCArguments,
        rpcVersion: Int = 14
    ) throws -> TorrentGeneralInfo {
        var torrentFields = fields
        torrentFields["id"] = .int(1)
        let detail = TorrentDetail(torrent: TorrentGetTorrent(json: torrentFields), rpcVersion: rpcVersion)
        return try XCTUnwrap(detail.generalInfo)
    }
}
