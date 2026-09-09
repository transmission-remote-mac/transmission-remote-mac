// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation

enum TorrentDetailLoadState: Hashable, Sendable {
    case notLoaded
    case loading
    case loaded(TorrentDetail)
    case failed(String)

    var detail: TorrentDetail? {
        if case .loaded(let detail) = self { return detail }
        return nil
    }
}

struct TorrentFilesSnapshotRevision: Hashable, Sendable {
    let rawValue: UUID

    init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

struct TorrentPeersSnapshotRevision: Hashable, Sendable {
    let rawValue: UUID

    init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

struct TorrentTrackersSnapshotRevision: Hashable, Sendable {
    let rawValue: UUID

    init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

struct TorrentDetail: Hashable, Sendable {
    var id: Int
    var generalInfo: TorrentGeneralInfo?
    var peers: [TorrentPeer]
    var trackers: [TorrentTracker]
    var files: [TorrentFile]
    var fileTree: [TorrentFileNode]
    var filesSnapshotRevision: TorrentFilesSnapshotRevision?
    var peersSnapshotRevision: TorrentPeersSnapshotRevision?
    var trackersSnapshotRevision: TorrentTrackersSnapshotRevision?

    init(
        id: Int,
        generalInfo: TorrentGeneralInfo? = nil,
        peers: [TorrentPeer] = [],
        trackers: [TorrentTracker] = [],
        files: [TorrentFile] = [],
        filesSnapshotRevision: TorrentFilesSnapshotRevision? = nil,
        peersSnapshotRevision: TorrentPeersSnapshotRevision? = nil,
        trackersSnapshotRevision: TorrentTrackersSnapshotRevision? = nil
    ) {
        self.id = id
        self.generalInfo = generalInfo
        self.peers = peers
        self.trackers = trackers
        self.files = files
        fileTree = TorrentFileNode.tree(from: files)
        self.filesSnapshotRevision = filesSnapshotRevision
        self.peersSnapshotRevision = peersSnapshotRevision
        self.trackersSnapshotRevision = trackersSnapshotRevision
    }

    init(torrent: TorrentGetTorrent, rpcVersion: Int = 14) {
        id = torrent.id
        generalInfo = TorrentGeneralInfo(torrent: torrent, rpcVersion: rpcVersion)
        peers = Self.mapPeers(torrent)
        trackers = Self.mapTrackers(torrent)
        files = TorrentFile.files(from: torrent)
        fileTree = TorrentFileNode.tree(from: files)
        filesSnapshotRevision = torrent.files == nil ? nil : TorrentFilesSnapshotRevision()
        peersSnapshotRevision = torrent.peers == nil ? nil : TorrentPeersSnapshotRevision()
        trackersSnapshotRevision = torrent.trackerStats == nil && torrent.trackers == nil
            ? nil
            : TorrentTrackersSnapshotRevision()
    }

    func replacing(_ pane: TorrentDetailPane, with detail: TorrentDetail) -> TorrentDetail {
        var next = self
        switch pane {
        case .overview:
            next.generalInfo = detail.generalInfo
        case .files:
            next.files = detail.files
            next.fileTree = detail.fileTree
            next.filesSnapshotRevision = detail.filesSnapshotRevision
        case .peers:
            next.peers = detail.peers
            next.peersSnapshotRevision = detail.peersSnapshotRevision
        case .trackers:
            next.trackers = detail.trackers
            next.trackersSnapshotRevision = detail.trackersSnapshotRevision
        case .statistics:
            break
        }
        return next
    }

