// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation
import SwiftUI

enum TorrentTableColumnID: String, CaseIterable, Identifiable, Sendable {
    case name = "torrent.name"
    case size = "torrent.size"
    case done = "torrent.progress"
    case status = "torrent.status"
    case seeds = "torrent.seeds"
    case peers = "torrent.peers"
    case downloadSpeed = "torrent.downloadSpeed"
    case uploadSpeed = "torrent.uploadSpeed"
    case eta = "torrent.eta"
    case ratio = "torrent.ratio"
    case downloaded = "torrent.downloaded"
    case uploaded = "torrent.uploaded"
    case tracker = "torrent.tracker"
    case trackerStatus = "torrent.trackerStatus"
    case addedOn = "torrent.addedOn"
    case completedOn = "torrent.completedOn"
    case lastActive = "torrent.lastActive"
    case path = "torrent.location"
    case priority = "torrent.priority"
    case sizeToDownload = "torrent.sizeToDownload"
    case torrentID = "torrent.id"
    case queuePosition = "torrent.queuePosition"
    case seedingTime = "torrent.seedingTime"
    case sizeLeft = "torrent.sizeLeft"
    case privateTorrent = "torrent.private"
    case labels = "torrent.labels"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: "Name"
        case .size: "Size"
        case .done: "Done"
        case .status: "Status"
        case .seeds: "Seeds"
        case .peers: "Peers"
        case .downloadSpeed: "Down speed"
        case .uploadSpeed: "Up speed"
        case .eta: "ETA"
        case .ratio: "Ratio"
        case .downloaded: "Downloaded"
        case .uploaded: "Uploaded"
        case .tracker: "Tracker"
        case .trackerStatus: "Tracker status"
        case .addedOn: "Added on"
        case .completedOn: "Completed on"
        case .lastActive: "Last active"
        case .path: "Path"
        case .priority: "Priority"
        case .sizeToDownload: "Size to download"
        case .torrentID: "ID"
        case .queuePosition: "Queue position"
        case .seedingTime: "Seeding time"
        case .sizeLeft: "Size left"
        case .privateTorrent: "Private"
        case .labels: "Labels"
        }
    }

    var isRequired: Bool {
        self == .name
    }

    var isVisibleByDefault: Bool {
        switch self {
        case .name, .size, .done, .status, .seeds, .peers, .downloadSpeed,
             .uploadSpeed, .eta, .ratio, .labels:
            true
        default:
            false
        }
    }
}

enum TorrentTableColumnPreferenceKeys {
    static let customization = "torrentTable.columnCustomization.v1"
    static let sort = "torrentTable.sort.v1"
}

enum TorrentTableColumnVisibility {
    static func isVisible(
        _ columnID: TorrentTableColumnID,
        in customization: TableColumnCustomization<TorrentSummary>
    ) -> Bool {
        guard !columnID.isRequired else { return true }

        let visibility = customization[visibility: columnID.rawValue]
        if visibility == .visible { return true }
        if visibility == .hidden { return false }
        return columnID.isVisibleByDefault
    }

    static func resolvedColumns(
        in customization: TableColumnCustomization<TorrentSummary>
    ) -> Set<TorrentTableColumnID> {
        Set(TorrentTableColumnID.allCases.filter { isVisible($0, in: customization) })
    }
}

enum TorrentTableSortDirection: String, CaseIterable, Sendable {
    case ascending
    case descending

    init(_ order: SortOrder) {
        self = order == .reverse ? .descending : .ascending
    }

    var sortOrder: SortOrder {
        self == .descending ? .reverse : .forward
    }
}

struct TorrentTableSortPreference: RawRepresentable, Equatable, Sendable {
    var columnID: TorrentTableColumnID
    var direction: TorrentTableSortDirection

    init(columnID: TorrentTableColumnID, direction: TorrentTableSortDirection) {
        self.columnID = columnID
        self.direction = direction
    }

