// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation
import XCTest
@testable import TransmissionRemoteMac

final class InstantPiecePresentationTests: XCTestCase {
    func testFullListCarriesOnlyCheapPieceMetadataAcrossRPCVersions() {
        for version in [4, 5, 6, 7, 16, 18] {
            let plan = TorrentListFieldPlan(
                revision: 1,
                rpcVersion: version,
                visibleColumns: [.name],
                activeSortColumn: .name
            )
            for fields in [plan.fullFields, plan.bootstrapFields] {
                XCTAssertTrue(fields.contains("pieceCount"))
                XCTAssertTrue(fields.contains("pieceSize"))
            }
            XCTAssertFalse(plan.deltaFields.contains("pieceCount"))
            XCTAssertFalse(plan.deltaFields.contains("pieceSize"))
            for fields in [plan.fullFields, plan.bootstrapFields, plan.deltaFields] {
                XCTAssertFalse(fields.contains("pieces"))
            }
        }
    }

    func testCompletedSummaryProducesCompactPresentationWithoutBitfield() {
        let summary = completedSummary()
        XCTAssertEqual(
            TorrentPiecePresentation.state(summary: summary, cachedInfo: nil),
            .complete(pieceCount: 4)
        )
        var huge = summary
        huge.pieceCount = 1_000_000_000
        huge.pieceSize = 16_384
        huge.totalSize = 16_384_000_000_000
        huge.reportedTotalSize = huge.totalSize
        huge.sizeWhenDone = huge.totalSize
        huge.haveValid = huge.totalSize
        XCTAssertEqual(
            TorrentPiecePresentation.state(summary: huge, cachedInfo: nil),
            .complete(pieceCount: 1_000_000_000)
        )
    }

    func testSelectedFilesAtOneHundredPercentDoNotProveAllPieces() {
        var selected = completedSummary()
        selected.sizeWhenDone = 300
        selected.haveValid = 300
        XCTAssertEqual(selected.percentDone, 1)
        XCTAssertEqual(TorrentPiecePresentation.state(summary: selected, cachedInfo: nil), .unavailable)

        var inferredTotal = completedSummary()
        inferredTotal.reportedTotalSize = nil
        XCTAssertEqual(TorrentPiecePresentation.state(summary: inferredTotal, cachedInfo: nil), .unavailable)
    }

    func testMissingInvalidAndContradictoryEvidenceNeverSynthesizesCompletion() {
        let mutations: [(inout TorrentSummary) -> Void] = [
            { $0.status = .checking },
            { $0.status = .checkWait },
            { $0.status = .unknown },
            { $0.haveUnchecked = 1 },
            { $0.haveUnchecked = nil },
            { $0.haveValid = nil },
            { $0.errorString = "Data is missing" },
            { $0.globalError = "I/O error" },
            { $0.metadataPercentComplete = nil },
            { $0.metadataPercentComplete = .nan },
            { $0.metadataPercentComplete = 0.5 },
            { $0.isMetadataComplete = false },
            { $0.pieceCount = nil },
            { $0.pieceCount = -1 },
            { $0.pieceCount = 5 },
            { $0.pieceSize = 0 },
            { $0.totalSize = 0 },
            { $0.leftUntilDone = 1 },
        ]
        for (index, mutate) in mutations.enumerated() {
            var summary = completedSummary()
            mutate(&summary)
            XCTAssertEqual(
                TorrentPiecePresentation.state(summary: summary, cachedInfo: nil),
                .unavailable,
                "Invalid evidence case \(index)"
            )
        }
    }

    func testCorruptAndIncompleteCachedBitfieldsAreNotPaintedComplete() {
        let summary = completedSummary()
        let corrupt = TorrentGeneralInfo(torrent: TorrentGetTorrent(json: [
            "pieceCount": .int(4), "pieces": .string("%%%"),
        ]))
        XCTAssertEqual(
            TorrentPiecePresentation.state(summary: summary, cachedInfo: corrupt),
            .invalid(.malformedBase64)
        )
        let partial = TorrentGeneralInfo(torrent: TorrentGetTorrent(json: [
            "pieceCount": .int(4),
            "pieces": .string(Data([0b1100_0000]).base64EncodedString()),
        ]))
        XCTAssertEqual(
            TorrentPiecePresentation.state(summary: summary, cachedInfo: partial),
            partial.pieceMapState
        )
        XCTAssertTrue(TorrentOverviewRequestPlan(summary: summary, cachedInfo: partial, rpcVersion: 18)
            .fields.contains("pieces"))
    }

    func testNewOverviewEvidenceRevokesOldCompleteSummary() {
        let updates: [RPCArguments] = [
            ["haveValid": .int(300)], ["haveUnchecked": .int(50)],
            ["metadataPercentComplete": .double(0.5)], ["totalSize": .int(401)],
            ["pieceCount": .int(8)], ["leftUntilDone": .int(50)],
            ["status": .int(2)], ["error": .int(3)], ["errorString": .string("Missing data")],
        ]
        for fields in updates {
            var info = TorrentGeneralInfo(torrent: TorrentGetTorrent(json: fields))
            info.pieceMapState = .complete(pieceCount: 4)
            XCTAssertEqual(
                TorrentPiecePresentation.state(summary: completedSummary(), cachedInfo: info),
                .unavailable
            )
        }
    }