    /// Preserve projection identity when a refresh contains the same semantic
    /// payload. Freshness is tracked separately by the store, never by a UUID.
    func preservingUnchangedRevision(from previous: TorrentDetail, pane: TorrentDetailPane) -> TorrentDetail {
        guard id == previous.id else { return self }
        var next = self
        switch pane {
        case .files where files == previous.files:
            next.filesSnapshotRevision = previous.filesSnapshotRevision
            next.fileTree = previous.fileTree
        case .peers:
            let previousByID = Dictionary(previous.peers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            next.peers = peers.map { peer in
                previousByID[peer.id].map { peer.reusingResolution(from: $0) } ?? peer
            }
            if next.peers == previous.peers { next.peersSnapshotRevision = previous.peersSnapshotRevision }
        case .trackers where trackers == previous.trackers:
            next.trackersSnapshotRevision = previous.trackersSnapshotRevision
        default:
            break
        }
        return next
    }

    func hasSamePayload(as previous: TorrentDetail, pane: TorrentDetailPane) -> Bool {
        guard id == previous.id else { return false }
        switch pane {
        case .overview: return generalInfo == previous.generalInfo
        case .files: return files == previous.files && generalInfo?.downloadDir == previous.generalInfo?.downloadDir
        case .peers: return peers == previous.peers
        case .trackers: return trackers == previous.trackers
        case .statistics: return true
        }
    }

    private static func mapPeers(_ torrent: TorrentGetTorrent) -> [TorrentPeer] {
        let peers = (torrent.peers ?? []).enumerated().compactMap { index, value -> TorrentPeer? in
            guard let peer = value.objectValue else { return nil }
            return TorrentPeer(index: index, json: peer)
        }
        return assigningStablePeerIDs(peers)
    }

    private static func mapTrackers(_ torrent: TorrentGetTorrent) -> [TorrentTracker] {
        let trackers: [TorrentTracker]
        if let stats = torrent.trackerStats, !stats.isEmpty {
            trackers = stats.enumerated().compactMap { index, value in
                guard let tracker = value.objectValue else { return nil }
                return TorrentTracker(index: index, json: tracker, fallbackNextAnnounceDate: torrent.nextAnnounceDate)
            }
        } else {
            trackers = (torrent.trackers ?? []).enumerated().compactMap { index, value in
                guard let tracker = value.objectValue else { return nil }
                return TorrentTracker(index: index, json: tracker, fallbackNextAnnounceDate: torrent.nextAnnounceDate)
            }
        }
        return assigningStableTrackerIDs(trackers)
    }

    private static func assigningStablePeerIDs(_ peers: [TorrentPeer]) -> [TorrentPeer] {
        assigningStableIDs(
            peers,
            baseID: \TorrentPeer.stableIdentityBase,
            collisionKey: \TorrentPeer.stableCollisionKey
        )
    }

    private static func assigningStableTrackerIDs(_ trackers: [TorrentTracker]) -> [TorrentTracker] {
        assigningStableIDs(
            trackers,
            baseID: \TorrentTracker.stableIdentityBase,
            collisionKey: \TorrentTracker.stableCollisionKey
        )
    }

    private static func assigningStableIDs<Value>(
        _ values: [Value],
        baseID: KeyPath<Value, String>,
        collisionKey: KeyPath<Value, String>
    ) -> [Value] where Value: StableSecondaryRowIdentity {
        let groupedOffsets = Dictionary(grouping: values.indices) { values[$0][keyPath: baseID] }
        var result = values

        for (identityBase, offsets) in groupedOffsets {
            guard offsets.count > 1 else {
                result[offsets[0]].id = identityBase
                continue
            }
            let deterministicOffsets = offsets.sorted {
                let lhsKey = values[$0][keyPath: collisionKey]
                let rhsKey = values[$1][keyPath: collisionKey]
                if lhsKey != rhsKey { return lhsKey < rhsKey }
                return $0 < $1
            }
            for (collisionIndex, offset) in deterministicOffsets.enumerated() {
                result[offset].id = "\(identityBase)#\(collisionIndex + 1)"
            }
        }
        return result
    }
}

protocol StableSecondaryRowIdentity {
    var id: String { get set }
}

struct TorrentFilesProjectionIdentity: Hashable, Sendable {
    var torrentID: Int
    var filesSnapshotRevision: TorrentFilesSnapshotRevision

    init?(detail: TorrentDetail) {
        guard let filesSnapshotRevision = detail.filesSnapshotRevision else { return nil }
        torrentID = detail.id
        self.filesSnapshotRevision = filesSnapshotRevision
    }

    func matches(torrentID: Int, detail: TorrentDetail?) -> Bool {
        guard let detail,
              detail.id == torrentID,
              let detailIdentity = TorrentFilesProjectionIdentity(detail: detail) else {
            return false
        }
        return self == detailIdentity
    }
}

struct TorrentPeersProjectionIdentity: Hashable, Sendable {
    var torrentID: Int
    var peersSnapshotRevision: TorrentPeersSnapshotRevision