    init(rawValue: String) {
        let components = rawValue.split(separator: "|", omittingEmptySubsequences: false)
        guard components.count == 2,
              let columnID = TorrentTableColumnID(rawValue: String(components[0])),
              let direction = TorrentTableSortDirection(rawValue: String(components[1])) else {
            self = TorrentTableDefaults.sort
            return
        }
        self.init(columnID: columnID, direction: direction)
    }

    var rawValue: String {
        "\(columnID.rawValue)|\(direction.rawValue)"
    }
}

enum TorrentTableDefaults {
    static let sort = TorrentTableSortPreference(columnID: .name, direction: .ascending)
}

enum TorrentTableSortMapping {
    static func descriptors(
        for preference: TorrentTableSortPreference
    ) -> [KeyPathComparator<TorrentSummary>] {
        let order = preference.direction.sortOrder
        let descriptor: KeyPathComparator<TorrentSummary>
        switch preference.columnID {
        case .name:
            descriptor = KeyPathComparator(\TorrentSummary.name, comparator: .localizedStandard, order: order)
        case .size:
            descriptor = KeyPathComparator(\TorrentSummary.displaySize, order: order)
        case .done:
            descriptor = KeyPathComparator(\TorrentSummary.percentDone, order: order)
        case .status:
            descriptor = KeyPathComparator(\TorrentSummary.status.rawValue, order: order)
        case .seeds:
            descriptor = KeyPathComparator(\TorrentSummary.seedsConnected, order: order)
        case .peers:
            descriptor = KeyPathComparator(\TorrentSummary.peersConnected, order: order)
        case .downloadSpeed:
            descriptor = KeyPathComparator(\TorrentSummary.rateDownload, order: order)
        case .uploadSpeed:
            descriptor = KeyPathComparator(\TorrentSummary.rateUpload, order: order)
        case .eta:
            descriptor = KeyPathComparator(\TorrentSummary.eta, order: order)
        case .ratio:
            descriptor = KeyPathComparator(\TorrentSummary.uploadRatio, order: order)
        case .downloaded:
            descriptor = KeyPathComparator(\TorrentSummary.downloadedEver, order: order)
        case .uploaded:
            descriptor = KeyPathComparator(\TorrentSummary.uploadedEver, order: order)
        case .tracker:
            descriptor = KeyPathComparator(\TorrentSummary.trackerHost, comparator: .localizedStandard, order: order)
        case .trackerStatus:
            descriptor = KeyPathComparator(\TorrentSummary.trackerStatusDisplay, comparator: .localizedStandard, order: order)
        case .addedOn:
            descriptor = KeyPathComparator(\TorrentSummary.addedSortDate, order: order)
        case .completedOn:
            descriptor = KeyPathComparator(\TorrentSummary.completedSortDate, order: order)
        case .lastActive:
            descriptor = KeyPathComparator(\TorrentSummary.activitySortDate, order: order)
        case .path:
            descriptor = KeyPathComparator(\TorrentSummary.downloadDir, comparator: .localizedStandard, order: order)
        case .priority:
            descriptor = KeyPathComparator(\TorrentSummary.bandwidthPriority, order: order)
        case .sizeToDownload:
            descriptor = KeyPathComparator(\TorrentSummary.sizeToDownload, order: order)
        case .torrentID:
            descriptor = KeyPathComparator(\TorrentSummary.id, order: order)
        case .queuePosition:
            descriptor = KeyPathComparator(\TorrentSummary.queuePosition, order: order)
        case .seedingTime:
            descriptor = KeyPathComparator(\TorrentSummary.secondsSeeding, order: order)
        case .sizeLeft:
            descriptor = KeyPathComparator(\TorrentSummary.leftUntilDone, order: order)
        case .privateTorrent:
            descriptor = KeyPathComparator(\TorrentSummary.privacySortValue, order: order)
        case .labels:
            descriptor = KeyPathComparator(\TorrentSummary.labelsDisplay, comparator: .localizedStandard, order: order)
        }
        return [descriptor]
    }

