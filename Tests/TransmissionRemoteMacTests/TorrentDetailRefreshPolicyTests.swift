// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import XCTest
@testable import TransmissionRemoteMac

final class TorrentDetailRefreshPolicyTests: XCTestCase {
    func testPeriodicCadenceOnlyRefreshesEligibleForegroundPane() {
        let policy = TorrentDetailRefreshPolicy(
            slowPollingMultiplier: 5,
            prefetchPolicy: nil
        )

        for tick in 1...10 {
            XCTAssertTrue(policy.shouldPoll(pane: .overview, visibility: .foreground, regularTick: tick))
            XCTAssertTrue(policy.shouldPoll(pane: .peers, visibility: .foreground, regularTick: tick))
            XCTAssertEqual(
                policy.shouldPoll(pane: .trackers, visibility: .foreground, regularTick: tick),
                tick.isMultiple(of: 5)
            )
            XCTAssertFalse(policy.shouldPoll(pane: .files, visibility: .foreground, regularTick: tick))
            XCTAssertFalse(policy.shouldPoll(pane: .statistics, visibility: .foreground, regularTick: tick))
            XCTAssertFalse(policy.shouldPoll(pane: .overview, visibility: .background, regularTick: tick))
            XCTAssertFalse(policy.shouldPoll(pane: .trackers, visibility: .background, regularTick: tick))
        }
    }

    func testOptionalPrefetchCanBeDisabledAndSkipsLargeOrUnknownTorrents() {
        let smallTorrent = makeTorrent(id: 1, totalSize: 100)
        let largeTorrent = makeTorrent(id: 2, totalSize: 1_001)
        let unknownTorrent = makeTorrent(id: 3, totalSize: 0)
        let enabled = TorrentDetailRefreshPolicy(
            prefetchPolicy: TorrentDetailPrefetchPolicy(maximumTorrentSizeBytes: 1_000)
        )
        let disabled = TorrentDetailRefreshPolicy(prefetchPolicy: nil)

        XCTAssertEqual(
            enabled.prefetchPanes(for: smallTorrent, excluding: .overview),
            [.trackers, .peers]
        )
        XCTAssertTrue(enabled.prefetchPanes(for: largeTorrent, excluding: .overview).isEmpty)
        XCTAssertTrue(enabled.prefetchPanes(for: unknownTorrent, excluding: .overview).isEmpty)
        XCTAssertTrue(disabled.prefetchPanes(for: smallTorrent, excluding: .overview).isEmpty)
    }

    func testStandardIsDemandOnlyAndExplicitPrefetchAlwaysExcludesFiles() {
        let torrent = makeTorrent(id: 1, totalSize: 100)
        let standard = TorrentDetailRefreshPolicy.standard
        let attemptedFilesOverride = TorrentDetailRefreshPolicy(
            prefetchPolicy: TorrentDetailPrefetchPolicy(
                maximumTorrentSizeBytes: 1_000,
                panesInPriorityOrder: [.files, .peers, .trackers, .overview]
            )
        )

        XCTAssertEqual(standard.prefetchPanes(for: torrent, excluding: .overview), [])
        XCTAssertEqual(
            attemptedFilesOverride.prefetchPanes(for: torrent, excluding: .overview),
            [.peers, .trackers]
        )
        XCTAssertFalse(
            attemptedFilesOverride.prefetchPanes(for: torrent, excluding: .peers).contains(.files)
        )
    }

    func testMutationInvalidationScopesAreExact() {
        let policy = TorrentMutationRefreshPolicy()

        for mutation in [
            TorrentMutationKind.state,
            .queue,
            .bandwidthPriority,
        ] {
            XCTAssertEqual(policy.invalidation(for: mutation), .rowsOnly)
        }
        XCTAssertEqual(
            policy.invalidation(for: .verify),
            TorrentMutationInvalidation(refreshTorrentRows: true, detailPanes: [.overview, .files])
        )
        for mutation in [TorrentMutationKind.labels, .location] {
            XCTAssertEqual(
                policy.invalidation(for: mutation),
                TorrentMutationInvalidation(refreshTorrentRows: true, detailPanes: [.overview])
            )
        }
        XCTAssertEqual(
            policy.invalidation(for: .rename),
            TorrentMutationInvalidation(refreshTorrentRows: true, detailPanes: [.overview, .files])
        )
        XCTAssertEqual(
            policy.invalidation(for: .reannounce),
            TorrentMutationInvalidation(refreshTorrentRows: true, detailPanes: [.trackers])
        )
        XCTAssertEqual(
            policy.invalidation(for: .files),
            TorrentMutationInvalidation(refreshTorrentRows: true, detailPanes: [.files])
        )
        XCTAssertEqual(
            policy.invalidation(for: .trackers),
            TorrentMutationInvalidation(refreshTorrentRows: true, detailPanes: [.trackers])
        )

        let generalUpdate = TorrentPropertiesUpdate(peerLimit: 30)
        XCTAssertEqual(policy.invalidation(for: .properties(generalUpdate)), .rowsOnly)

        let trackerUpdate = TorrentPropertiesUpdate(
            trackerEdit: TorrentPropertiesTrackerEdit(
                originalTrackers: [],
                editedText: "https://tracker.example/announce"
            )
        )
        XCTAssertEqual(
            policy.invalidation(for: .properties(trackerUpdate)),
            TorrentMutationInvalidation(refreshTorrentRows: true, detailPanes: [.trackers])
        )
    }

    func testOnlyPhysicalDataMutationsRequireFreshPieceProof() {
        let policy = TorrentMutationRefreshPolicy()
        for mutation in [TorrentMutationKind.verify, .location, .rename, .removal] {
            XCTAssertTrue(policy.requiresPieceRevalidation(after: mutation))
        }
        for mutation in [TorrentMutationKind.labels, .state, .files, .trackers, .queue, .bandwidthPriority] {
            XCTAssertFalse(policy.requiresPieceRevalidation(after: mutation))
        }
        XCTAssertEqual(policy.invalidation(for: .removal).detailPanes, Set(TorrentDetailRefreshPolicy.rpcPanes))
    }

    private func makeTorrent(id: Int, totalSize: Int64) -> TorrentSummary {
        TorrentSummary(json: [
            "id": .int(id),
            "name": .string("Torrent \(id)"),
            "status": .int(0),
            "totalSize": .int(Int(totalSize)),
            "sizeWhenDone": .int(Int(totalSize)),
        ])
    }
}
