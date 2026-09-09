// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation

enum SecondaryTablePreferenceKeys {
    static let fileColumns = "torrentDetail.files.columnCustomization.v1"
    static let fileLayout = "torrentDetail.files.layout.v1"
    static let fileSort = "torrentDetail.files.sort.v1"
    static let peerColumns = "torrentDetail.peers.columnCustomization.v1"
    static let peerLayout = "torrentDetail.peers.layout.v1"
    static let peerSort = "torrentDetail.peers.sort.v1"
    static let trackerColumns = "torrentDetail.trackers.columnCustomization.v1"
    static let trackerLayout = "torrentDetail.trackers.layout.v1"
    static let trackerSort = "torrentDetail.trackers.sort.v1"
}

enum SecondaryTableColumnID {
    enum Files {
        static let name = "torrentDetail.files.name"
        static let size = "torrentDetail.files.size"
        static let completed = "torrentDetail.files.completed"
        static let progress = "torrentDetail.files.progress"
        static let wanted = "torrentDetail.files.wanted"
        static let priority = "torrentDetail.files.priority"

        static let all = [name, size, completed, progress, wanted, priority]
    }

    enum Peers {
        static let host = "torrentDetail.peers.host"
        static let port = "torrentDetail.peers.port"
        static let country = "torrentDetail.peers.country"
        static let client = "torrentDetail.peers.client"
        static let flags = "torrentDetail.peers.flags"
        static let progress = "torrentDetail.peers.progress"
        static let upload = "torrentDetail.peers.upload"
        static let download = "torrentDetail.peers.download"

        static let all = [host, port, country, client, flags, progress, upload, download]
    }

    enum Trackers {
        static let tracker = "torrentDetail.trackers.tracker"
        static let status = "torrentDetail.trackers.status"
        static let update = "torrentDetail.trackers.update"
        static let seeds = "torrentDetail.trackers.seeds"
        static let leechers = "torrentDetail.trackers.leechers"
        static let downloads = "torrentDetail.trackers.downloads"

        static let all = [tracker, status, update, seeds, leechers, downloads]
    }
}

enum SecondaryTableSortDirection: String, Equatable, Sendable {
    case ascending
    case descending
}

struct SecondaryTableSortPreference: RawRepresentable, Equatable, Sendable {
    var columnID: String
    var direction: SecondaryTableSortDirection

    init(columnID: String, direction: SecondaryTableSortDirection) {
        self.columnID = columnID
        self.direction = direction
    }

    init?(rawValue: String) {
        let components = rawValue.split(separator: "|", omittingEmptySubsequences: false)
        guard components.count == 2,
              !components[0].isEmpty,
              let direction = SecondaryTableSortDirection(rawValue: String(components[1])) else {
            return nil
        }
        columnID = String(components[0])
        self.direction = direction
    }

    var rawValue: String {
        "\(columnID)|\(direction.rawValue)"
    }

    func normalized(
        allowedColumnIDs: [String],
        default defaultPreference: SecondaryTableSortPreference
    ) -> SecondaryTableSortPreference {
        allowedColumnIDs.contains(columnID) ? self : defaultPreference
    }
}

enum SecondaryTableDefaults {
    static let fileSort = SecondaryTableSortPreference(
        columnID: SecondaryTableColumnID.Files.name,
        direction: .ascending
    )
    static let peerSort = SecondaryTableSortPreference(
        columnID: SecondaryTableColumnID.Peers.host,
        direction: .ascending
    )
    static let trackerSort = SecondaryTableSortPreference(
        columnID: SecondaryTableColumnID.Trackers.tracker,
        direction: .ascending
    )
}

enum SecondaryTableKind: CaseIterable, Sendable {
    case files
    case peers
    case trackers

    var layoutStorageKey: String {
        switch self {
        case .files:
            SecondaryTablePreferenceKeys.fileLayout
        case .peers:
            SecondaryTablePreferenceKeys.peerLayout
        case .trackers:
            SecondaryTablePreferenceKeys.trackerLayout
        }
    }

    var columnIDs: [String] {
        switch self {
        case .files:
            SecondaryTableColumnID.Files.all
        case .peers:
            SecondaryTableColumnID.Peers.all
        case .trackers:
            SecondaryTableColumnID.Trackers.all
        }
    }

    var requiredColumnID: String {
        switch self {
        case .files:
            SecondaryTableColumnID.Files.name
        case .peers:
            SecondaryTableColumnID.Peers.host
        case .trackers:
            SecondaryTableColumnID.Trackers.tracker
        }
    }