    func testPendingMutationInvalidationCannotResynthesizeCompleteFromOldSummary() {
        var info = TorrentGeneralInfo(torrent: TorrentGetTorrent(json: completedFields))
        info.isPieceCompletionInvalidated = true
        XCTAssertEqual(
            TorrentPiecePresentation.state(summary: completedSummary(), cachedInfo: info),
            .unavailable
        )
        XCTAssertTrue(TorrentOverviewRequestPlan(
            summary: completedSummary(), cachedInfo: info, rpcVersion: 18
        ).fields.contains("pieces"))
    }

    func testMutationTombstoneForcesRevalidationWithoutAnyCachedSnapshot() {
        XCTAssertEqual(TorrentPiecePresentation.state(
            summary: completedSummary(), cachedInfo: nil, requiresPieceRevalidation: true
        ), .unavailable)
        let plan = TorrentOverviewRequestPlan(
            summary: completedSummary(), cachedInfo: nil, rpcVersion: 18,
            requiresPieceRevalidation: true
        )
        XCTAssertTrue(plan.fields.contains("pieces"))
        XCTAssertTrue(plan.fields.contains("pieceCount"))
        XCTAssertTrue(plan.fields.contains("pieceSize"))
    }

    func testOverviewKeepsDynamicEvidenceAndOmitsLoadedStaticMetadata() {
        let summary = completedSummary()
        let info = TorrentGeneralInfo(torrent: TorrentGetTorrent(json: completedFields))
        let initial = TorrentOverviewRequestPlan(summary: summary, cachedInfo: nil, rpcVersion: 18)
        XCTAssertTrue(initial.fields.contains("creator"))
        XCTAssertFalse(initial.fields.contains("pieces"))
        XCTAssertFalse(initial.fields.contains("pieceCount"))
        XCTAssertFalse(initial.fields.contains("pieceSize"))
        XCTAssertEqual(initial.pieceCount, 4)
        XCTAssertEqual(initial.pieceSize, 100)
        let repeatPlan = TorrentOverviewRequestPlan(summary: summary, cachedInfo: info, rpcVersion: 18)
        XCTAssertEqual(repeatPlan.omittedFields, [
            "comment", "creator", "dateCreated", "pieceCount", "pieceSize", "pieces",
        ])
        XCTAssertTrue(repeatPlan.fields.contains("magnetLink"), "Display name and tracker parameters may change")
        for field in ["haveValid", "haveUnchecked", "metadataPercentComplete", "totalSize", "leftUntilDone"] {
            XCTAssertTrue(repeatPlan.fields.contains(field), field)
        }
    }

    func testUnrelatedTypedTrackerFailureDoesNotRefetchVerifiedPieces() {
        var summary = completedSummary()
        summary.trackerError = "Tracker error: unavailable"
        summary.errorString = summary.trackerError
        let info = TorrentGeneralInfo(torrent: TorrentGetTorrent(json: [
            "error": .int(2), "errorString": .string("unavailable"),
        ]))
        XCTAssertEqual(TorrentPiecePresentation.state(summary: summary, cachedInfo: info), .complete(pieceCount: 4))
    }

    func testCompleteSummaryOverlayCannotAuthorizeOmittingUnloadedModernMetadata() {
        let immutableFields: Set<String> = ["comment", "creator", "dateCreated"]
        for version in [7, 18] {
            for metadata in [nil, 0.5] as [Double?] {
                var fields = completedFields
                fields["metadataPercentComplete"] = metadata.map(JSONValue.double)
                let cached = TorrentGeneralInfo(torrent: TorrentGetTorrent(json: fields), rpcVersion: version)
                let overlaid = cached.overlayingCachedDisplay(with: completedSummary())
                XCTAssertEqual(overlaid.isMetadataComplete, true)

                let refresh = TorrentOverviewRequestPlan(
                    summary: completedSummary(), cachedInfo: overlaid, rpcVersion: version
                )
                XCTAssertTrue(immutableFields.isSubset(of: Set(refresh.fields)))
                XCTAssertTrue(immutableFields.isDisjoint(with: refresh.omittedFields))

                let authoritative = TorrentGeneralInfo(
                    torrent: TorrentGetTorrent(json: completedFields), rpcVersion: version
                )
                let nextRefresh = TorrentOverviewRequestPlan(
                    summary: completedSummary(), cachedInfo: authoritative, rpcVersion: version
                )
                XCTAssertTrue(immutableFields.isSubset(of: nextRefresh.omittedFields))
            }
        }
    }

