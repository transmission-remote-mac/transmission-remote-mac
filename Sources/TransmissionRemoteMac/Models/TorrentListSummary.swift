// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation

struct TorrentListSummary: Equatable {
    var filteredCount: Int
    var totalCount: Int
    var selectedCount: Int
    var selectedSize: Int64
    var filteredSize: Int64
    var downloadSpeed: Int64
    var uploadSpeed: Int64
    var freeSpace: Int64?

    init(
        visibleTorrents: [TorrentSummary],
        totalTorrents: [TorrentSummary],
        selectedIDs: Set<TorrentSummary.ID>,
        sessionStats: SessionStats?,
        sessionInfo: SessionInfo?
    ) {
        filteredCount = visibleTorrents.count
        totalCount = totalTorrents.count

        let selectedTorrents = totalTorrents.filter { selectedIDs.contains($0.id) }
        selectedCount = selectedTorrents.count
        selectedSize = selectedTorrents.reduce(0) { $0 + Self.displaySize(for: $1) }
        filteredSize = visibleTorrents.reduce(0) { $0 + Self.displaySize(for: $1) }

        if let sessionStats {
            downloadSpeed = sessionStats.downloadSpeed
            uploadSpeed = sessionStats.uploadSpeed
        } else {
            downloadSpeed = totalTorrents.reduce(0) { $0 + max(0, $1.rateDownload) }
            uploadSpeed = totalTorrents.reduce(0) { $0 + max(0, $1.rateUpload) }
        }

        freeSpace = sessionInfo?.downloadDirFreeSpace
    }

    var countDisplay: String {
        filteredCount == totalCount ? "\(totalCount) torrents" : "\(filteredCount) of \(totalCount) torrents"
    }

    var selectedDisplay: String {
        guard selectedCount > 0 else {
            return "No selection"
        }
        let noun = selectedCount == 1 ? "torrent" : "torrents"
        return "\(selectedCount) selected \(noun) · \(ByteCountFormatters.fileSize(selectedSize))"
    }

    var filteredSizeDisplay: String {
        "Filtered: \(ByteCountFormatters.fileSize(filteredSize))"
    }

    var speedDisplay: String {
        "↓ \(ByteCountFormatters.speed(downloadSpeed))  ↑ \(ByteCountFormatters.speed(uploadSpeed))"
    }

    var freeSpaceDisplay: String? {
        guard let freeSpace, freeSpace >= 0 else { return nil }
        return "Free: \(ByteCountFormatters.fileSize(freeSpace))"
    }

    private static func displaySize(for torrent: TorrentSummary) -> Int64 {
        torrent.displaySize
    }
}