    static func preference(
        for descriptors: [KeyPathComparator<TorrentSummary>]
    ) -> TorrentTableSortPreference? {
        guard let descriptor = descriptors.first,
              let columnID = columnID(for: descriptor.keyPath) else {
            return nil
        }
        return TorrentTableSortPreference(
            columnID: columnID,
            direction: TorrentTableSortDirection(descriptor.order)
        )
    }

    private static func columnID(
        for keyPath: PartialKeyPath<TorrentSummary>
    ) -> TorrentTableColumnID? {
        switch keyPath {
        case \TorrentSummary.name: .name
        case \TorrentSummary.displaySize: .size
        case \TorrentSummary.percentDone: .done
        case \TorrentSummary.status.rawValue: .status
        case \TorrentSummary.seedsConnected: .seeds
        case \TorrentSummary.peersConnected: .peers
        case \TorrentSummary.rateDownload: .downloadSpeed
        case \TorrentSummary.rateUpload: .uploadSpeed
        case \TorrentSummary.eta: .eta
        case \TorrentSummary.uploadRatio: .ratio
        case \TorrentSummary.downloadedEver: .downloaded
        case \TorrentSummary.uploadedEver: .uploaded
        case \TorrentSummary.trackerHost: .tracker
        case \TorrentSummary.trackerStatusDisplay: .trackerStatus
        case \TorrentSummary.addedSortDate: .addedOn
        case \TorrentSummary.completedSortDate: .completedOn
        case \TorrentSummary.activitySortDate: .lastActive
        case \TorrentSummary.downloadDir: .path
        case \TorrentSummary.bandwidthPriority: .priority
        case \TorrentSummary.sizeToDownload: .sizeToDownload
        case \TorrentSummary.id: .torrentID
        case \TorrentSummary.queuePosition: .queuePosition
        case \TorrentSummary.secondsSeeding: .seedingTime
        case \TorrentSummary.leftUntilDone: .sizeLeft
        case \TorrentSummary.privacySortValue: .privateTorrent
        case \TorrentSummary.labelsDisplay: .labels
        default: nil
        }
    }
}

struct TorrentRPCFieldRequirement: Hashable, Sendable {
    var field: String
    var minimumRPCVersion: Int?
    var maximumRPCVersion: Int?

    init(_ field: String, minimumRPCVersion: Int? = nil, maximumRPCVersion: Int? = nil) {
        self.field = field
        self.minimumRPCVersion = minimumRPCVersion
        self.maximumRPCVersion = maximumRPCVersion
    }

    func isSupported(by rpcVersion: Int) -> Bool {
        if let minimumRPCVersion, rpcVersion < minimumRPCVersion { return false }
        if let maximumRPCVersion, rpcVersion > maximumRPCVersion { return false }
        return true
    }
}

enum TorrentTableFieldRequirements {
    static let identityRequired: Set<TorrentRPCFieldRequirement> = [
        TorrentRPCFieldRequirement("hashString"),
        TorrentRPCFieldRequirement("id"),
        TorrentRPCFieldRequirement("name"),
    ]

    // These values drive row identity, progress, action enablement, size summaries,
    // and safe delete-data estimates. They must be current for every changed row.
    static let alwaysNeededBehaviorDynamicRequired: Set<TorrentRPCFieldRequirement> = [
        TorrentRPCFieldRequirement("haveUnchecked"),
        TorrentRPCFieldRequirement("haveValid"),
        TorrentRPCFieldRequirement("leftUntilDone"),
        TorrentRPCFieldRequirement("metadataPercentComplete", minimumRPCVersion: 7),
        TorrentRPCFieldRequirement("percentDone"),
        TorrentRPCFieldRequirement("rateDownload"),
        TorrentRPCFieldRequirement("rateUpload"),
        TorrentRPCFieldRequirement("recheckProgress"),
        TorrentRPCFieldRequirement("sizeWhenDone"),
        TorrentRPCFieldRequirement("status"),
        TorrentRPCFieldRequirement("totalSize"),
    ]

    // Status/error filters and sidebar activity counts change at delta cadence.
    static let filterSidebarDynamicRequired: Set<TorrentRPCFieldRequirement> = [
        TorrentRPCFieldRequirement("announceResponse", maximumRPCVersion: 6),
        TorrentRPCFieldRequirement("errorString"),
    ]

