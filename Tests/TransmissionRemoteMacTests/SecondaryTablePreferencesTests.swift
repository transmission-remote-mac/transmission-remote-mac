// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation
import XCTest
@testable import TransmissionRemoteMac

final class SecondaryTablePreferencesTests: XCTestCase {
    func testFilesSnapshotRevisionChangesOnlyForFilesPaneReplacement() throws {
        let firstRevision = TorrentFilesSnapshotRevision(
            rawValue: try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        )
        let replacementRevision = TorrentFilesSnapshotRevision(
            rawValue: try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        )
        let files = [
            TorrentFile(
                id: 0,
                path: "",
                name: "payload.bin",
                length: 10,
                bytesCompleted: 5,
                wanted: true,
                priority: 0
            )
        ]
        let current = TorrentDetail(
            id: 7,
            files: files,
            filesSnapshotRevision: firstRevision
        )
        let incoming = TorrentDetail(
            id: 7,
            files: files,
            filesSnapshotRevision: replacementRevision
        )

        for pane in [TorrentDetailPane.overview, .peers, .trackers, .statistics] {
            XCTAssertEqual(
                current.replacing(pane, with: incoming).filesSnapshotRevision,
                firstRevision
            )
        }
        XCTAssertEqual(
            current.replacing(.files, with: incoming).filesSnapshotRevision,
            replacementRevision
        )
    }

    func testFilesProjectionIdentityFailsClosedForTorrentOrSnapshotChanges() throws {
        let firstRevision = TorrentFilesSnapshotRevision(
            rawValue: try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000011"))
        )
        let replacementRevision = TorrentFilesSnapshotRevision(
            rawValue: try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000012"))
        )
        let current = TorrentDetail(id: 11, filesSnapshotRevision: firstRevision)
        let replacement = TorrentDetail(id: 11, filesSnapshotRevision: replacementRevision)
        let otherTorrent = TorrentDetail(id: 12, filesSnapshotRevision: firstRevision)
        let identity = try XCTUnwrap(TorrentFilesProjectionIdentity(detail: current))

        XCTAssertTrue(identity.matches(torrentID: 11, detail: current))
        XCTAssertFalse(identity.matches(torrentID: 11, detail: replacement))
        XCTAssertFalse(identity.matches(torrentID: 12, detail: current))
        XCTAssertFalse(identity.matches(torrentID: 12, detail: otherTorrent))
        XCTAssertFalse(identity.matches(torrentID: 11, detail: nil))
        XCTAssertTrue(
            identity.matches(
                torrentID: 11,
                detail: current.replacing(.overview, with: replacement)
            )
        )
        XCTAssertFalse(
            identity.matches(
                torrentID: 11,
                detail: current.replacing(.files, with: replacement)
            )
        )
    }

    func testColumnIDsAreStableAndUniqueAcrossSecondaryTables() {
        let allIDs = SecondaryTableColumnID.Files.all
            + SecondaryTableColumnID.Peers.all
            + SecondaryTableColumnID.Trackers.all

        XCTAssertEqual(Set(allIDs).count, allIDs.count)
        XCTAssertTrue(SecondaryTableColumnID.Files.all.contains(SecondaryTableDefaults.fileSort.columnID))
        XCTAssertTrue(SecondaryTableColumnID.Peers.all.contains(SecondaryTableDefaults.peerSort.columnID))
        XCTAssertTrue(SecondaryTableColumnID.Trackers.all.contains(SecondaryTableDefaults.trackerSort.columnID))
    }

    func testSecondaryTablesUseIndependentAppOwnedLayoutKeys() {
        let keys = SecondaryTableKind.allCases.map(\.layoutStorageKey)

        XCTAssertEqual(Set(keys).count, SecondaryTableKind.allCases.count)
        XCTAssertEqual(
            keys,
            [
                "torrentDetail.files.layout.v1",
                "torrentDetail.peers.layout.v1",
                "torrentDetail.trackers.layout.v1"
            ]
        )
    }

