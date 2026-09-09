// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import SwiftUI
import XCTest
@testable import TransmissionRemoteMac

final class TorrentTableColumnsTests: XCTestCase {
    func testIdleSpeedIsBlankWithoutChangingNumericSortOrder() {
        XCTAssertEqual(TorrentTableFormatters.speed(0), "")
        XCTAssertEqual(TorrentTableFormatters.speed(-1), "")
        XCTAssertEqual(TorrentTableFormatters.speed(1_024), ByteCountFormatters.speed(1_024))
        var idle = torrent(id: 1)
        idle.rateDownload = 0
        idle.rateUpload = 0
        var slow = torrent(id: 2)
        slow.rateDownload = 8_192
        slow.rateUpload = 8_192
        var fast = torrent(id: 3)
        fast.rateDownload = 1_048_576
        fast.rateUpload = 1_048_576
        for column in [TorrentTableColumnID.downloadSpeed, .uploadSpeed] {
            for direction in [TorrentTableSortDirection.ascending, .descending] {
                let descriptors = TorrentTableSortMapping.descriptors(for: .init(columnID: column, direction: direction))
                XCTAssertEqual(TorrentSorting.sorted([slow, fast, idle], using: descriptors).map(\.id),
                               direction == .ascending ? [1, 2, 3] : [3, 2, 1])
            }
        }
    }

    func testPhysicalTableSizeKeepsZeroAndUnknownSizeUsesPlaceholder() {
        XCTAssertEqual(TorrentTableFormatters.size(0), ByteCountFormatters.fileSize(0))
        XCTAssertNotEqual(TorrentTableFormatters.size(0), "—")
        XCTAssertEqual(TorrentTableFormatters.size(-1), "—")
    }

    func testTransferCounterPlaceholdersKeepNumericColumnSorting() {
        var empty = torrent(id: 1)
        empty.downloadedEver = 0
        empty.uploadedEver = 0
        empty.leftUntilDone = 0
        var partial = torrent(id: 2)
        partial.downloadedEver = 1_024
        partial.uploadedEver = 1_024
        partial.leftUntilDone = 1_024
        var larger = torrent(id: 3)
        larger.downloadedEver = 8_192
        larger.uploadedEver = 8_192
        larger.leftUntilDone = 8_192

        XCTAssertEqual(ByteCountFormatters.transferSize(empty.downloadedEver), "—")
        XCTAssertEqual(ByteCountFormatters.transferSize(empty.uploadedEver), "—")
        XCTAssertEqual(ByteCountFormatters.transferSize(empty.leftUntilDone), "—")
        for column in [TorrentTableColumnID.downloaded, .uploaded, .sizeLeft] {
            for direction in [TorrentTableSortDirection.ascending, .descending] {
                let descriptors = TorrentTableSortMapping.descriptors(for: .init(columnID: column, direction: direction))
                XCTAssertEqual(TorrentSorting.sorted([partial, larger, empty], using: descriptors).map(\.id),
                               direction == .ascending ? [1, 2, 3] : [3, 2, 1])
            }
        }
    }

    func testDefinesTwentySixUniqueStableColumnIDs() {
        let columns = TorrentTableColumnID.allCases

        XCTAssertEqual(columns.count, 26)
        XCTAssertEqual(Set(columns.map(\.rawValue)).count, 26)
        XCTAssertEqual(columns.filter(\.isRequired), [.name])
        XCTAssertEqual(
            Set(columns.filter(\.isVisibleByDefault)),
            [.name, .size, .done, .status, .seeds, .peers, .downloadSpeed,
             .uploadSpeed, .eta, .ratio, .labels]
        )
    }

    func testEveryColumnSortMappingRoundTripsInBothDirections() {
        for columnID in TorrentTableColumnID.allCases {
            for direction in TorrentTableSortDirection.allCases {
                let preference = TorrentTableSortPreference(
                    columnID: columnID,
                    direction: direction
                )

                let descriptors = TorrentTableSortMapping.descriptors(for: preference)

                XCTAssertEqual(
                    TorrentTableSortMapping.preference(for: descriptors),
                    preference,
                    "Failed sort mapping for \(columnID.rawValue) \(direction.rawValue)"
                )
            }
        }
    }

    func testEveryAscendingColumnSortUsesDeterministicIDTieBreak() {
        let torrents = [torrent(id: 2), torrent(id: 1)]

        for columnID in TorrentTableColumnID.allCases {
            let descriptors = TorrentTableSortMapping.descriptors(
                for: TorrentTableSortPreference(columnID: columnID, direction: .ascending)
            )

            XCTAssertEqual(
                TorrentSorting.sorted(torrents, using: descriptors).map(\.id),
                [1, 2],
                "Failed deterministic tie-break for \(columnID.rawValue)"
            )
        }
    }