    var defaultHiddenColumnIDs: Set<String> {
        switch self {
        case .files:
            []
        case .peers:
            [SecondaryTableColumnID.Peers.port]
        case .trackers:
            [SecondaryTableColumnID.Trackers.downloads]
        }
    }

    var defaultSort: SecondaryTableSortPreference {
        switch self {
        case .files:
            SecondaryTableDefaults.fileSort
        case .peers:
            SecondaryTableDefaults.peerSort
        case .trackers:
            SecondaryTableDefaults.trackerSort
        }
    }
}

struct SecondaryTableLayoutPreference: Equatable, RawRepresentable, Sendable {
    var hiddenColumnIDs: Set<String>
    var sortPreference: SecondaryTableSortPreference

    init(
        hiddenColumnIDs: Set<String>,
        sortPreference: SecondaryTableSortPreference
    ) {
        self.hiddenColumnIDs = hiddenColumnIDs
        self.sortPreference = sortPreference
    }

    init?(rawValue: String) {
        guard let data = rawValue.data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.version == 1,
              let sortPreference = SecondaryTableSortPreference(rawValue: payload.sort) else {
            return nil
        }
        hiddenColumnIDs = Set(payload.hidden)
        self.sortPreference = sortPreference
    }

    var rawValue: String {
        let payload = Payload(
            version: 1,
            order: nil,
            hidden: hiddenColumnIDs.sorted(),
            sort: sortPreference.rawValue
        )
        guard let data = try? JSONEncoder.stable.encode(payload),
              let rawValue = String(data: data, encoding: .utf8) else {
            return ""
        }
        return rawValue
    }

    static func defaults(for table: SecondaryTableKind) -> SecondaryTableLayoutPreference {
        SecondaryTableLayoutPreference(
            hiddenColumnIDs: table.defaultHiddenColumnIDs,
            sortPreference: table.defaultSort
        )
    }

    static func restored(
        from rawValue: String?,
        for table: SecondaryTableKind
    ) -> SecondaryTableLayoutPreference {
        guard let rawValue,
              let preference = SecondaryTableLayoutPreference(rawValue: rawValue) else {
            return defaults(for: table)
        }
        return preference.normalized(for: table)
    }

    func normalized(for table: SecondaryTableKind) -> SecondaryTableLayoutPreference {
        let allowedIDs = Set(table.columnIDs)
        var normalizedHiddenIDs = hiddenColumnIDs.intersection(allowedIDs)
        normalizedHiddenIDs.remove(table.requiredColumnID)

        return SecondaryTableLayoutPreference(
            hiddenColumnIDs: normalizedHiddenIDs,
            sortPreference: sortPreference.normalized(
                allowedColumnIDs: table.columnIDs,
                default: table.defaultSort
            )
        )
    }

    func isColumnVisible(_ columnID: String, for table: SecondaryTableKind) -> Bool {
        let preference = normalized(for: table)
        return columnID == table.requiredColumnID || !preference.hiddenColumnIDs.contains(columnID)
    }

    func settingColumnVisibility(
        _ isVisible: Bool,
        columnID: String,
        for table: SecondaryTableKind
    ) -> SecondaryTableLayoutPreference {
        var preference = normalized(for: table)
        guard columnID != table.requiredColumnID,
              table.columnIDs.contains(columnID) else {
            return preference
        }
        if isVisible {
            preference.hiddenColumnIDs.remove(columnID)
        } else {
            preference.hiddenColumnIDs.insert(columnID)
        }
        return preference
    }

    func settingSort(
        _ sortPreference: SecondaryTableSortPreference,
        for table: SecondaryTableKind
    ) -> SecondaryTableLayoutPreference {
        var preference = normalized(for: table)
        preference.sortPreference = sortPreference.normalized(
            allowedColumnIDs: table.columnIDs,
            default: table.defaultSort
        )
        return preference
    }

    func restoringColumns(for table: SecondaryTableKind) -> SecondaryTableLayoutPreference {
        var preference = normalized(for: table)
        preference.hiddenColumnIDs = table.defaultHiddenColumnIDs
        return preference
    }

    func restoringSort(for table: SecondaryTableKind) -> SecondaryTableLayoutPreference {
        settingSort(table.defaultSort, for: table)
    }

    func restoringDefaults(for table: SecondaryTableKind) -> SecondaryTableLayoutPreference {
        Self.defaults(for: table)
    }