    init?(detail: TorrentDetail) {
        guard let peersSnapshotRevision = detail.peersSnapshotRevision else { return nil }
        torrentID = detail.id
        self.peersSnapshotRevision = peersSnapshotRevision
    }

    func matches(detail: TorrentDetail?) -> Bool {
        guard let detail,
              let currentIdentity = TorrentPeersProjectionIdentity(detail: detail) else {
            return false
        }
        return self == currentIdentity
    }
}

struct TorrentTrackersProjectionIdentity: Hashable, Sendable {
    var torrentID: Int
    var trackersSnapshotRevision: TorrentTrackersSnapshotRevision

    init?(detail: TorrentDetail) {
        guard let trackersSnapshotRevision = detail.trackersSnapshotRevision else { return nil }
        torrentID = detail.id
        self.trackersSnapshotRevision = trackersSnapshotRevision
    }

    func matches(detail: TorrentDetail?) -> Bool {
        guard let detail,
              let currentIdentity = TorrentTrackersProjectionIdentity(detail: detail) else {
            return false
        }
        return self == currentIdentity
    }
}

struct TorrentGeneralInfo: Hashable, Sendable {
    var hashString: String
    var status: TorrentStatus?
    var error: Int?
    var errorString: String
    var magnetLink: String
    var comment: String
    var creator: String
    var dateCreated: Date?
    var metadataPercentComplete: Double?
    /// Display overlays must not turn pre-metadata overview values into loaded metadata.
    let hasCompleteMetadataFromOverview: Bool
    var isPrivate: Bool?
    var labels: [String]?
    var totalSize: Int64?
    var sizeWhenDone: Int64?
    var leftUntilDone: Int64?
    var downloadDir: String?
    var addedDate: Date?
    var completedDate: Date?
    var activityDate: Date?
    var pieceCount: Int?
    var pieceSize: Int64?
    var pieceMapState: TorrentPieceMapState
    var isPieceCompletionInvalidated = false
    var haveValid: Int64?
    var haveUnchecked: Int64?
    var downloadedEver: Int64?
    var uploadedEver: Int64?
    var corruptEver: Int64?
    var rateDownload: Int64?
    var rateUpload: Int64?
    var downloadSpeedLimit: TorrentGeneralSpeedLimit?
    var uploadSpeedLimit: TorrentGeneralSpeedLimit?
    var maxConnectedPeers: Int?
    var eta: Int?
    var uploadRatio: Double?
    var bandwidthPriority: Int?
    var queuePosition: Int?
    var peersSendingToUs: Int?
    var peersGettingFromUs: Int?
    var seeders: Int?
    var leechers: Int?
    var trackerHost: String?
    var trackerStatus: String?
    var trackerUpdate: TorrentTrackerUpdate?
    var secondsDownloading: Int?
    var secondsSeeding: Int?
    var desiredAvailable: Int64?

    var isMetadataComplete: Bool? {
        metadataPercentComplete.map { $0 == 1 }
    }

    var completedSize: Int64? {
        guard let sizeWhenDone,
              let leftUntilDone,
              sizeWhenDone >= 0,
              leftUntilDone >= 0,
              leftUntilDone <= sizeWhenDone else {
            return nil
        }
        return sizeWhenDone - leftUntilDone
    }

    func fullPath(torrentName: String) -> String? {
        guard let downloadDir,
              !downloadDir.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !torrentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        if downloadDir.hasSuffix("/") || downloadDir.hasSuffix("\\") {
            return downloadDir + torrentName
        }
        let separator = downloadDir.contains("\\") && !downloadDir.contains("/") ? "\\" : "/"
        return downloadDir + separator + torrentName
    }

    var seedsDisplay: String? {
        connectedCountDisplay(connected: peersSendingToUs, total: seeders)
    }

    var peersDisplay: String? {
        connectedCountDisplay(connected: peersGettingFromUs, total: leechers)
    }