    func testLayoutPreferenceRoundTripsHiddenAndSortStateWithoutClaimingNativeOrder() {
        let preference = SecondaryTableLayoutPreference(
            hiddenColumnIDs: [
                SecondaryTableColumnID.Peers.flags,
                SecondaryTableColumnID.Peers.port
            ],
            sortPreference: SecondaryTableSortPreference(
                columnID: SecondaryTableColumnID.Peers.download,
                direction: .descending
            )
        )

        XCTAssertEqual(
            SecondaryTableLayoutPreference.restored(from: preference.rawValue, for: .peers),
            preference
        )
        XCTAssertFalse(preference.rawValue.contains("\"order\""))
    }

    func testLayoutNormalizationKeepsRequiredIdentityVisibleAndRepairsColumns() {
        let malformedLayout = SecondaryTableLayoutPreference(
            hiddenColumnIDs: [
                SecondaryTableColumnID.Files.name,
                SecondaryTableColumnID.Files.progress,
                "removed-column"
            ],
            sortPreference: SecondaryTableSortPreference(
                columnID: "removed-column",
                direction: .descending
            )
        )

        let restored = SecondaryTableLayoutPreference.restored(
            from: malformedLayout.rawValue,
            for: .files
        )

        XCTAssertEqual(restored.hiddenColumnIDs, [SecondaryTableColumnID.Files.progress])
        XCTAssertTrue(restored.isColumnVisible(SecondaryTableColumnID.Files.name, for: .files))
        XCTAssertEqual(restored.sortPreference, SecondaryTableDefaults.fileSort)
    }

    func testMalformedLayoutFallsBackAndDefaultsCanBeRestored() {
        XCTAssertEqual(
            SecondaryTableLayoutPreference.restored(from: "not-json", for: .trackers),
            SecondaryTableLayoutPreference.defaults(for: .trackers)
        )

        let customized = SecondaryTableLayoutPreference(
            hiddenColumnIDs: [SecondaryTableColumnID.Trackers.status],
            sortPreference: SecondaryTableSortPreference(
                columnID: SecondaryTableColumnID.Trackers.seeds,
                direction: .descending
            )
        )

        XCTAssertEqual(
            customized.restoringDefaults(for: .trackers),
            SecondaryTableLayoutPreference.defaults(for: .trackers)
        )
    }

    func testFileProjectionCommitRequiresSameOwnerAndSnapshotBeforeAndAfterBuild() throws {
        let firstRevision = TorrentFilesSnapshotRevision(
            rawValue: try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000021"))
        )
        let replacementRevision = TorrentFilesSnapshotRevision(
            rawValue: try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000022"))
        )
        let expected = try XCTUnwrap(
            TorrentFilesProjectionIdentity(
                detail: TorrentDetail(id: 21, filesSnapshotRevision: firstRevision)
            )
        )
        let replacement = try XCTUnwrap(
            TorrentFilesProjectionIdentity(
                detail: TorrentDetail(id: 21, filesSnapshotRevision: replacementRevision)
            )
        )
        let otherTorrent = try XCTUnwrap(
            TorrentFilesProjectionIdentity(
                detail: TorrentDetail(id: 22, filesSnapshotRevision: firstRevision)
            )
        )

        XCTAssertTrue(
            TorrentFilesProjectionCommitGuard.canCommit(
                expectedIdentity: expected,
                projectionOwnerIdentity: expected,
                currentIdentity: expected
            )
        )
        XCTAssertFalse(
            TorrentFilesProjectionCommitGuard.canCommit(
                expectedIdentity: expected,
                projectionOwnerIdentity: replacement,
                currentIdentity: expected
            )
        )
        XCTAssertFalse(
            TorrentFilesProjectionCommitGuard.canCommit(
                expectedIdentity: expected,
                projectionOwnerIdentity: expected,
                currentIdentity: replacement
            )
        )
        XCTAssertFalse(
            TorrentFilesProjectionCommitGuard.canCommit(
                expectedIdentity: expected,
                projectionOwnerIdentity: expected,
                currentIdentity: otherTorrent
            )
        )
    }