    private struct Payload: Codable {
        var version: Int
        // Retained only so existing v1 values decode. SwiftUI's
        // TableColumnCustomization owns runtime dragged-column order.
        var order: [String]?
        var hidden: [String]
        var sort: String
    }
}

enum TorrentFilesProjectionCommitGuard {
    static func canCommit(
        expectedIdentity: TorrentFilesProjectionIdentity,
        projectionOwnerIdentity: TorrentFilesProjectionIdentity?,
        currentIdentity: TorrentFilesProjectionIdentity?
    ) -> Bool {
        projectionOwnerIdentity == expectedIdentity && currentIdentity == expectedIdentity
    }
}

enum TorrentPeersProjectionCommitGuard {
    static func canCommit(
        expectedIdentity: TorrentPeersProjectionIdentity,
        projectionOwnerIdentity: TorrentPeersProjectionIdentity?,
        currentIdentity: TorrentPeersProjectionIdentity?
    ) -> Bool {
        projectionOwnerIdentity == expectedIdentity && currentIdentity == expectedIdentity
    }
}

enum TorrentTrackersProjectionCommitGuard {
    static func canCommit(
        expectedIdentity: TorrentTrackersProjectionIdentity,
        projectionOwnerIdentity: TorrentTrackersProjectionIdentity?,
        currentIdentity: TorrentTrackersProjectionIdentity?
    ) -> Bool {
        projectionOwnerIdentity == expectedIdentity && currentIdentity == expectedIdentity
    }
}

struct TrackerEditorOwner: Equatable, Sendable {
    var torrentID: Int
    var trackerRowID: TorrentTracker.ID?
    var daemonTrackerID: Int?
    var originalAnnounceURL: String?

    init?(detail: TorrentDetail, tracker: TorrentTracker?) {
        guard detail.trackersSnapshotRevision != nil else { return nil }
        torrentID = detail.id
        trackerRowID = tracker?.id
        daemonTrackerID = tracker?.trackerID
        originalAnnounceURL = tracker?.announce
    }

    func matches(detail: TorrentDetail?, requiresTracker: Bool) -> Bool {
        guard let detail,
              detail.id == torrentID,
              detail.trackersSnapshotRevision != nil else {
            return false
        }
        guard requiresTracker else { return true }
        guard let trackerRowID,
              let daemonTrackerID,
              let originalAnnounceURL else {
            return false
        }
        return detail.trackers.contains {
            $0.id == trackerRowID
                && $0.trackerID == daemonTrackerID
                && $0.announce == originalAnnounceURL
        }
    }
}

enum SecondaryTableFocusedSelectionAction {
    static func selectAll<ID: Hashable>(
        isActive: Bool,
        ownsFocus: Bool,
        ownsCurrentProjection: Bool,
        availableIDs: Set<ID>
    ) -> Set<ID>? {
        guard isActive, ownsFocus, ownsCurrentProjection else { return nil }
        return availableIDs
    }

    static func canCopy(
        isActive: Bool,
        ownsFocus: Bool,
        ownsCurrentProjection: Bool,
        selectedCount: Int
    ) -> Bool {
        isActive && ownsFocus && ownsCurrentProjection && selectedCount > 0
    }
}

private extension JSONEncoder {
    static var stable: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

enum SecondaryTableSorting {
    static func files(
        _ nodes: [TorrentFileNode],
        by preference: SecondaryTableSortPreference
    ) -> [TorrentFileNode] {
        let preference = preference.normalized(
            allowedColumnIDs: SecondaryTableColumnID.Files.all,
            default: SecondaryTableDefaults.fileSort
        )
        return nodes
            .map { node in
                var node = node
                if let children = node.children {
                    node.children = files(children, by: preference)
                }
                return node
            }
            .sorted { lhs, rhs in
                if lhs.isFolder != rhs.isFolder {
                    return lhs.isFolder
                }
                return fileOrdering(lhs, rhs, preference: preference)
            }
    }