    // Recently-active rows must carry modern tracker state so recovery and
    // failure indicators do not remain stale until the repair snapshot.
    static let trackerStatusDynamicRequired: Set<TorrentRPCFieldRequirement> = [
        TorrentRPCFieldRequirement("trackerStats", minimumRPCVersion: 7),
    ]

    // Path, label, and tracker sidebar generations are refreshed by full snapshots
    // and targeted mutation/bootstrap fetches rather than every recently-active poll.
    static let filterSidebarStaticRequired: Set<TorrentRPCFieldRequirement> = [
        TorrentRPCFieldRequirement("downloadDir"),
        TorrentRPCFieldRequirement("labels", minimumRPCVersion: 16),
    ]

    // Two scalar metadata values make the first General selection useful without
    // fetching every torrent's potentially large piece bitfield.
    static let overviewStaticRequired: Set<TorrentRPCFieldRequirement> = [
        TorrentRPCFieldRequirement("pieceCount"),
        TorrentRPCFieldRequirement("pieceSize"),
    ]

    // Both generations contain nested tracker dictionaries. Full snapshots
    // use exactly one compatible generation; modern deltas also refresh status.
    static let heavyweightTrackerMetadataRequired: Set<TorrentRPCFieldRequirement> = [
        TorrentRPCFieldRequirement("trackers", maximumRPCVersion: 6),
        TorrentRPCFieldRequirement("trackerStats", minimumRPCVersion: 7),
    ]

    static var fullBaselineRequired: Set<TorrentRPCFieldRequirement> {
        identityRequired
            .union(alwaysNeededBehaviorDynamicRequired)
            .union(filterSidebarDynamicRequired)
            .union(filterSidebarStaticRequired)
            .union(overviewStaticRequired)
            .union(heavyweightTrackerMetadataRequired)
    }

    static func identityFields(rpcVersion: Int) -> [String] {
        supportedFields(in: identityRequired, rpcVersion: rpcVersion)
    }

    static func alwaysNeededBehaviorDynamicFields(rpcVersion: Int) -> [String] {
        supportedFields(in: alwaysNeededBehaviorDynamicRequired, rpcVersion: rpcVersion)
    }

    static func filterSidebarDynamicFields(rpcVersion: Int) -> [String] {
        supportedFields(in: filterSidebarDynamicRequired, rpcVersion: rpcVersion)
    }

    static func filterSidebarStaticFields(rpcVersion: Int) -> [String] {
        supportedFields(in: filterSidebarStaticRequired, rpcVersion: rpcVersion)
    }

    static func heavyweightTrackerMetadataFields(rpcVersion: Int) -> [String] {
        supportedFields(in: heavyweightTrackerMetadataRequired, rpcVersion: rpcVersion)
    }

    static func fullBaselineFields(rpcVersion: Int) -> [String] {
        supportedFields(in: fullBaselineRequired, rpcVersion: rpcVersion)
    }

    static func presentationRequirements(
        for visibleColumns: Set<TorrentTableColumnID>
    ) -> Set<TorrentRPCFieldRequirement> {
        visibleColumns.reduce(into: Set<TorrentRPCFieldRequirement>()) { result, columnID in
            result.formUnion(presentationRequirements(for: columnID))
        }
    }

    static func dynamicPresentationRequirements(
        for projectionColumns: Set<TorrentTableColumnID>
    ) -> Set<TorrentRPCFieldRequirement> {
        projectionColumns.reduce(into: Set<TorrentRPCFieldRequirement>()) { result, columnID in
            result.formUnion(dynamicPresentationRequirements(for: columnID))
        }
    }

    static func staticPresentationRequirements(
        for projectionColumns: Set<TorrentTableColumnID>
    ) -> Set<TorrentRPCFieldRequirement> {
        projectionColumns.reduce(into: Set<TorrentRPCFieldRequirement>()) { result, columnID in
            result.formUnion(staticPresentationRequirements(for: columnID))
        }
    }

