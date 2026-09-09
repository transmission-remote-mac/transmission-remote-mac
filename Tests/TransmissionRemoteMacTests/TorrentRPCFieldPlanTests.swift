// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import XCTest
@testable import TransmissionRemoteMac

final class TorrentRPCFieldPlanTests: XCTestCase {
    private let visibleColumns: Set<TorrentTableColumnID> = [.name, .eta, .seeds, .labels]

    func testExactCadenceFieldsAcrossSupportedRPCGenerations() {
        for rpcVersion in [6, 7, 16, 17, 18] {
            let plan = TorrentListFieldPlan(
                revision: 42,
                rpcVersion: rpcVersion,
                visibleColumns: visibleColumns,
                activeSortColumn: .uploaded
            )

            XCTAssertEqual(plan.revision, 42)
            XCTAssertEqual(plan.rpcVersion, rpcVersion)
            XCTAssertEqual(plan.projectionColumns, visibleColumns.union([.uploaded]))
            XCTAssertEqual(plan.deltaFields, expectedDeltaFields[rpcVersion])
            XCTAssertEqual(plan.fullFields, expectedFullFields[rpcVersion])
            XCTAssertEqual(plan.bootstrapFields, expectedFullFields[rpcVersion])
        }
    }

    func testHiddenColumnsProduceNarrowDeterministicDeltaPlan() {
        let first = TorrentListFieldPlan(
            revision: 9,
            rpcVersion: 18,
            visibleColumns: [.name],
            activeSortColumn: .name
        )
        let second = TorrentListFieldPlan(
            revision: 9,
            rpcVersion: 18,
            visibleColumns: [.name],
            activeSortColumn: .name
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.projectionColumns, [.name])
        XCTAssertEqual(first.deltaFields, modernBaselineDeltaFields)
        XCTAssertEqual(
            first.fullFields,
            modernBaselineDeltaFields.addingAndSorting(["downloadDir", "labels", "pieceCount", "pieceSize"])
        )
        XCTAssertTrue(first.deltaFields.contains("trackerStats"))
        XCTAssertFalse(first.deltaFields.contains("labels"))
        XCTAssertFalse(first.deltaFields.contains("downloadDir"))
        XCTAssertFalse(first.deltaFields.contains("eta"))
        XCTAssertFalse(first.deltaFields.contains("uploadRatio"))
        XCTAssertFalse(first.deltaFields.contains("uploadedEver"))
        XCTAssertFalse(first.deltaFields.contains("queuePosition"))
    }

    func testVisibleColumnExpansionAddsOnlyItsStaticAndDynamicFields() {
        let narrow = TorrentListFieldPlan(
            revision: 1,
            rpcVersion: 18,
            visibleColumns: [.name],
            activeSortColumn: .name
        )
        let expanded = TorrentListFieldPlan(
            revision: 2,
            rpcVersion: 18,
            visibleColumns: [.name, .addedOn, .eta, .privateTorrent, .queuePosition, .ratio],
            activeSortColumn: .name
        )

        XCTAssertEqual(
            Set(expanded.deltaFields).subtracting(narrow.deltaFields),
            ["eta", "queuePosition", "uploadRatio"]
        )
        XCTAssertEqual(
            Set(expanded.fullFields).subtracting(narrow.fullFields),
            ["addedDate", "eta", "isPrivate", "queuePosition", "uploadRatio"]
        )
        for unrelatedField in [
            "activityDate", "bandwidthPriority", "doneDate", "downloadedEver",
            "peersGettingFromUs", "peersSendingToUs", "secondsSeeding", "uploadedEver",
        ] {
            XCTAssertFalse(expanded.fullFields.contains(unrelatedField), unrelatedField)
        }
    }

    func testTrackerGenerationsNeverOverlapAndModernStatusStaysFreshInDeltaRequests() {
        for rpcVersion in [6, 7, 16, 17, 18] {
            let plan = TorrentListFieldPlan(
                revision: 1,
                rpcVersion: rpcVersion,
                visibleColumns: Set(TorrentTableColumnID.allCases),
                activeSortColumn: .tracker
            )

            for fields in [plan.fullFields, plan.deltaFields, plan.bootstrapFields] {
                XCTAssertFalse(fields.contains("trackerList"), "RPC \(rpcVersion)")
                XCTAssertFalse(
                    fields.contains("trackers") && fields.contains("trackerStats"),
                    "RPC \(rpcVersion) requested both tracker generations"
                )
            }

            XCTAssertFalse(plan.deltaFields.contains("trackers"))
            if rpcVersion <= 6 {
                XCTAssertFalse(plan.deltaFields.contains("trackerStats"))
                XCTAssertTrue(plan.fullFields.contains("trackers"))
                XCTAssertFalse(plan.fullFields.contains("trackerStats"))
            } else {
                XCTAssertTrue(plan.deltaFields.contains("trackerStats"))
                XCTAssertFalse(plan.fullFields.contains("trackers"))
                XCTAssertTrue(plan.fullFields.contains("trackerStats"))
            }
        }
    }