    init(torrent: TorrentGetTorrent, rpcVersion: Int = 14) {
        hashString = torrent.hashString ?? ""
        status = torrent.status.map { TorrentStatus.mapped(rawStatus: $0, rpcVersion: rpcVersion) }
        error = torrent["error"]?.intValue
        errorString = torrent.errorString ?? ""
        magnetLink = torrent.magnetLink ?? ""
        comment = torrent.comment ?? ""
        creator = torrent.creator ?? ""
        dateCreated = torrent.dateCreated
        metadataPercentComplete = torrent.metadataPercentComplete
        hasCompleteMetadataFromOverview = rpcVersion < 7 || torrent.metadataPercentComplete == 1
        isPrivate = torrent.isPrivate
        labels = torrent.labels
        totalSize = torrent.totalSize
        sizeWhenDone = torrent.sizeWhenDone
        leftUntilDone = torrent.leftUntilDone
        downloadDir = torrent.downloadDir
        addedDate = torrent.addedDate
        completedDate = torrent.doneDate
        activityDate = torrent.activityDate
        pieceCount = torrent.pieceCount
        pieceSize = torrent.pieceSize
        pieceMapState = torrent.pieceMapState
        haveValid = torrent.haveValid
        haveUnchecked = torrent.haveUnchecked
        downloadedEver = torrent.downloadedEver
        uploadedEver = torrent.uploadedEver
        corruptEver = torrent["corruptEver"]?.int64Value
        rateDownload = torrent.rateDownload
        rateUpload = torrent.rateUpload
        downloadSpeedLimit = TorrentGeneralSpeedLimit(
            limit: torrent["downloadLimit"],
            modernEnabled: torrent["downloadLimited"],
            legacyMode: torrent["downloadLimitMode"],
            rpcVersion: rpcVersion
        )
        uploadSpeedLimit = TorrentGeneralSpeedLimit(
            limit: torrent["uploadLimit"],
            modernEnabled: torrent["uploadLimited"],
            legacyMode: torrent["uploadLimitMode"],
            rpcVersion: rpcVersion
        )
        maxConnectedPeers = torrent["maxConnectedPeers"]?.intValue
        eta = torrent.eta
        uploadRatio = torrent.uploadRatio.flatMap { ratio in
            if ratio == -2 { return .infinity }
            return ratio == -1 ? nil : ratio
        }
        bandwidthPriority = torrent.bandwidthPriority
        queuePosition = torrent.queuePosition
        peersSendingToUs = torrent.peersSendingToUs
        peersGettingFromUs = torrent.peersGettingFromUs
        let primaryTracker = rpcVersion >= 7
            ? torrent.trackerStats?.first?.objectValue
            : torrent.trackers?.first?.objectValue
        seeders = rpcVersion >= 7
            ? primaryTracker?["seederCount"]?.intValue
            : torrent.seeders
        leechers = rpcVersion >= 7
            ? primaryTracker?["leecherCount"]?.intValue
            : torrent.leechers
        let hasTrackerPayload = rpcVersion >= 7
            ? torrent.trackerStats != nil
            : torrent.trackers != nil
        trackerHost = hasTrackerPayload ? TorrentMapper.trackerDisplay(torrent, rpcVersion: rpcVersion) : nil
        let mappedError = TorrentErrorMapper.merging(
            torrent,
            into: TorrentMappedError(displayError: "", trackerError: "", globalError: "", trackerStatus: ""),
            status: status ?? .unknown,
            rpcVersion: rpcVersion
        )
        trackerStatus = mappedError.trackerStatus.isEmpty ? nil : mappedError.trackerStatus
        trackerUpdate = TorrentTrackerUpdate(
            tracker: primaryTracker,
            legacyNextAnnounceTime: torrent["nextAnnounceTime"],
            rpcVersion: rpcVersion
        )
        secondsDownloading = torrent.secondsDownloading
        secondsSeeding = torrent.secondsSeeding
        desiredAvailable = torrent.desiredAvailable
    }

    func retainingOmittedFields(_ fields: Set<String>, from cached: TorrentGeneralInfo) -> TorrentGeneralInfo {
        var next = self
        if fields.contains("comment") { next.comment = cached.comment }
        if fields.contains("creator") { next.creator = cached.creator }
        if fields.contains("dateCreated") { next.dateCreated = cached.dateCreated }
        if fields.contains("pieceCount") { next.pieceCount = cached.pieceCount }
        if fields.contains("pieceSize") { next.pieceSize = cached.pieceSize }
        if fields.contains("pieces") { next.pieceMapState = cached.pieceMapState }
        return next
    }