    static func optionalPresentationFields(
        for visibleColumns: Set<TorrentTableColumnID>,
        rpcVersion: Int
    ) -> [String] {
        supportedFields(in: presentationRequirements(for: visibleColumns), rpcVersion: rpcVersion)
    }

    static func optionalDynamicPresentationFields(
        for visibleColumns: Set<TorrentTableColumnID>,
        rpcVersion: Int
    ) -> [String] {
        supportedFields(
            in: dynamicPresentationRequirements(for: visibleColumns),
            rpcVersion: rpcVersion
        )
    }

    static func optionalStaticPresentationFields(
        for visibleColumns: Set<TorrentTableColumnID>,
        rpcVersion: Int
    ) -> [String] {
        supportedFields(
            in: staticPresentationRequirements(for: visibleColumns),
            rpcVersion: rpcVersion
        )
    }

    static func fields(
        for visibleColumns: Set<TorrentTableColumnID>,
        rpcVersion: Int
    ) -> [String] {
        supportedFields(
            in: fullBaselineRequired.union(presentationRequirements(for: visibleColumns)),
            rpcVersion: rpcVersion
        )
    }

    static func presentationRequirements(
        for columnID: TorrentTableColumnID
    ) -> Set<TorrentRPCFieldRequirement> {
        dynamicPresentationRequirements(for: columnID)
            .union(staticPresentationRequirements(for: columnID))
    }

    static func dynamicPresentationRequirements(
        for columnID: TorrentTableColumnID
    ) -> Set<TorrentRPCFieldRequirement> {
        switch columnID {
        case .name, .size, .done, .status:
            []
        case .seeds:
            requirements("peersSendingToUs")
                .union(trackerGenerationRequirements(legacyField: "seeders"))
        case .peers:
            requirements("peersGettingFromUs")
                .union(trackerGenerationRequirements(legacyField: "leechers"))
        case .downloadSpeed, .uploadSpeed:
            []
        case .eta:
            requirements("eta")
        case .ratio:
            requirements("uploadRatio")
        case .downloaded:
            requirements("downloadedEver")
        case .uploaded:
            requirements("uploadedEver")
        case .tracker:
            []
        case .trackerStatus:
            []
        case .addedOn:
            []
        case .completedOn:
            requirements("doneDate")
        case .lastActive:
            requirements("activityDate")
        case .path:
            []
        case .priority:
            requirements("bandwidthPriority")
        case .sizeToDownload:
            []
        case .torrentID:
            []
        case .queuePosition:
            requirements("queuePosition")
        case .seedingTime:
            requirements("secondsSeeding")
        case .sizeLeft:
            []
        case .privateTorrent:
            []
        case .labels:
            []
        }
    }

    static func staticPresentationRequirements(
        for columnID: TorrentTableColumnID
    ) -> Set<TorrentRPCFieldRequirement> {
        switch columnID {
        case .addedOn:
            requirements("addedDate")
        case .privateTorrent:
            requirements("isPrivate")
        case .name, .size, .done, .status, .seeds, .peers, .downloadSpeed,
             .uploadSpeed, .eta, .ratio, .downloaded, .uploaded, .tracker,
             .trackerStatus, .completedOn, .lastActive, .path, .priority,
             .sizeToDownload, .torrentID, .queuePosition, .seedingTime,
             .sizeLeft, .labels:
            []
        }
    }

    private static func trackerGenerationRequirements(
        legacyField: String
    ) -> Set<TorrentRPCFieldRequirement> {
        [
            TorrentRPCFieldRequirement(legacyField, maximumRPCVersion: 6),
        ]
    }

    private static func requirements(_ fields: String...) -> Set<TorrentRPCFieldRequirement> {
        Set(fields.map { TorrentRPCFieldRequirement($0) })
    }

    private static func supportedFields(
        in requirements: Set<TorrentRPCFieldRequirement>,
        rpcVersion: Int
    ) -> [String] {
        Array(Set(requirements.lazy.filter { $0.isSupported(by: rpcVersion) }.map(\.field))).sorted()
    }
}