    func testHiddenActiveSortColumnIsIncludedAndOutputIsStableAndSorted() {
        let first = TorrentListFieldPlan(
            revision: 9,
            rpcVersion: 18,
            visibleColumns: [.name],
            activeSortColumn: .queuePosition
        )
        let second = TorrentListFieldPlan(
            revision: 9,
            rpcVersion: 18,
            visibleColumns: [.name],
            activeSortColumn: .queuePosition
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.projectionColumns, [.name, .queuePosition])
        XCTAssertTrue(first.deltaFields.contains("queuePosition"))
        XCTAssertEqual(first.deltaFields, first.deltaFields.sorted())
        XCTAssertEqual(first.fullFields, first.fullFields.sorted())
        XCTAssertEqual(first.bootstrapFields, first.bootstrapFields.sorted())
        XCTAssertEqual(Set(first.deltaFields).count, first.deltaFields.count)
        XCTAssertEqual(Set(first.fullFields).count, first.fullFields.count)
    }

    func testNameIsAlwaysPartOfProjectionAndIdentityFields() {
        let plan = TorrentListFieldPlan(
            revision: 0,
            rpcVersion: 18,
            visibleColumns: [],
            activeSortColumn: .ratio
        )

        XCTAssertTrue(plan.projectionColumns.contains(.name))
        for fields in [plan.fullFields, plan.deltaFields, plan.bootstrapFields] {
            XCTAssertTrue(fields.contains("id"))
            XCTAssertTrue(fields.contains("hashString"))
            XCTAssertTrue(fields.contains("name"))
        }
    }

    private var expectedDeltaFields: [Int: [String]] {
        [
            6: [
                "announceResponse", "errorString", "eta", "hashString", "haveUnchecked",
                "haveValid", "id", "leftUntilDone", "name", "peersSendingToUs",
                "percentDone", "rateDownload", "rateUpload", "recheckProgress", "seeders",
                "sizeWhenDone", "status", "totalSize", "uploadedEver",
            ],
            7: modernExpandedDeltaFields,
            16: modernExpandedDeltaFields,
            17: modernExpandedDeltaFields,
            18: modernExpandedDeltaFields,
        ]
    }

    private var expectedFullFields: [Int: [String]] {
        [
            6: [
                "announceResponse", "downloadDir", "errorString", "eta", "hashString",
                "haveUnchecked", "haveValid", "id", "leftUntilDone", "name",
                "peersSendingToUs", "percentDone", "pieceCount", "pieceSize", "rateDownload", "rateUpload",
                "recheckProgress", "seeders", "sizeWhenDone", "status", "totalSize",
                "trackers", "uploadedEver",
            ],
            7: modernExpandedDeltaFields.addingAndSorting(["downloadDir", "pieceCount", "pieceSize"]),
            16: modernExpandedDeltaFields.addingAndSorting(["downloadDir", "labels", "pieceCount", "pieceSize"]),
            17: modernExpandedDeltaFields.addingAndSorting(["downloadDir", "labels", "pieceCount", "pieceSize"]),
            18: modernExpandedDeltaFields.addingAndSorting(["downloadDir", "labels", "pieceCount", "pieceSize"]),
        ]
    }

    private var modernBaselineDeltaFields: [String] {
        [
            "errorString", "hashString", "haveUnchecked", "haveValid", "id",
            "leftUntilDone", "metadataPercentComplete", "name", "percentDone",
            "rateDownload", "rateUpload", "recheckProgress", "sizeWhenDone", "status",
            "totalSize", "trackerStats",
        ]
    }

    private var modernExpandedDeltaFields: [String] {
        modernBaselineDeltaFields.addingAndSorting([
            "eta", "peersSendingToUs", "uploadedEver",
        ])
    }
}

private extension Array where Element == String {
    func addingAndSorting(_ fields: [String]) -> [String] {
        (self + fields).sorted()
    }
}