    func testPeerAndTrackerSnapshotReplacementIsPaneScoped() throws {
        let peerRevision = TorrentPeersSnapshotRevision(
            rawValue: try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000031"))
        )
        let nextPeerRevision = TorrentPeersSnapshotRevision(
            rawValue: try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000032"))
        )
        let trackerRevision = TorrentTrackersSnapshotRevision(
            rawValue: try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000033"))
        )
        let nextTrackerRevision = TorrentTrackersSnapshotRevision(
            rawValue: try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000034"))
        )
        let current = TorrentDetail(
            id: 31,
            peersSnapshotRevision: peerRevision,
            trackersSnapshotRevision: trackerRevision
        )
        let incoming = TorrentDetail(
            id: 31,
            peersSnapshotRevision: nextPeerRevision,
            trackersSnapshotRevision: nextTrackerRevision
        )

        XCTAssertEqual(current.replacing(.overview, with: incoming).peersSnapshotRevision, peerRevision)
        XCTAssertEqual(current.replacing(.overview, with: incoming).trackersSnapshotRevision, trackerRevision)
        XCTAssertEqual(current.replacing(.peers, with: incoming).peersSnapshotRevision, nextPeerRevision)
        XCTAssertEqual(current.replacing(.peers, with: incoming).trackersSnapshotRevision, trackerRevision)
        XCTAssertEqual(current.replacing(.trackers, with: incoming).peersSnapshotRevision, peerRevision)
        XCTAssertEqual(current.replacing(.trackers, with: incoming).trackersSnapshotRevision, nextTrackerRevision)
    }

    func testPeerAndTrackerProjectionCommitGuardsRejectStaleOwners() throws {
        let peerRevision = TorrentPeersSnapshotRevision(
            rawValue: try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000041"))
        )
        let nextPeerRevision = TorrentPeersSnapshotRevision(
            rawValue: try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000042"))
        )
        let trackerRevision = TorrentTrackersSnapshotRevision(
            rawValue: try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000043"))
        )
        let nextTrackerRevision = TorrentTrackersSnapshotRevision(
            rawValue: try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000044"))
        )
        let peerIdentity = try XCTUnwrap(
            TorrentPeersProjectionIdentity(
                detail: TorrentDetail(id: 41, peersSnapshotRevision: peerRevision)
            )
        )
        let nextPeerIdentity = try XCTUnwrap(
            TorrentPeersProjectionIdentity(
                detail: TorrentDetail(id: 41, peersSnapshotRevision: nextPeerRevision)
            )
        )
        let trackerIdentity = try XCTUnwrap(
            TorrentTrackersProjectionIdentity(
                detail: TorrentDetail(id: 41, trackersSnapshotRevision: trackerRevision)
            )
        )
        let nextTrackerIdentity = try XCTUnwrap(
            TorrentTrackersProjectionIdentity(
                detail: TorrentDetail(id: 41, trackersSnapshotRevision: nextTrackerRevision)
            )
        )

        XCTAssertTrue(
            TorrentPeersProjectionCommitGuard.canCommit(
                expectedIdentity: peerIdentity,
                projectionOwnerIdentity: peerIdentity,
                currentIdentity: peerIdentity
            )
        )
        XCTAssertFalse(
            TorrentPeersProjectionCommitGuard.canCommit(
                expectedIdentity: peerIdentity,
                projectionOwnerIdentity: peerIdentity,
                currentIdentity: nextPeerIdentity
            )
        )
        XCTAssertTrue(
            TorrentTrackersProjectionCommitGuard.canCommit(
                expectedIdentity: trackerIdentity,
                projectionOwnerIdentity: trackerIdentity,
                currentIdentity: trackerIdentity
            )
        )
        XCTAssertFalse(
            TorrentTrackersProjectionCommitGuard.canCommit(
                expectedIdentity: trackerIdentity,
                projectionOwnerIdentity: nextTrackerIdentity,
                currentIdentity: trackerIdentity
            )
        )
    }

