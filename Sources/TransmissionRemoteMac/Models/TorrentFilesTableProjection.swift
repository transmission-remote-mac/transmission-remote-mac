// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation

struct TorrentFilesTableProjection {
    let tree: [TorrentFileNode]
    let planner: TorrentFileSelectionPlanner
}

struct TorrentFileLocalActionCapabilityRequest: Equatable {
    let identity: TorrentFilesProjectionIdentity
    let mapping: TorrentFileLocalActionMapping
    let downloadDirectory: String
    /// Empty means download-root preflight only, for optimistic context-menu hints.
    let selection: Set<TorrentFileNode.ID>
}

/// Only path ownership/policy participates in capability invalidation, not
/// credentials, add rules, or unrelated connection preferences.
struct TorrentFileLocalActionMapping: Equatable {
    let profileID: UUID
    let host: String
    let pathMappings: [PathMapping]

    init(profile: ConnectionProfile) {
        profileID = profile.id
        host = profile.host
        pathMappings = profile.pathMappings
    }
}