    /// Only for a stale cache restore. A freshly selected detail response may
    /// be newer than the list and must not be overwritten with older row data.
    func overlayingCachedDisplay(with summary: TorrentSummary) -> TorrentGeneralInfo {
        var next = self
        next.status = summary.status
        next.errorString = summary.errorString
        if summary.globalError.isEmpty && summary.errorString.isEmpty { next.error = 0 }
        if let metadata = summary.metadataPercentComplete { next.metadataPercentComplete = metadata }
        if let total = summary.reportedTotalSize {
            next.totalSize = total
            next.sizeWhenDone = summary.sizeWhenDone
            next.leftUntilDone = summary.leftUntilDone
        }
        if let valid = summary.haveValid { next.haveValid = valid }
        if let unchecked = summary.haveUnchecked { next.haveUnchecked = unchecked }
        if let count = summary.pieceCount { next.pieceCount = count }
        if let size = summary.pieceSize { next.pieceSize = size }
        if !summary.downloadDir.isEmpty { next.downloadDir = summary.downloadDir }
        next.labels = summary.labels
        if let date = summary.addedDate { next.addedDate = date }
        if let date = summary.completedDate { next.completedDate = date }
        if let date = summary.activityDate { next.activityDate = date }
        next.pieceMapState = TorrentPiecePresentation.state(summary: summary, cachedInfo: next)
        return next
    }

    private func connectedCountDisplay(connected: Int?, total: Int?) -> String? {
        guard let connected else { return nil }
        guard let total, total >= 0 else { return "\(max(0, connected)) connected" }
        return "\(max(0, connected)) of \(total) connected"
    }
}

enum TorrentGeneralSpeedLimit: Hashable, Sendable {
    case global
    case unlimited
    case limited(Int)

    init?(
        limit: JSONValue?,
        modernEnabled: JSONValue?,
        legacyMode: JSONValue?,
        rpcVersion: Int
    ) {
        let limitKBps = limit?.intValue
        if rpcVersion < 5 {
            guard let rawMode = legacyMode?.intValue,
                  let mode = TorrentPropertiesLimitMode(rawValue: rawMode) else {
                return nil
            }
            switch mode {
            case .global:
                self = .global
            case .unlimited:
                self = .unlimited
            case .single:
                guard let limitKBps else { return nil }
                self = limitKBps < 0 ? .unlimited : .limited(limitKBps)
            }
            return
        }

        guard let modernEnabled = modernEnabled?.boolValue
            ?? modernEnabled?.intValue.map({ $0 != 0 }) else {
            return nil
        }
        if !modernEnabled {
            self = .global
        } else if let limitKBps {
            self = limitKBps < 0 ? .unlimited : .limited(limitKBps)
        } else {
            return nil
        }
    }
}

enum TorrentTrackerUpdate: Hashable, Sendable {
    case updating
    case scheduled(Date)

    init?(tracker: RPCArguments?, legacyNextAnnounceTime: JSONValue?, rpcVersion: Int) {
        if rpcVersion >= 7 {
            guard let tracker else { return nil }
            if let announceState = tracker["announceState"]?.intValue,
               announceState == 2 || announceState == 3 {
                self = .updating
                return
            }
            if tracker["nextAnnounceTime"]?.doubleValue == 1 {
                self = .updating
                return
            }
            guard let date = tracker["nextAnnounceTime"]?.dateFromUnixTime else { return nil }
            self = .scheduled(date)
            return
        }

        guard let timestamp = legacyNextAnnounceTime?.doubleValue,
              timestamp.isFinite,
              timestamp > 0 else {
            return nil
        }
        if timestamp == 1 {
            self = .updating
        } else if let date = legacyNextAnnounceTime?.dateFromUnixTime {
            self = .scheduled(date)
        } else {
            return nil
        }
    }
}

struct TorrentFile: Identifiable, Hashable, Sendable {
    var id: Int
    var path: String
    var name: String
    var length: Int64
    var bytesCompleted: Int64
    var wanted: Bool?
    var priority: Int?

    var progress: Double {
        guard length > 0 else { return 1 }
        return min(max(Double(bytesCompleted) / Double(length), 0), 1)
    }

    var relativePath: String {
        path.isEmpty ? name : "\(path)/\(name)"
    }

