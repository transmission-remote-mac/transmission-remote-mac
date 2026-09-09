// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation

struct SessionStats: Equatable, Sendable {
    var activeTorrentCount: Int
    var pausedTorrentCount: Int
    var torrentCount: Int
    var downloadSpeed: Int64
    var uploadSpeed: Int64
    var current: SessionStatsSnapshot
    var cumulative: SessionStatsSnapshot

    init(arguments: RPCArguments) {
        activeTorrentCount = arguments["activeTorrentCount"]?.intValue ?? 0
        pausedTorrentCount = arguments["pausedTorrentCount"]?.intValue ?? 0
        torrentCount = arguments["torrentCount"]?.intValue ?? 0
        downloadSpeed = arguments["downloadSpeed"]?.int64Value ?? 0
        uploadSpeed = arguments["uploadSpeed"]?.int64Value ?? 0
        current = SessionStatsSnapshot(arguments: arguments["current-stats"]?.objectValue ?? [:])
        cumulative = SessionStatsSnapshot(arguments: arguments["cumulative-stats"]?.objectValue ?? [:])
    }
}

struct SessionStatsSnapshot: Equatable, Sendable {
    var uploadedBytes: Int64
    var downloadedBytes: Int64
    var filesAdded: Int
    var sessionCount: Int
    var secondsActive: Int

    init(arguments: RPCArguments) {
        uploadedBytes = arguments["uploadedBytes"]?.int64Value ?? 0
        downloadedBytes = arguments["downloadedBytes"]?.int64Value ?? 0
        filesAdded = arguments["filesAdded"]?.intValue ?? 0
        sessionCount = arguments["sessionCount"]?.intValue ?? 0
        secondsActive = arguments["secondsActive"]?.intValue ?? 0
    }
}
