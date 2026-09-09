// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation

enum TorrentDetailPollingLane: Equatable, Sendable {
    case regular
    case slow
}

struct TorrentDetailPrefetchPolicy: Equatable, Sendable {
    static let standard = TorrentDetailPrefetchPolicy(
        maximumTorrentSizeBytes: Int64(256) * 1_024 * 1_024 * 1_024,
        panesInPriorityOrder: [.overview, .trackers, .peers]
    )

    var maximumTorrentSizeBytes: Int64
    var panesInPriorityOrder: [TorrentDetailPane]

    init(
        maximumTorrentSizeBytes: Int64,
        panesInPriorityOrder: [TorrentDetailPane] = [.overview, .trackers, .peers]
    ) {
        self.maximumTorrentSizeBytes = max(0, maximumTorrentSizeBytes)
        var seen = Set<TorrentDetailPane>()
        self.panesInPriorityOrder = panesInPriorityOrder.filter { pane in
            pane.needsRPCRefresh && pane != .files && seen.insert(pane).inserted
        }
    }

    func panes(
        for torrent: TorrentSummary,
        excluding activePane: TorrentDetailPane
    ) -> [TorrentDetailPane] {
        guard torrent.displaySize > 0, torrent.displaySize <= maximumTorrentSizeBytes else {
            return []
        }
        return panesInPriorityOrder.filter { $0 != activePane }
    }
}

struct TorrentDetailRefreshPolicy: Equatable, Sendable {
    static let standard = TorrentDetailRefreshPolicy(
        slowPollingMultiplier: 5,
        prefetchPolicy: nil
    )

    static let rpcPanes: [TorrentDetailPane] = [.overview, .files, .peers, .trackers]

    var slowPollingMultiplier: Int
    var prefetchPolicy: TorrentDetailPrefetchPolicy?

    init(
        slowPollingMultiplier: Int = 5,
        prefetchPolicy: TorrentDetailPrefetchPolicy? = nil
    ) {
        self.slowPollingMultiplier = max(1, slowPollingMultiplier)
        self.prefetchPolicy = prefetchPolicy
    }

    func pollingLane(
        for pane: TorrentDetailPane,
        visibility: PollingVisibilityState
    ) -> TorrentDetailPollingLane? {
        guard visibility == .foreground else { return nil }
        switch pane {
        case .overview, .peers:
            return .regular
        case .trackers:
            return .slow
        case .files, .statistics:
            return nil
        }
    }

    func shouldPoll(
        pane: TorrentDetailPane,
        visibility: PollingVisibilityState,
        regularTick: Int
    ) -> Bool {
        switch pollingLane(for: pane, visibility: visibility) {
        case .regular:
            true
        case .slow:
            regularTick > 0 && regularTick.isMultiple(of: slowPollingMultiplier)
        case nil:
            false
        }
    }

    func prefetchPanes(
        for torrent: TorrentSummary,
        excluding activePane: TorrentDetailPane
    ) -> [TorrentDetailPane] {
        prefetchPolicy?.panes(for: torrent, excluding: activePane) ?? []
    }
}

struct TorrentMutationInvalidation: Equatable, Sendable {
    var refreshTorrentRows: Bool
    var detailPanes: Set<TorrentDetailPane>

    static let rowsOnly = TorrentMutationInvalidation(
        refreshTorrentRows: true,
        detailPanes: []
    )
}

enum TorrentMutationKind: Equatable, Sendable {
    case state
    case verify
    case reannounce
    case queue
    case bandwidthPriority
    case labels
    case location
    case rename
    case removal
    case properties(TorrentPropertiesUpdate)
    case files
    case trackers
}

struct TorrentMutationRefreshPolicy: Sendable {
    func requiresPieceRevalidation(after mutation: TorrentMutationKind) -> Bool {
        switch mutation {
        case .verify, .location, .rename, .removal: true
        default: false
        }
    }

    func invalidation(for mutation: TorrentMutationKind) -> TorrentMutationInvalidation {
        switch mutation {
        case .state, .queue, .bandwidthPriority:
            .rowsOnly
        case .verify:
            TorrentMutationInvalidation(refreshTorrentRows: true, detailPanes: [.overview, .files])
        case .labels, .location:
            TorrentMutationInvalidation(refreshTorrentRows: true, detailPanes: [.overview])
        case .rename:
            TorrentMutationInvalidation(refreshTorrentRows: true, detailPanes: [.overview, .files])
        case .removal:
            TorrentMutationInvalidation(refreshTorrentRows: true, detailPanes: Set(TorrentDetailRefreshPolicy.rpcPanes))
        case .reannounce:
            TorrentMutationInvalidation(refreshTorrentRows: true, detailPanes: [.trackers])
        case .properties(let update):
            TorrentMutationInvalidation(
                refreshTorrentRows: true,
                detailPanes: update.trackerEdit == nil ? [] : [.trackers]
            )
        case .files:
            TorrentMutationInvalidation(refreshTorrentRows: true, detailPanes: [.files])
        case .trackers:
            TorrentMutationInvalidation(refreshTorrentRows: true, detailPanes: [.trackers])
        }
    }
}