    fileprivate static func files(from torrent: TorrentGetTorrent) -> [TorrentFile] {
        (torrent.files ?? []).enumerated().compactMap { index, value in
            guard let file = value.objectValue else { return nil }
            let rawName = file["name"]?.stringValue ?? "File \(index + 1)"
            let pathParts = Self.pathParts(rawName)
            let name = pathParts.last ?? rawName
            let path = pathParts.dropLast().joined(separator: "/")
            let stat = torrent.fileStats?[safe: index]?.objectValue
            return TorrentFile(
                id: index,
                path: path,
                name: name,
                length: max(0, file["length"]?.int64Value ?? 0),
                bytesCompleted: max(0, stat?["bytesCompleted"]?.int64Value ?? file["bytesCompleted"]?.int64Value ?? 0),
                wanted: stat?["wanted"]?.torrentBoolValue ?? torrent.wanted?[safe: index]?.torrentBoolValue,
                priority: stat?["priority"]?.intValue ?? torrent.priorities?[safe: index]?.intValue
            )
        }
    }

    fileprivate static func pathParts(_ path: String) -> [String] {
        let parts = path.split { $0 == "/" || $0 == "\\" }.map(String.init)
        return parts.isEmpty ? [path] : parts
    }
}

struct TorrentFileNode: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case folder
        case file(Int)
    }

    var id: String
    var kind: Kind
    var name: String
    var path: String
    var length: Int64
    var bytesCompleted: Int64
    var wanted: TorrentFileWantedState
    var priority: TorrentFilePriorityState
    var children: [TorrentFileNode]?

    var isFolder: Bool {
        if case .folder = kind { return true }
        return false
    }

    var fileIndexes: [Int] {
        switch kind {
        case .file(let index):
            [index]
        case .folder:
            (children ?? []).flatMap(\.fileIndexes).sorted()
        }
    }

    var progress: Double {
        guard length > 0 else { return 1 }
        return min(max(Double(bytesCompleted) / Double(length), 0), 1)
    }

    static func tree(from files: [TorrentFile]) -> [TorrentFileNode] {
        let root = TorrentFileTreeBuilder(component: "", path: "")
        for file in files.sorted(by: fileSort) {
            root.insert(file)
        }
        return root.makeChildren()
    }

    private static func fileSort(_ lhs: TorrentFile, _ rhs: TorrentFile) -> Bool {
        lhs.relativePath.localizedStandardCompare(rhs.relativePath) == .orderedAscending
    }
}

enum TorrentFileWantedState: Hashable, Sendable {
    case wanted
    case unwanted
    case mixed
    case unknown

    var title: String {
        switch self {
        case .wanted: "Yes"
        case .unwanted: "No"
        case .mixed: "Mixed"
        case .unknown: "—"
        }
    }

    fileprivate init(value: Bool?) {
        switch value {
        case .some(true): self = .wanted
        case .some(false): self = .unwanted
        case nil: self = .unknown
        }
    }

    fileprivate static func aggregate(_ values: [TorrentFileWantedState]) -> TorrentFileWantedState {
        guard let first = values.first else { return .unknown }
        return values.allSatisfy { $0 == first } ? first : .mixed
    }
}

enum TorrentFilePriorityState: Hashable, Comparable, Sendable {
    case skipped
    case low
    case normal
    case high
    case mixed
    case unknown
    case other(Int)

    var title: String {
        switch self {
        case .skipped: "Skip"
        case .low: "Low"
        case .normal: "Normal"
        case .high: "High"
        case .mixed: "Mixed"
        case .unknown: "—"
        case .other(let value): "\(value)"
        }
    }

    var editablePriority: TorrentFilePriority? {
        switch self {
        case .low: .low
        case .normal: .normal
        case .high: .high
        case .skipped, .mixed, .unknown, .other: nil
        }
    }

    static func < (lhs: TorrentFilePriorityState, rhs: TorrentFilePriorityState) -> Bool {
        if case .other(let left) = lhs, case .other(let right) = rhs {
            return left < right
        }
        return lhs.sortGroup < rhs.sortGroup
    }

    fileprivate init(priority: Int?, wanted: Bool?) {
        if wanted == false {
            self = .skipped
            return
        }
        switch priority {
        case .some(-1): self = .low
        case .some(0): self = .normal
        case .some(1): self = .high
        case nil: self = .unknown
        case .some(let value): self = .other(value)
        }
    }

    fileprivate static func aggregate(_ values: [TorrentFilePriorityState]) -> TorrentFilePriorityState {
        guard let first = values.first else { return .unknown }
        return values.allSatisfy { $0 == first } ? first : .mixed
    }