    func testMalformedPersistedSortFallsBackToDefault() {
        let malformedValues = [
            "",
            "torrent.name",
            "torrent.unknown|ascending",
            "torrent.name|sideways",
            "torrent.name|ascending|extra",
        ]

        for rawValue in malformedValues {
            XCTAssertEqual(
                TorrentTableSortPreference(rawValue: rawValue),
                TorrentTableDefaults.sort,
                "Expected fallback for \(rawValue)"
            )
        }
    }

    func testEmptyVisibleSetPreservesClassifiedBaselineAcrossSupportedRPCGenerations() {
        let identity: Set<String> = ["hashString", "id", "name"]
        let legacyBehavior: Set<String> = [
            "haveUnchecked", "haveValid", "leftUntilDone",
            "percentDone", "rateDownload", "rateUpload", "recheckProgress", "sizeWhenDone",
            "status", "totalSize",
        ]
        let currentBehavior: Set<String> = [
            "haveUnchecked", "haveValid", "leftUntilDone",
            "metadataPercentComplete", "percentDone", "rateDownload", "rateUpload",
            "recheckProgress", "sizeWhenDone", "status", "totalSize",
        ]

        for rpcVersion in [6, 7, 16, 18] {
            let expectedBehavior = rpcVersion < 7 ? legacyBehavior : currentBehavior
            let expectedFilterDynamic: Set<String> = rpcVersion < 7
                ? ["announceResponse", "errorString"]
                : ["errorString"]
            var expectedFilterStatic: Set<String> = ["downloadDir"]
            if rpcVersion >= 16 {
                expectedFilterStatic.insert("labels")
            }
            let expectedTrackerMetadata: Set<String> = rpcVersion < 7
                ? ["trackers"]
                : ["trackerStats"]
            let expectedOverviewStatic: Set<String> = ["pieceCount", "pieceSize"]
            let expectedBaseline = identity
                .union(expectedBehavior)
                .union(expectedFilterDynamic)
                .union(expectedFilterStatic)
                .union(expectedOverviewStatic)
                .union(expectedTrackerMetadata)

            XCTAssertEqual(
                Set(TorrentTableFieldRequirements.identityFields(rpcVersion: rpcVersion)),
                identity,
                "Identity fields for RPC \(rpcVersion)"
            )
            XCTAssertEqual(
                Set(TorrentTableFieldRequirements.alwaysNeededBehaviorDynamicFields(rpcVersion: rpcVersion)),
                expectedBehavior,
                "Always-needed behavior fields for RPC \(rpcVersion)"
            )
            XCTAssertEqual(
                Set(TorrentTableFieldRequirements.filterSidebarDynamicFields(rpcVersion: rpcVersion)),
                expectedFilterDynamic,
                "Dynamic filter/sidebar fields for RPC \(rpcVersion)"
            )
            XCTAssertEqual(
                Set(TorrentTableFieldRequirements.filterSidebarStaticFields(rpcVersion: rpcVersion)),
                expectedFilterStatic,
                "Static filter/sidebar fields for RPC \(rpcVersion)"
            )
            XCTAssertEqual(
                Set(TorrentTableFieldRequirements.heavyweightTrackerMetadataFields(rpcVersion: rpcVersion)),
                expectedTrackerMetadata,
                "Heavy tracker fields for RPC \(rpcVersion)"
            )
            XCTAssertEqual(
                Set(TorrentTableFieldRequirements.fullBaselineFields(rpcVersion: rpcVersion)),
                expectedBaseline,
                "Full baseline for RPC \(rpcVersion)"
            )
            XCTAssertEqual(
                Set(TorrentTableFieldRequirements.fields(for: [], rpcVersion: rpcVersion)),
                expectedBaseline,
                "Empty visible-column union for RPC \(rpcVersion)"
            )
            XCTAssertTrue(
                TorrentTableFieldRequirements.optionalPresentationFields(
                    for: [],
                    rpcVersion: rpcVersion
                ).isEmpty
            )
        }
    }

