// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation

enum TorrentDetailPane: Hashable, Sendable {
    case overview
    case files
    case peers
    case trackers
    case statistics

    var needsRPCRefresh: Bool {
        self != .statistics
    }

    /// Returns the narrow, version-aware field set for this detail pane.
    func rpcFields(rpcVersion: Int) -> [String] {
        let fields: [String]

        switch self {
        case .overview:
            fields = overviewFieldRequirements.compactMap { requirement in
                requirement.isSupported(by: rpcVersion) ? requirement.field : nil
            }
        case .files:
            fields = [
                "downloadDir", "fileStats", "files", "hashString", "id", "priorities", "wanted",
            ]
        case .peers:
            fields = ["hashString", "id", "peers"]
        case .trackers:
            fields = rpcVersion >= 7
                ? ["hashString", "id", "trackerStats"]
                : ["hashString", "id", "nextAnnounceTime", "trackers"]
        case .statistics:
            fields = []
        }

        return Array(Set(fields)).sorted()
    }

    private var overviewFieldRequirements: [TorrentRPCFieldRequirement] {
        [
            TorrentRPCFieldRequirement("activityDate"),
            TorrentRPCFieldRequirement("addedDate"),
            TorrentRPCFieldRequirement("announceResponse", maximumRPCVersion: 6),
            TorrentRPCFieldRequirement("bandwidthPriority"),
            TorrentRPCFieldRequirement("comment"),
            TorrentRPCFieldRequirement("corruptEver"),
            TorrentRPCFieldRequirement("creator"),
            TorrentRPCFieldRequirement("dateCreated"),
            TorrentRPCFieldRequirement("desiredAvailable"),
            TorrentRPCFieldRequirement("doneDate"),
            TorrentRPCFieldRequirement("downloadDir"),
            TorrentRPCFieldRequirement("downloadLimit"),
            TorrentRPCFieldRequirement("downloadLimitMode", maximumRPCVersion: 4),
            TorrentRPCFieldRequirement("downloadLimited", minimumRPCVersion: 5),
            TorrentRPCFieldRequirement("downloadedEver"),
            TorrentRPCFieldRequirement("error"),
            TorrentRPCFieldRequirement("errorString"),
            TorrentRPCFieldRequirement("eta"),
            TorrentRPCFieldRequirement("hashString"),
            TorrentRPCFieldRequirement("haveUnchecked"),
            TorrentRPCFieldRequirement("haveValid"),
            TorrentRPCFieldRequirement("id"),
            TorrentRPCFieldRequirement("isPrivate"),
            TorrentRPCFieldRequirement("labels", minimumRPCVersion: 16),
            TorrentRPCFieldRequirement("leechers", maximumRPCVersion: 6),
            TorrentRPCFieldRequirement("leftUntilDone"),
            TorrentRPCFieldRequirement("magnetLink", minimumRPCVersion: 7),
            TorrentRPCFieldRequirement("maxConnectedPeers"),
            TorrentRPCFieldRequirement("metadataPercentComplete", minimumRPCVersion: 7),
            TorrentRPCFieldRequirement("nextAnnounceTime", maximumRPCVersion: 6),
            TorrentRPCFieldRequirement("peersGettingFromUs"),
            TorrentRPCFieldRequirement("peersSendingToUs"),
            TorrentRPCFieldRequirement("pieceCount"),
            TorrentRPCFieldRequirement("pieceSize"),
            TorrentRPCFieldRequirement("pieces", minimumRPCVersion: 5),
            TorrentRPCFieldRequirement("queuePosition"),
            TorrentRPCFieldRequirement("rateDownload"),
            TorrentRPCFieldRequirement("rateUpload"),
            TorrentRPCFieldRequirement("secondsDownloading"),
            TorrentRPCFieldRequirement("secondsSeeding"),
            TorrentRPCFieldRequirement("seeders", maximumRPCVersion: 6),
            TorrentRPCFieldRequirement("sizeWhenDone"),
            TorrentRPCFieldRequirement("status"),
            TorrentRPCFieldRequirement("totalSize"),
            TorrentRPCFieldRequirement("trackers", maximumRPCVersion: 6),
            TorrentRPCFieldRequirement("trackerStats", minimumRPCVersion: 7),
            TorrentRPCFieldRequirement("uploadLimit"),
            TorrentRPCFieldRequirement("uploadLimitMode", maximumRPCVersion: 4),
            TorrentRPCFieldRequirement("uploadLimited", minimumRPCVersion: 5),
            TorrentRPCFieldRequirement("uploadRatio"),
            TorrentRPCFieldRequirement("uploadedEver"),
        ]
    }
}