    private var sortGroup: Int {
        switch self {
        case .high: 0
        case .normal: 1
        case .low: 2
        case .mixed: 3
        case .skipped: 4
        case .unknown: 5
        case .other: 6
        }
    }
}

enum TorrentFilePriority: Int, CaseIterable, Hashable, Identifiable, Sendable {
    case low = -1
    case normal = 0
    case high = 1

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .low: "Low"
        case .normal: "Normal"
        case .high: "High"
        }
    }
}

private final class TorrentFileTreeBuilder {
    let component: String
    let path: String
    var file: TorrentFile?
    private var childrenByComponent: [String: TorrentFileTreeBuilder] = [:]

    init(component: String, path: String) {
        self.component = component
        self.path = path
    }

    func insert(_ file: TorrentFile) {
        let components = TorrentFile.pathParts(file.relativePath)
        insert(file, components: components[...])
    }

    private func insert(_ file: TorrentFile, components: ArraySlice<String>) {
        guard let component = components.first else { return }
        if components.count == 1 {
            let child = child(named: component)
            child.file = file
            return
        }
        child(named: component).insert(file, components: components.dropFirst())
    }

    private func child(named name: String) -> TorrentFileTreeBuilder {
        if let child = childrenByComponent[name] {
            return child
        }
        let childPath = path.isEmpty ? name : "\(path)/\(name)"
        let child = TorrentFileTreeBuilder(component: name, path: childPath)
        childrenByComponent[name] = child
        return child
    }

    func makeChildren() -> [TorrentFileNode] {
        childrenByComponent.values
            .sorted(by: Self.displayOrder)
            .compactMap { $0.makeNode() }
    }

    private static func displayOrder(_ lhs: TorrentFileTreeBuilder, _ rhs: TorrentFileTreeBuilder) -> Bool {
        let lhsIsFolder = lhs.file == nil
        let rhsIsFolder = rhs.file == nil
        if lhsIsFolder != rhsIsFolder {
            return lhsIsFolder
        }

        let comparison = lhs.component.localizedStandardCompare(rhs.component)
        if comparison != .orderedSame {
            return comparison == .orderedAscending
        }
        return lhs.component < rhs.component
    }

    private func makeNode() -> TorrentFileNode? {
        if let file {
            return TorrentFileNode(
                id: "file-\(file.id)",
                kind: .file(file.id),
                name: file.name,
                path: file.path,
                length: file.length,
                bytesCompleted: file.bytesCompleted,
                wanted: TorrentFileWantedState(value: file.wanted),
                priority: TorrentFilePriorityState(priority: file.priority, wanted: file.wanted),
                children: nil
            )
        }

        let childNodes = makeChildren()
        guard !childNodes.isEmpty else { return nil }
        return TorrentFileNode(
            id: "folder-\(path)",
            kind: .folder,
            name: component,
            path: parentPath,
            length: childNodes.reduce(0) { Self.saturatingAdd($0, $1.length) },
            bytesCompleted: childNodes.reduce(0) {
                Self.saturatingAdd($0, $1.bytesCompleted)
            },
            wanted: TorrentFileWantedState.aggregate(childNodes.map(\.wanted)),
            priority: TorrentFilePriorityState.aggregate(childNodes.map(\.priority)),
            children: childNodes
        )
    }

    private var parentPath: String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    private static func saturatingAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int64.max : sum
    }
}

struct TorrentPeer: Identifiable, Hashable, Sendable, StableSecondaryRowIdentity {
    var id: String
    /// The address exactly as returned by Transmission. Resolution never
    /// replaces it, so copy actions and endpoint identity remain truthful.
    var host: String
    var port: Int
    var resolvedHostName: String?
    private var daemonCountry: String
    var countryCode: String
    var country: String
    var countryFlag: String
    var clientName: String
    var flags: String
    var progress: Double
    var rateToClient: Int64
    var rateToPeer: Int64