    func testEmptyVisibleSetExcludesUnsupportedLegacyAndLabelFields() {
        let rpc6 = Set(TorrentTableFieldRequirements.fields(for: [], rpcVersion: 6))
        XCTAssertTrue(rpc6.contains("announceResponse"))
        XCTAssertFalse(rpc6.contains("metadataPercentComplete"))
        XCTAssertFalse(rpc6.contains("trackerStats"))
        XCTAssertFalse(rpc6.contains("labels"))
        XCTAssertTrue(rpc6.contains("trackers"))
        XCTAssertFalse(rpc6.contains("addedDate"))
        XCTAssertFalse(rpc6.contains("isPrivate"))

        let rpc7 = Set(TorrentTableFieldRequirements.fields(for: [], rpcVersion: 7))
        XCTAssertFalse(rpc7.contains("announceResponse"))
        XCTAssertTrue(rpc7.contains("metadataPercentComplete"))
        XCTAssertTrue(rpc7.contains("trackerStats"))
        XCTAssertFalse(rpc7.contains("labels"))
        XCTAssertFalse(rpc7.contains("trackers"))

        for rpcVersion in [16, 18] {
            let fields = Set(TorrentTableFieldRequirements.fields(for: [], rpcVersion: rpcVersion))
            XCTAssertFalse(fields.contains("announceResponse"))
            XCTAssertTrue(fields.contains("trackerStats"))
            XCTAssertTrue(fields.contains("labels"))
            XCTAssertFalse(fields.contains("trackers"))
        }
    }

    func testAutomaticVisibilityUsesDeclaredDefaultsAndNameCannotBeHidden() {
        var customization = TableColumnCustomization<TorrentSummary>()

        XCTAssertEqual(
            TorrentTableColumnVisibility.resolvedColumns(in: customization),
            Set(TorrentTableColumnID.allCases.filter(\.isVisibleByDefault))
        )
        XCTAssertTrue(TorrentTableColumnVisibility.isVisible(.labels, in: customization))
        XCTAssertFalse(TorrentTableColumnVisibility.isVisible(.uploaded, in: customization))

        customization[visibility: TorrentTableColumnID.name.rawValue] = .hidden
        customization[visibility: TorrentTableColumnID.labels.rawValue] = .hidden
        customization[visibility: TorrentTableColumnID.uploaded.rawValue] = .visible

        XCTAssertTrue(TorrentTableColumnVisibility.isVisible(.name, in: customization))
        XCTAssertFalse(TorrentTableColumnVisibility.isVisible(.labels, in: customization))
        XCTAssertTrue(TorrentTableColumnVisibility.isVisible(.uploaded, in: customization))
    }

    func testVisibleColumnsAddOnlyPresentationFields() {
        let columns: Set<TorrentTableColumnID> = [
            .downloaded, .eta, .labels, .peers, .seeds, .trackerStatus,
        ]

        XCTAssertEqual(
            Set(TorrentTableFieldRequirements.optionalPresentationFields(for: columns, rpcVersion: 6)),
            ["downloadedEver", "eta", "leechers", "peersGettingFromUs", "peersSendingToUs", "seeders"]
        )
        XCTAssertEqual(
            Set(TorrentTableFieldRequirements.optionalPresentationFields(for: columns, rpcVersion: 7)),
            ["downloadedEver", "eta", "peersGettingFromUs", "peersSendingToUs"]
        )
        XCTAssertEqual(
            Set(TorrentTableFieldRequirements.optionalPresentationFields(for: columns, rpcVersion: 16)),
            ["downloadedEver", "eta", "peersGettingFromUs", "peersSendingToUs"]
        )
        XCTAssertEqual(
            Set(TorrentTableFieldRequirements.optionalDynamicPresentationFields(for: columns, rpcVersion: 18)),
            ["downloadedEver", "eta", "peersGettingFromUs", "peersSendingToUs"]
        )
        XCTAssertTrue(
            TorrentTableFieldRequirements.optionalStaticPresentationFields(
                for: columns,
                rpcVersion: 18
            ).isEmpty
        )

        for rpcVersion in [6, 7, 16, 18] {
            let baseline = Set(TorrentTableFieldRequirements.fullBaselineFields(rpcVersion: rpcVersion))
            let presentation = Set(
                TorrentTableFieldRequirements.optionalPresentationFields(
                    for: columns,
                    rpcVersion: rpcVersion
                )
            )
            let allFields = Set(
                TorrentTableFieldRequirements.fields(for: columns, rpcVersion: rpcVersion)
            )
            XCTAssertTrue(baseline.isDisjoint(with: presentation))
            XCTAssertEqual(allFields, baseline.union(presentation))
        }
    }

    func testStaticPresentationFieldsAreDrivenOnlyByVisibleColumns() {
        let hidden = Set(
            TorrentTableFieldRequirements.optionalStaticPresentationFields(
                for: [.name],
                rpcVersion: 18
            )
        )
        let visible = Set(
            TorrentTableFieldRequirements.optionalStaticPresentationFields(
                for: [.addedOn, .privateTorrent],
                rpcVersion: 18
            )
        )

        XCTAssertTrue(hidden.isEmpty)
        XCTAssertEqual(visible, ["addedDate", "isPrivate"])
    }

    private func torrent(id: Int) -> TorrentSummary {
        TorrentSummary(
            id: id,
            name: "Same",
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
            eta: 0,
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