    func testTrackerEditorOwnerSurvivesBenignRefreshAndRejectsChangedOrMissingTarget() throws {
        let revision = TorrentTrackersSnapshotRevision(
            rawValue: try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000051"))
        )
        let replacementRevision = TorrentTrackersSnapshotRevision(
            rawValue: try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000052"))
        )
        let selectedTracker = tracker(
            index: 0,
            id: 9,
            announce: "https://tracker.example/announce",
            seeds: 4
        )
        let current = TorrentDetail(
            id: 51,
            trackers: [selectedTracker],
            trackersSnapshotRevision: revision
        )
        let owner = try XCTUnwrap(TrackerEditorOwner(detail: current, tracker: selectedTracker))
        let addOwner = try XCTUnwrap(TrackerEditorOwner(detail: current, tracker: nil))
        let benignRefresh = TorrentDetail(
            id: 51,
            trackers: [selectedTracker],
            trackersSnapshotRevision: replacementRevision
        )

        XCTAssertTrue(owner.matches(detail: current, requiresTracker: true))
        XCTAssertTrue(owner.matches(detail: benignRefresh, requiresTracker: true))
        XCTAssertTrue(addOwner.matches(detail: benignRefresh, requiresTracker: false))
        var replacedTracker = selectedTracker
        replacedTracker.announce = "https://replacement.example/announce"
        XCTAssertFalse(
            owner.matches(
                detail: TorrentDetail(
                    id: 51,
                    trackers: [replacedTracker],
                    trackersSnapshotRevision: replacementRevision
                ),
                requiresTracker: true
            )
        )
        XCTAssertFalse(
            owner.matches(
                detail: TorrentDetail(
                    id: 51,
                    trackers: [],
                    trackersSnapshotRevision: replacementRevision
                ),
                requiresTracker: true
            )
        )
        XCTAssertFalse(
            owner.matches(
                detail: TorrentDetail(
                    id: 52,
                    trackers: [selectedTracker],
                    trackersSnapshotRevision: revision
                ),
                requiresTracker: true
            )
        )
        XCTAssertFalse(
            addOwner.matches(
                detail: TorrentDetail(
                    id: 52,
                    trackers: [selectedTracker],
                    trackersSnapshotRevision: replacementRevision
                ),
                requiresTracker: false
            )
        )
    }

