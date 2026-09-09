// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation

enum TorrentMapper {
    static let unknownSize: Int64 = -1
    static let unknownETA = -1

    static func map(_ torrent: TorrentGetTorrent, rpcVersion: Int, promoteFinished: Bool = true) -> TorrentSummary {
        let empty = TorrentSummary(
            id: torrent.id,
            name: "Unknown",
            status: .unknown,
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
            eta: unknownETA,
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
            seedsTotal: -1,
            peersConnected: 0,
            peersTotal: -1,
            labels: [],
            trackerHost: "No tracker",
            addedDate: nil,
            completedDate: nil,
            activityDate: nil
        )
        return merging(
            torrent,
            into: empty,
            rpcVersion: rpcVersion,
            promoteFinished: promoteFinished
        )
    }

    /// Applies a partial list refresh without retaining its untyped RPC object.
    /// Full and targeted list responses may contain dozens of fields, while
    /// recently-active responses intentionally contain only dynamic fields.
    /// The materialized summary is the durable value; the JSON dictionary is
    /// only transport input for this merge.
    static func merging(
        _ refreshed: TorrentGetTorrent,
        into existing: TorrentSummary,
        rpcVersion: Int,
        promoteFinished: Bool = true
    ) -> TorrentSummary {
        var result = existing

        if let name = refreshed.providedName {
            result.name = name.isEmpty ? "Unknown" : name
        }
        if let hashString = refreshed.hashString {
            result.hashString = hashString.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let hasProgressUpdate = refreshed.status != nil
            || refreshed.metadataPercentComplete != nil
            || refreshed.percentDone != nil
            || refreshed.recheckProgress != nil
            || refreshed.totalSize != nil
            || refreshed.sizeWhenDone != nil
            || refreshed.leftUntilDone != nil
        if let status = refreshed.status {
            result.status = TorrentStatus.mapped(rawStatus: status, rpcVersion: rpcVersion)
        }
        if let metadataPercentComplete = refreshed.metadataPercentComplete {
            result.isMetadataComplete = metadataPercentComplete == 1.0
            result.metadataPercentComplete = metadataPercentComplete
        } else if rpcVersion < 7 {
            result.metadataPercentComplete = 1
        }
        if refreshed.sizeWhenDone != nil || refreshed.metadataPercentComplete != nil {
            result.sizeWhenDone = result.isMetadataComplete
                ? (refreshed.sizeWhenDone ?? result.sizeWhenDone)
                : unknownSize
            result.sizeToDownload = result.sizeWhenDone
        }
        if refreshed.totalSize != nil
            || refreshed.sizeWhenDone != nil
            || refreshed.metadataPercentComplete != nil {
            if !result.isMetadataComplete {
                result.totalSize = unknownSize
            } else if let totalSize = refreshed.totalSize {
                result.totalSize = totalSize
            } else if result.totalSize <= 0, let sizeWhenDone = refreshed.sizeWhenDone {
                result.totalSize = sizeWhenDone
            }
        }
        if let leftUntilDone = refreshed.leftUntilDone {
            result.leftUntilDone = max(0, leftUntilDone)
        }
        if promoteFinished,
           result.status == .stopped,
           result.leftUntilDone == 0,
           result.sizeWhenDone > 0 {
            result.status = .finished
        }
        if hasProgressUpdate {
            result.percentDone = normalizedProgress(
                status: result.status,
                recheckProgress: refreshed.recheckProgress,
                percentDone: refreshed.percentDone ?? result.percentDone,
                sizeWhenDone: max(0, result.sizeWhenDone),
                leftUntilDone: result.leftUntilDone
            )
        }

        if refreshed.trackerStats != nil
            || refreshed.announceResponse != nil
            || refreshed.errorString != nil
            || refreshed.status != nil {
            let errors = TorrentErrorMapper.merging(
                refreshed,
                into: TorrentMappedError(
                    displayError: result.errorString,
                    trackerError: result.trackerError,
                    globalError: result.globalError,
                    trackerStatus: result.trackerStatus
                ),
                status: result.status,
                rpcVersion: rpcVersion
            )
            result.errorString = errors.displayError
            result.trackerError = errors.trackerError
            result.globalError = errors.globalError
            result.trackerStatus = errors.trackerStatus
        }

        if refreshed.trackerStats != nil || refreshed.trackers != nil {
            result.trackerHost = trackerDisplay(refreshed, rpcVersion: rpcVersion)
        }
        if let rateDownload = refreshed.rateDownload { result.rateDownload = max(0, rateDownload) }
        if let rateUpload = refreshed.rateUpload { result.rateUpload = max(0, rateUpload) }
        if refreshed.eta != nil || refreshed.leftUntilDone != nil || refreshed.rateDownload != nil {
            result.eta = normalizedETA(
                refreshed.eta,
                leftUntilDone: result.leftUntilDone,
                rateDownload: result.rateDownload
            )
        }
        if let uploadRatio = refreshed.uploadRatio { result.uploadRatio = normalizedRatio(uploadRatio) }
        if let downloadedEver = refreshed.downloadedEver { result.downloadedEver = max(0, downloadedEver) }
        if let uploadedEver = refreshed.uploadedEver { result.uploadedEver = max(0, uploadedEver) }
        if let downloadDir = refreshed.downloadDir { result.downloadDir = trimmedTrailingSlash(downloadDir) }
        if let bandwidthPriority = refreshed.bandwidthPriority { result.bandwidthPriority = bandwidthPriority }
        if let queuePosition = refreshed.queuePosition { result.queuePosition = queuePosition }
        if let secondsSeeding = refreshed.secondsSeeding { result.secondsSeeding = max(0, secondsSeeding) }
        if let isPrivate = refreshed.isPrivate { result.isPrivate = isPrivate }
        if let peersSendingToUs = refreshed.peersSendingToUs { result.seedsConnected = max(0, peersSendingToUs) }
        if let peersGettingFromUs = refreshed.peersGettingFromUs { result.peersConnected = max(0, peersGettingFromUs) }
        if (rpcVersion >= 7 && refreshed.trackerStats != nil)
            || (rpcVersion < 7 && refreshed.seeders != nil) {
            result.seedsTotal = totalSeeds(refreshed, rpcVersion: rpcVersion)
        }
        if (rpcVersion >= 7 && refreshed.trackerStats != nil)
            || (rpcVersion < 7 && refreshed.leechers != nil) {
            result.peersTotal = totalPeers(refreshed, rpcVersion: rpcVersion)
        }
        if let labels = refreshed.labels { result.labels = labels }
        if refreshed["addedDate"] != nil { result.addedDate = refreshed.addedDate }
        if refreshed["doneDate"] != nil { result.completedDate = refreshed.doneDate }
        if refreshed["activityDate"] != nil { result.activityDate = refreshed.activityDate }
        if let haveValid = refreshed.haveValid { result.haveValid = haveValid }
        if let haveUnchecked = refreshed.haveUnchecked { result.haveUnchecked = haveUnchecked }
        if let pieceCount = refreshed.pieceCount { result.pieceCount = pieceCount }
        if let pieceSize = refreshed.pieceSize { result.pieceSize = pieceSize }
        if let totalSize = refreshed.totalSize { result.reportedTotalSize = totalSize }
        if let size = refreshed.sizeWhenDone { result.reportedSizeWhenDone = size }
        if let left = refreshed.leftUntilDone { result.reportedLeftUntilDone = left }

        return result
    }

    static func normalizedProgress(
        status: TorrentStatus,
        recheckProgress: Double?,
        percentDone: Double?,
        sizeWhenDone: Int64,
        leftUntilDone: Int64
    ) -> Double {
        let progress: Double
        if status == .checking {
            progress = recheckProgress ?? percentDone ?? 0
        } else if sizeWhenDone > 0 {
            progress = Double(sizeWhenDone - leftUntilDone) / Double(sizeWhenDone)
        } else {
            progress = percentDone ?? 0
        }
        return min(max(progress, 0), 1)
    }

    static func normalizedETA(_ eta: Int?, leftUntilDone: Int64, rateDownload: Int64) -> Int {
        if rateDownload > 0 {
            return Int((Double(leftUntilDone) / Double(rateDownload)).rounded())
        }
        guard let eta, eta >= 0 else { return unknownETA }
        return eta
    }

    static func normalizedRatio(_ ratio: Double?) -> Double {
        guard let ratio else { return 0 }
        if ratio == -2 {
            return .infinity
        }
        if ratio < 0 {
            return 0
        }
        return ratio
    }

    static func trackerDisplay(_ torrent: TorrentGetTorrent, rpcVersion: Int) -> String {
        let announce: String?
        if rpcVersion >= 7 {
            let tracker = torrent.trackerStats?.first?.objectValue
            let legacyTracker = torrent.trackers?.first?.objectValue
            announce = tracker?["announce"]?.stringValue
                ?? tracker?["host"]?.stringValue
                ?? legacyTracker?["announce"]?.stringValue
                ?? legacyTracker?["host"]?.stringValue
        } else {
            let tracker = torrent.trackers?.first?.objectValue
            announce = tracker?["announce"]?.stringValue ?? tracker?["host"]?.stringValue
        }
        guard let announce, !announce.isEmpty else { return "No tracker" }
        return filterTrackerURI(announce)
    }

    static func filterTrackerURI(_ string: String) -> String {
        let host: String
        if let url = URL(string: string), let urlHost = url.host {
            host = urlHost
        } else {
            var value = string
            if let schemeRange = value.range(of: "://") {
                value = String(value[schemeRange.upperBound...])
            }
            if let portIndex = value.firstIndex(of: ":") {
                value = String(value[..<portIndex])
            } else if let slashIndex = value.firstIndex(of: "/") {
                value = String(value[..<slashIndex])
            }
            host = value
        }

        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard let first = parts.first?.lowercased(), parts.count > 1 else { return host }
        if first == "bt" || first == "www" || first == "tracker" || (first.count == 3 && first.hasPrefix("bt") && first.last?.isNumber == true) {
            return parts.dropFirst().joined(separator: ".")
        }
        return host
    }

    private static func totalSeeds(_ torrent: TorrentGetTorrent, rpcVersion: Int) -> Int {
        if rpcVersion >= 7 {
            return torrent.trackerStats?.first?.objectValue?["seederCount"]?.intValue ?? -1
        }
        return torrent.seeders ?? -1
    }

    private static func totalPeers(_ torrent: TorrentGetTorrent, rpcVersion: Int) -> Int {
        if rpcVersion >= 7 {
            return torrent.trackerStats?.first?.objectValue?["leecherCount"]?.intValue ?? -1
        }
        return torrent.leechers ?? -1
    }

    private static func trimmedTrailingSlash(_ path: String) -> String {
        guard path.count > 1 else { return path }
        return path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}