    func testLegacyOverviewCanOmitLoadedMetadataWithoutModernCompletionField() {
        var fields = completedFields
        fields.removeValue(forKey: "metadataPercentComplete")
        for version in [1, 4, 5, 6] {
            let summary = TorrentMapper.map(TorrentGetTorrent(json: fields), rpcVersion: version)
            let cached = TorrentGeneralInfo(torrent: TorrentGetTorrent(json: fields), rpcVersion: version)
            let plan = TorrentOverviewRequestPlan(summary: summary, cachedInfo: cached, rpcVersion: version)
            XCTAssertTrue(Set(["comment", "creator", "dateCreated"]).isSubset(of: plan.omittedFields))
            XCTAssertFalse(plan.fields.contains("metadataPercentComplete"))
        }
    }

    func testPartialPieceRequestsKeepTheirRequiredCountAndRefetchPieces() {
        var summary = completedSummary()
        summary.haveValid = 200
        summary.leftUntilDone = 200
        let info = TorrentGeneralInfo(torrent: TorrentGetTorrent(json: completedFields))
        let plan = TorrentOverviewRequestPlan(summary: summary, cachedInfo: info, rpcVersion: 18)
        XCTAssertTrue(plan.fields.contains("pieces"))
        XCTAssertTrue(plan.fields.contains("pieceCount"))
        XCTAssertFalse(plan.fields.contains("pieceSize"))
    }

    func testLegacyGatesRemainExactAndMetadataArrivalRefetchesStaticFields() {
        var incomplete = completedSummary()
        incomplete.metadataPercentComplete = 0.5
        incomplete.isMetadataComplete = false
        for version in [4, 5, 6, 7, 15, 16, 18] {
            let plan = TorrentOverviewRequestPlan(summary: incomplete, cachedInfo: nil, rpcVersion: version)
            XCTAssertEqual(plan.fields, TorrentDetailPane.overview.rpcFields(rpcVersion: version))
            XCTAssertEqual(plan.fields.contains("pieces"), version >= 5)
            XCTAssertEqual(plan.fields.contains("magnetLink"), version >= 7)
            XCTAssertEqual(plan.fields.contains("labels"), version >= 16)
        }
        let metadataPending = TorrentGeneralInfo(torrent: TorrentGetTorrent(json: [
            "metadataPercentComplete": .double(0.5),
        ]))
        let arrived = TorrentOverviewRequestPlan(
            summary: completedSummary(), cachedInfo: metadataPending, rpcVersion: 18
        )
        XCTAssertTrue(arrived.fields.contains("creator"))
        XCTAssertTrue(arrived.fields.contains("pieces"))
    }

    func testSummaryMetadataSurvivesPartialListRefreshWithoutInventingTotalSize() {
        let original = completedSummary()
        let merged = TorrentMapper.merging(
            TorrentGetTorrent(json: ["id": .int(7), "rateUpload": .int(1024)]),
            into: original,
            rpcVersion: 18
        )
        XCTAssertEqual(merged.pieceCount, 4)
        XCTAssertEqual(merged.pieceSize, 100)
        XCTAssertEqual(merged.reportedTotalSize, 400)
        XCTAssertEqual(merged.metadataPercentComplete, 1)
        let noTotal = TorrentMapper.map(TorrentGetTorrent(json: [
            "id": .int(7), "sizeWhenDone": .int(400),
        ]), rpcVersion: 18)
        XCTAssertEqual(noTotal.totalSize, 400)
        XCTAssertNil(noTotal.reportedTotalSize)
        XCTAssertNil(noTotal.metadataPercentComplete)
    }

    func testInitialSizeProgressUsesReportedFieldsWithoutTurningUnknownIntoZero() {
        var summary = completedSummary()
        XCTAssertEqual(summary.reportedSizeWhenDone, 400)
        XCTAssertEqual(summary.reportedCompletedSize, 400)
        summary.reportedLeftUntilDone = nil
        XCTAssertNil(summary.reportedCompletedSize)
        summary.reportedLeftUntilDone = 401
        XCTAssertNil(summary.reportedCompletedSize)
        summary.reportedLeftUntilDone = -1
        XCTAssertNil(summary.reportedCompletedSize)
        summary.reportedLeftUntilDone = 100
        XCTAssertEqual(summary.reportedCompletedSize, 300)
        summary.metadataPercentComplete = 0.5
        XCTAssertNil(summary.reportedCompletedSize)
    }

    private var completedFields: RPCArguments {
        [
            "id": .int(7), "hashString": .string("complete-example"), "status": .int(6),
            "metadataPercentComplete": .int(1), "percentDone": .int(1),
            "totalSize": .int(400), "sizeWhenDone": .int(400), "leftUntilDone": .int(0),
            "haveValid": .int(400), "haveUnchecked": .int(0),
            "pieceCount": .int(4), "pieceSize": .int(100),
        ]
    }

    private func completedSummary() -> TorrentSummary {
        TorrentMapper.map(TorrentGetTorrent(json: completedFields), rpcVersion: 18)
    }
}
