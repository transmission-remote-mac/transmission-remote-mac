// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation

struct TorrentSummary: Identifiable, Hashable, Sendable {
    let id: Int
    var name: String
    var status: TorrentStatus
    var errorString: String
    var trackerError: String
    var globalError: String
    var trackerStatus: String
    var percentDone: Double
    var totalSize: Int64
    var sizeWhenDone: Int64
    var sizeToDownload: Int64
    var leftUntilDone: Int64
    var rateDownload: Int64
    var rateUpload: Int64
    var eta: Int
    var uploadRatio: Double
    var downloadedEver: Int64
    var uploadedEver: Int64
    var downloadDir: String
    var bandwidthPriority: Int
    var queuePosition: Int
    var secondsSeeding: Int
    var isPrivate: Bool
    var isMetadataComplete: Bool
    var seedsConnected: Int
    var seedsTotal: Int
    var peersConnected: Int
    var peersTotal: Int
    var labels: [String]
    var trackerHost: String
    var addedDate: Date?
    var completedDate: Date?
    var activityDate: Date?
    var haveValid: Int64?
    var haveUnchecked: Int64?
    var pieceCount: Int?
    var pieceSize: Int64?
    var metadataPercentComplete: Double?
    var reportedTotalSize: Int64?
    var reportedSizeWhenDone: Int64?
    var reportedLeftUntilDone: Int64?
    var hashString: String
    var detailState: TorrentDetailLoadState

    init(
        id: Int,
        name: String,
        status: TorrentStatus,
        errorString: String,
        trackerError: String,
        globalError: String,
        trackerStatus: String,
        percentDone: Double,
        totalSize: Int64,
        sizeWhenDone: Int64,
        sizeToDownload: Int64,
        leftUntilDone: Int64,
        rateDownload: Int64,
        rateUpload: Int64,
        eta: Int,
        uploadRatio: Double,
        downloadedEver: Int64,
        uploadedEver: Int64,
        downloadDir: String,
        bandwidthPriority: Int,
        queuePosition: Int,
        secondsSeeding: Int,
        isPrivate: Bool,
        isMetadataComplete: Bool,
        seedsConnected: Int,
        seedsTotal: Int,
        peersConnected: Int,
        peersTotal: Int,
        labels: [String],
        trackerHost: String,
        addedDate: Date?,
        completedDate: Date?,
        activityDate: Date?,
        haveValid: Int64? = nil,
        haveUnchecked: Int64? = nil,
        pieceCount: Int? = nil,
        pieceSize: Int64? = nil,
        metadataPercentComplete: Double? = nil,
        reportedTotalSize: Int64? = nil,
        reportedSizeWhenDone: Int64? = nil,
        reportedLeftUntilDone: Int64? = nil,
        hashString: String = "",
        detailState: TorrentDetailLoadState = .notLoaded
    ) {
        self.id = id
        self.name = name
        self.status = status
        self.errorString = errorString
        self.trackerError = trackerError
        self.globalError = globalError
        self.trackerStatus = trackerStatus
        self.percentDone = percentDone
        self.totalSize = totalSize
        self.sizeWhenDone = sizeWhenDone
        self.sizeToDownload = sizeToDownload
        self.leftUntilDone = leftUntilDone
        self.rateDownload = rateDownload
        self.rateUpload = rateUpload
        self.eta = eta
        self.uploadRatio = uploadRatio
        self.downloadedEver = downloadedEver
        self.uploadedEver = uploadedEver
        self.downloadDir = downloadDir
        self.bandwidthPriority = bandwidthPriority
        self.queuePosition = queuePosition
        self.secondsSeeding = secondsSeeding
        self.isPrivate = isPrivate
        self.isMetadataComplete = isMetadataComplete
        self.seedsConnected = seedsConnected
        self.seedsTotal = seedsTotal
        self.peersConnected = peersConnected
        self.peersTotal = peersTotal
        self.labels = labels
        self.trackerHost = trackerHost
        self.addedDate = addedDate
        self.completedDate = completedDate
        self.activityDate = activityDate
        self.haveValid = haveValid
        self.haveUnchecked = haveUnchecked
        self.pieceCount = pieceCount
        self.pieceSize = pieceSize
        self.metadataPercentComplete = metadataPercentComplete
        self.reportedTotalSize = reportedTotalSize
        self.reportedSizeWhenDone = reportedSizeWhenDone
        self.reportedLeftUntilDone = reportedLeftUntilDone
        self.hashString = hashString
        self.detailState = detailState
    }

    init(json: [String: JSONValue]) {
        self = TorrentMapper.map(TorrentGetTorrent(json: json), rpcVersion: 14, promoteFinished: false)
    }

    var progressTitle: String {
        percentDone.formatted(.percent.precision(.fractionLength(0)))
    }

    var displaySize: Int64 {
        if sizeWhenDone > 0 { return sizeWhenDone }
        if totalSize > 0 { return totalSize }
        if sizeToDownload > 0 { return sizeToDownload }
        return 0
    }

    var completedSize: Int64 {
        guard sizeWhenDone >= 0 else { return -1 }
        return max(0, sizeWhenDone - leftUntilDone)
    }

    var reportedCompletedSize: Int64? {
        guard metadataPercentComplete == 1,
              let size = reportedSizeWhenDone, size >= 0,
              let left = reportedLeftUntilDone, left >= 0, left <= size else {
            return nil
        }
        return size - left
    }

    var downloadedDataSize: Int64 {
        if haveValid != nil || haveUnchecked != nil {
            let validBytes = max(0, haveValid ?? 0)
            let uncheckedBytes = max(0, haveUnchecked ?? 0)
            let result = validBytes.addingReportingOverflow(uncheckedBytes)
            return result.overflow ? .max : result.partialValue
        }
        return max(0, completedSize)
    }

    var fullPath: String {
        guard !downloadDir.isEmpty else { return name }
        return "\(downloadDir)/\(name)"
    }

    var labelsDisplay: String {
        labels.joined(separator: ", ")
    }

    var labelsDetailDisplay: String {
        labels.isEmpty ? "None" : labelsDisplay
    }

    var trackerStatusDisplay: String {
        if !trackerError.isEmpty { return trackerError }
        if !globalError.isEmpty { return globalError }
        if !trackerStatus.isEmpty { return trackerStatus }
        return "—"
    }

    var addedSortDate: Date {
        addedDate ?? .distantPast
    }

    var completedSortDate: Date {
        completedDate ?? .distantPast
    }

    var activitySortDate: Date {
        activityDate ?? .distantPast
    }

    var priorityTitle: String {
        switch bandwidthPriority {
        case 1: "High"
        case 0: "Normal"
        case -1: "Low"
        default: "\(bandwidthPriority)"
        }
    }

    var queuePositionTitle: String {
        queuePosition >= 0 ? "\(queuePosition)" : "—"
    }

    var privacyTitle: String {
        isPrivate ? "Private" : "Public"
    }

    var privacySortValue: Int {
        isPrivate ? 1 : 0
    }

    var metadataTitle: String {
        isMetadataComplete ? "Complete" : "Fetching metadata"
    }

    var seedsDisplay: String {
        connectedCountDisplay(seedsConnected, total: seedsTotal)
    }

    var peersDisplay: String {
        connectedCountDisplay(peersConnected, total: peersTotal)
    }

    private func connectedCountDisplay(_ connected: Int, total: Int) -> String {
        total >= 0 ? "\(connected) of \(total) connected" : "\(connected) connected"
    }
}