    func testPeerAndTrackerIDsRemainStableWhenRPCOrderChanges() {
        let peerRows: [RPCArguments] = [
            [
                "address": .string("192.0.2.20"),
                "port": .int(51413),
                "clientName": .string("Alpha"),
                "country": .string("AU")
            ],
            [
                "address": .string("192.0.2.20"),
                "port": .int(51413),
                "clientName": .string("Alpha"),
                "country": .string("NZ")
            ]
        ]
        let trackerRows: [RPCArguments] = [
            [
                "id": .int(7),
                "announce": .string("https://tracker.example/announce"),
                "host": .string("a.tracker.example")
            ],
            [
                "id": .int(7),
                "announce": .string("https://tracker.example/announce"),
                "host": .string("b.tracker.example")
            ]
        ]
        let first = TorrentDetail(
            torrent: TorrentGetTorrent(
                json: [
                    "id": .int(61),
                    "peers": .array(peerRows.map(JSONValue.object)),
                    "trackerStats": .array(trackerRows.map(JSONValue.object))
                ]
            )
        )
        let reordered = TorrentDetail(
            torrent: TorrentGetTorrent(
                json: [
                    "id": .int(61),
                    "peers": .array(peerRows.reversed().map(JSONValue.object)),
                    "trackerStats": .array(trackerRows.reversed().map(JSONValue.object))
                ]
            )
        )
        let survivingPeer = TorrentDetail(
            torrent: TorrentGetTorrent(
                json: [
                    "id": .int(61),
                    "peers": .array([.object(peerRows[1])])
                ]
            )
        )

        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: first.peers.map { ("\($0.clientName)|\($0.country)", $0.id) }),
            Dictionary(uniqueKeysWithValues: reordered.peers.map { ("\($0.clientName)|\($0.country)", $0.id) })
        )
        XCTAssertEqual(
            first.peers.first(where: { $0.country == "NZ" })?.id,
            survivingPeer.peers.first?.id
        )
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: first.trackers.map { ($0.host, $0.id) }),
            Dictionary(uniqueKeysWithValues: reordered.trackers.map { ($0.host, $0.id) })
        )
        XCTAssertEqual(Set(first.peers.map(\.id)).count, 2)
        XCTAssertEqual(Set(first.trackers.map(\.id)).count, 2)
    }

    func testFocusedSelectionActionFailsClosedWithoutActiveFocusedCurrentProjection() {
        let availableIDs: Set<Int> = [1, 2, 3]

        XCTAssertEqual(
            SecondaryTableFocusedSelectionAction.selectAll(
                isActive: true,
                ownsFocus: true,
                ownsCurrentProjection: true,
                availableIDs: availableIDs
            ),
            availableIDs
        )
        XCTAssertNil(
            SecondaryTableFocusedSelectionAction.selectAll(
                isActive: false,
                ownsFocus: true,
                ownsCurrentProjection: true,
                availableIDs: availableIDs
            )
        )
        XCTAssertFalse(
            SecondaryTableFocusedSelectionAction.canCopy(
                isActive: true,
                ownsFocus: false,
                ownsCurrentProjection: true,
                selectedCount: 3
            )
        )
        XCTAssertTrue(
            SecondaryTableFocusedSelectionAction.canCopy(
                isActive: true,
                ownsFocus: true,
                ownsCurrentProjection: true,
                selectedCount: 3
            )
        )
    }

    func testSortPreferenceRoundTripsStableRawValue() {
        let preference = SecondaryTableSortPreference(
            columnID: SecondaryTableColumnID.Peers.download,
            direction: .descending
        )

        XCTAssertEqual(SecondaryTableSortPreference(rawValue: preference.rawValue), preference)
        XCTAssertEqual(preference.rawValue, "torrentDetail.peers.download|descending")
    }

    func testSortPreferenceRejectsMalformedValuesAndNormalizesUnknownColumns() {
        XCTAssertNil(SecondaryTableSortPreference(rawValue: ""))
        XCTAssertNil(SecondaryTableSortPreference(rawValue: "column|sideways"))
        XCTAssertNil(SecondaryTableSortPreference(rawValue: "one|ascending|extra"))

        let unknown = SecondaryTableSortPreference(columnID: "removed-column", direction: .descending)
        XCTAssertEqual(
            unknown.normalized(
                allowedColumnIDs: SecondaryTableColumnID.Files.all,
                default: SecondaryTableDefaults.fileSort
            ),
            SecondaryTableDefaults.fileSort
        )
    }

    func testFileSortPreservesHierarchyAndSortsEachSiblingGroup() throws {
        let tree = TorrentFileNode.tree(from: [
            TorrentFile(id: 0, path: "z-folder", name: "small.bin", length: 1, bytesCompleted: 1, wanted: true, priority: 0),
            TorrentFile(id: 1, path: "a-folder", name: "large.bin", length: 100, bytesCompleted: 50, wanted: true, priority: 1),
            TorrentFile(id: 2, path: "a-folder", name: "tiny.bin", length: 2, bytesCompleted: 0, wanted: false, priority: -1),
            TorrentFile(id: 3, path: "", name: "root.bin", length: 50, bytesCompleted: 50, wanted: true, priority: 0)
        ])

        let sorted = SecondaryTableSorting.files(
            tree,
            by: SecondaryTableSortPreference(
                columnID: SecondaryTableColumnID.Files.size,
                direction: .descending
            )
        )

        XCTAssertEqual(sorted.map(\.name), ["a-folder", "z-folder", "root.bin"])
        XCTAssertEqual(try XCTUnwrap(sorted.first?.children).map(\.name), ["large.bin", "tiny.bin"])
    }

    func testPeerUploadAndDownloadSortUseTransmissionDirections() {
        let peers = [
            peer(index: 0, host: "slow-up", rateToClient: 900, rateToPeer: 1),
            peer(index: 1, host: "fast-up", rateToClient: 2, rateToPeer: 800)
        ]

        XCTAssertEqual(
            SecondaryTableSorting.peers(
                peers,
                by: SecondaryTableSortPreference(
                    columnID: SecondaryTableColumnID.Peers.upload,
                    direction: .descending
                )
            ).map(\.host),
            ["fast-up", "slow-up"]
        )
        XCTAssertEqual(
            SecondaryTableSorting.peers(
                peers,
                by: SecondaryTableSortPreference(
                    columnID: SecondaryTableColumnID.Peers.download,
                    direction: .descending
                )
            ).map(\.host),
            ["slow-up", "fast-up"]
        )
    }

    func testBlankIdlePeerSpeedsKeepRawNumericSorting() {
        let peers = [
            peer(index: 0, host: "slow", rateToClient: 1_024, rateToPeer: 1_024),
            peer(index: 1, host: "idle", rateToClient: 0, rateToPeer: 0),
            peer(index: 2, host: "fast", rateToClient: 8_192, rateToPeer: 8_192)
        ]
        XCTAssertEqual(ByteCountFormatters.speed(peers[1].rateToClient, zeroValue: ""), "")
        XCTAssertEqual(ByteCountFormatters.speed(peers[1].rateToPeer, zeroValue: ""), "")

        for columnID in [SecondaryTableColumnID.Peers.upload, SecondaryTableColumnID.Peers.download] {
            for direction in [SecondaryTableSortDirection.ascending, .descending] {
                let sorted = SecondaryTableSorting.peers(
                    peers,
                    by: SecondaryTableSortPreference(columnID: columnID, direction: direction)
                )
                XCTAssertEqual(sorted.map(\.host), direction == .ascending ? ["idle", "slow", "fast"] : ["fast", "slow", "idle"])
            }
        }
        XCTAssertEqual(peers.map(\.rateToClient), [1_024, 0, 8_192])
        XCTAssertEqual(peers.map(\.rateToPeer), [1_024, 0, 8_192])
    }

    func testFileCompletionPlaceholderKeepsPhysicalZeroLengthAndNumericSorting() throws {
        let tree = TorrentFileNode.tree(from: [
            TorrentFile(id: 0, path: "", name: "empty", length: 0, bytesCompleted: 0, wanted: true, priority: 0),
            TorrentFile(id: 1, path: "", name: "partial", length: 8_192, bytesCompleted: 1_024, wanted: true, priority: 0),
            TorrentFile(id: 2, path: "", name: "full", length: 16_384, bytesCompleted: 16_384, wanted: true, priority: 0)
        ])
        let empty = try XCTUnwrap(tree.first { $0.name == "empty" })
        XCTAssertEqual(TorrentDetailFormatters.size(empty.length), ByteCountFormatters.fileSize(0))
        XCTAssertEqual(ByteCountFormatters.transferSize(empty.bytesCompleted), "—")
        for direction in [SecondaryTableSortDirection.ascending, .descending] {
            let sorted = SecondaryTableSorting.files(
                tree,
                by: SecondaryTableSortPreference(columnID: SecondaryTableColumnID.Files.completed, direction: direction)
            )
            XCTAssertEqual(sorted.map(\.name), direction == .ascending ? ["empty", "partial", "full"] : ["full", "partial", "empty"])
        }
        XCTAssertEqual(empty.length, 0)
        XCTAssertEqual(empty.bytesCompleted, 0)
    }

    func testTrackerSortUsesDeterministicIDTieBreak() {
        let trackers = [
            tracker(index: 1, id: 2, announce: "https://b.example/announce", seeds: 4),
            tracker(index: 0, id: 1, announce: "https://a.example/announce", seeds: 4)
        ]

        XCTAssertEqual(
            SecondaryTableSorting.trackers(
                trackers,
                by: SecondaryTableSortPreference(
                    columnID: SecondaryTableColumnID.Trackers.seeds,
                    direction: .descending
                )
            ).map(\.trackerID),
            [1, 2]
        )
    }

    private func peer(
        index: Int,
        host: String,
        rateToClient: Int64,
        rateToPeer: Int64
    ) -> TorrentPeer {
        TorrentPeer(
            index: index,
            json: [
                "address": .string(host),
                "port": .int(51413),
                "rateToClient": .int(Int(rateToClient)),
                "rateToPeer": .int(Int(rateToPeer))
            ]
        )
    }

    private func tracker(
        index: Int,
        id: Int,
        announce: String,
        seeds: Int
    ) -> TorrentTracker {
        TorrentTracker(
            index: index,
            json: [
                "id": .int(id),
                "announce": .string(announce),
                "seederCount": .int(seeds),
                "hasAnnounced": .bool(true),
                "lastAnnounceSucceeded": .bool(true)
            ],
            fallbackNextAnnounceDate: nil
        )
    }
}