    static func peers(
        _ peers: [TorrentPeer],
        by preference: SecondaryTableSortPreference
    ) -> [TorrentPeer] {
        let preference = preference.normalized(
            allowedColumnIDs: SecondaryTableColumnID.Peers.all,
            default: SecondaryTableDefaults.peerSort
        )
        return peers.sorted { lhs, rhs in
            let result: ComparisonResult
            switch preference.columnID {
            case SecondaryTableColumnID.Peers.port:
                result = compare(lhs.port, rhs.port)
            case SecondaryTableColumnID.Peers.country:
                result = compare(lhs.countryDisplay, rhs.countryDisplay)
            case SecondaryTableColumnID.Peers.client:
                result = compare(lhs.clientName, rhs.clientName)
            case SecondaryTableColumnID.Peers.flags:
                result = compare(lhs.flags, rhs.flags)
            case SecondaryTableColumnID.Peers.progress:
                result = compare(lhs.progress, rhs.progress)
            case SecondaryTableColumnID.Peers.upload:
                result = compare(lhs.rateToPeer, rhs.rateToPeer)
            case SecondaryTableColumnID.Peers.download:
                result = compare(lhs.rateToClient, rhs.rateToClient)
            default:
                result = compare(lhs.displayHost, rhs.displayHost)
            }
            return ordered(result, direction: preference.direction, lhsID: lhs.id, rhsID: rhs.id)
        }
    }

    static func trackers(
        _ trackers: [TorrentTracker],
        by preference: SecondaryTableSortPreference
    ) -> [TorrentTracker] {
        let preference = preference.normalized(
            allowedColumnIDs: SecondaryTableColumnID.Trackers.all,
            default: SecondaryTableDefaults.trackerSort
        )
        return trackers.sorted { lhs, rhs in
            let result: ComparisonResult
            switch preference.columnID {
            case SecondaryTableColumnID.Trackers.status:
                result = compare(lhs.status, rhs.status)
            case SecondaryTableColumnID.Trackers.update:
                result = compare(lhs.nextAnnounceDate ?? .distantPast, rhs.nextAnnounceDate ?? .distantPast)
            case SecondaryTableColumnID.Trackers.seeds:
                result = compare(lhs.seederCount, rhs.seederCount)
            case SecondaryTableColumnID.Trackers.leechers:
                result = compare(lhs.leecherCount, rhs.leecherCount)
            case SecondaryTableColumnID.Trackers.downloads:
                result = compare(lhs.downloadCount, rhs.downloadCount)
            default:
                result = compare(lhs.announce, rhs.announce)
            }
            return ordered(result, direction: preference.direction, lhsID: lhs.id, rhsID: rhs.id)
        }
    }

    private static func fileOrdering(
        _ lhs: TorrentFileNode,
        _ rhs: TorrentFileNode,
        preference: SecondaryTableSortPreference
    ) -> Bool {
        let result: ComparisonResult
        switch preference.columnID {
        case SecondaryTableColumnID.Files.size:
            result = compare(lhs.length, rhs.length)
        case SecondaryTableColumnID.Files.completed:
            result = compare(lhs.bytesCompleted, rhs.bytesCompleted)
        case SecondaryTableColumnID.Files.progress:
            result = compare(lhs.progress, rhs.progress)
        case SecondaryTableColumnID.Files.wanted:
            result = compare(fileWantedRank(lhs.wanted), fileWantedRank(rhs.wanted))
        case SecondaryTableColumnID.Files.priority:
            result = compare(lhs.priority, rhs.priority)
        default:
            result = compare(lhs.path.isEmpty ? lhs.name : "\(lhs.path)/\(lhs.name)",
                             rhs.path.isEmpty ? rhs.name : "\(rhs.path)/\(rhs.name)")
        }
        return ordered(result, direction: preference.direction, lhsID: lhs.id, rhsID: rhs.id)
    }

    private static func fileWantedRank(_ value: TorrentFileWantedState) -> Int {
        switch value {
        case .wanted: 0
        case .mixed: 1
        case .unwanted: 2
        case .unknown: 3
        }
    }

    private static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let localized = lhs.localizedStandardCompare(rhs)
        guard localized == .orderedSame else { return localized }
        return lhs.compare(rhs)
    }

    private static func compare<Value: Comparable>(_ lhs: Value, _ rhs: Value) -> ComparisonResult {
        if lhs < rhs { return .orderedAscending }
        if lhs > rhs { return .orderedDescending }
        return .orderedSame
    }

    private static func ordered(
        _ result: ComparisonResult,
        direction: SecondaryTableSortDirection,
        lhsID: String,
        rhsID: String
    ) -> Bool {
        if result == .orderedSame {
            return lhsID < rhsID
        }
        switch direction {
        case .ascending:
            return result == .orderedAscending
        case .descending:
            return result == .orderedDescending
        }
    }
}