    init(index _: Int, json: RPCArguments) {
        host = json["address"]?.stringValue ?? json["host"]?.stringValue ?? ""
        port = max(0, json["port"]?.intValue ?? 0)
        resolvedHostName = nil
        daemonCountry = json["country"]?.stringValue ?? ""
        countryCode = ""
        country = daemonCountry
        countryFlag = ""
        clientName = json["clientName"]?.stringValue ?? ""
        flags = json["flagStr"]?.stringValue ?? json["flags"]?.stringValue ?? ""
        progress = min(max(json["progress"]?.doubleValue ?? 0, 0), 1)
        rateToClient = max(0, json["rateToClient"]?.int64Value ?? 0)
        rateToPeer = max(0, json["rateToPeer"]?.int64Value ?? 0)
        id = "peer:\(host.lowercased()):\(port)|\(clientName.lowercased())|\(daemonCountry.lowercased())"
    }

    var displayHost: String {
        resolvedHostName ?? host
    }

    var countryDisplay: String {
        countryFlag.isEmpty ? country : "\(countryFlag) \(country)"
    }

    func applying(_ metadata: PeerResolvedMetadata?) -> TorrentPeer {
        guard let metadata else { return self }
        var peer = self
        peer.resolvedHostName = metadata.hostName
        if let countryCode = metadata.countryCode {
            peer.countryCode = countryCode
            peer.country = metadata.countryName ?? countryCode
            peer.countryFlag = metadata.countryFlag ?? ""
        } else {
            peer.countryCode = ""
            peer.country = daemonCountry
            peer.countryFlag = ""
        }
        return peer
    }

    var clearingResolution: TorrentPeer {
        var peer = self
        peer.resolvedHostName = nil
        peer.countryCode = ""
        peer.country = daemonCountry
        peer.countryFlag = ""
        return peer
    }

    fileprivate func reusingResolution(from previous: TorrentPeer) -> TorrentPeer {
        guard id == previous.id, host == previous.host, port == previous.port,
              daemonCountry == previous.daemonCountry else { return self }
        var peer = self
        peer.resolvedHostName = previous.resolvedHostName
        peer.countryCode = previous.countryCode
        peer.country = previous.country
        peer.countryFlag = previous.countryFlag
        return peer
    }

    fileprivate var stableIdentityBase: String {
        "peer:\(host.lowercased()):\(port)|\(clientName.lowercased())|\(daemonCountry.lowercased())"
    }

    fileprivate var stableCollisionKey: String {
        stableIdentityBase
    }
}

struct TorrentTracker: Identifiable, Hashable, Sendable, StableSecondaryRowIdentity {
    var id: String
    var trackerID: Int
    private var stableDaemonIdentity: String
    var announce: String
    var host: String
    var status: String
    var nextAnnounceDate: Date?
    var seederCount: Int
    var leecherCount: Int
    var downloadCount: Int

    init(index: Int, json: RPCArguments, fallbackNextAnnounceDate: Date?) {
        let daemonTrackerID = json["id"]?.intValue
        trackerID = daemonTrackerID ?? index
        stableDaemonIdentity = daemonTrackerID.map(String.init) ?? "announce"
        announce = json["announce"]?.stringValue ?? json["host"]?.stringValue ?? ""
        host = json["host"]?.stringValue ?? TorrentMapper.filterTrackerURI(announce)
        status = Self.statusText(for: json)
        nextAnnounceDate = json["nextAnnounceTime"]?.dateFromUnixTime ?? fallbackNextAnnounceDate
        seederCount = json["seederCount"]?.intValue ?? -1
        leecherCount = json["leecherCount"]?.intValue ?? -1
        downloadCount = json["downloadCount"]?.intValue ?? -1
        id = "tracker:\(stableDaemonIdentity)|\(announce)"
    }

    fileprivate var stableIdentityBase: String {
        "tracker:\(stableDaemonIdentity)|\(announce)"
    }

    fileprivate var stableCollisionKey: String {
        host.lowercased()
    }

    private static func statusText(for tracker: RPCArguments) -> String {
        if let announceState = tracker["announceState"]?.intValue, announceState == 2 || announceState == 3 {
            return "Updating"
        }
        guard tracker["hasAnnounced"]?.boolValue ?? false else { return "Not announced" }
        if tracker["lastAnnounceSucceeded"]?.boolValue ?? false {
            return "Working"
        }
        let result = tracker["lastAnnounceResult"]?.stringValue ?? ""
        return result.isEmpty || result == "Success" ? "Working" : result
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private extension JSONValue {
    var torrentBoolValue: Bool? {
        if let boolValue {
            return boolValue
        }
        if let intValue {
            return intValue != 0
        }
        return nil
    }
}
