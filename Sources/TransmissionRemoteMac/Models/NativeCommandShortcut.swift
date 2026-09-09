// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation

enum NativeCommandID: String, CaseIterable, Codable, Hashable, Sendable {
    case addTorrent = "torrent.add"
    case toggleInfoPane = "view.toggle-info-pane"
    case showGeneralDetails = "view.detail.general"
    case showFilesDetails = "view.detail.files"
    case showPeersDetails = "view.detail.peers"
    case showTrackersDetails = "view.detail.trackers"
    case showStatisticsDetails = "view.detail.statistics"
    case filterAllTorrents = "filter.status.all"
    case filterDownloadingTorrents = "filter.status.downloading"
    case filterDoneTorrents = "filter.status.done"
    case filterActiveTorrents = "filter.status.active"
    case filterInactiveTorrents = "filter.status.inactive"
    case filterStoppedTorrents = "filter.status.stopped"
    case filterErrorTorrents = "filter.status.error"
    case filterWaitingTorrents = "filter.status.waiting"
    case toggleConnection = "connection.toggle"
    case cancelConnection = "connection.cancel-or-disconnect"
    case refresh = "connection.refresh"
    case start = "torrent.start"
    case startNow = "torrent.start-now"
    case stop = "torrent.stop"
    case verify = "torrent.verify"
    case reannounce = "torrent.reannounce"
    case properties = "torrent.properties"
    case remove = "torrent.remove"
    case removeAndDeleteData = "torrent.remove-and-delete-data"
    case queueTop = "queue.top"
    case queueUp = "queue.up"
    case queueDown = "queue.down"
    case queueBottom = "queue.bottom"
    case setLabels = "labels.set"
}

enum NativeShortcutModifier: String, CaseIterable, Codable, Hashable, Sendable {
    case command
    case option
    case control
    case shift

    fileprivate var sortOrder: Int {
        switch self {
        case .command: 0
        case .option: 1
        case .control: 2
        case .shift: 3
        }
    }
}

struct NativeCommandShortcut: Codable, Equatable, Hashable, Sendable {
    let keyEquivalent: String
    let modifiers: [NativeShortcutModifier]

    init(
        normalizedKeyEquivalent: String,
        normalizedModifiers: [NativeShortcutModifier]
    ) {
        keyEquivalent = normalizedKeyEquivalent
        modifiers = normalizedModifiers.sorted { $0.sortOrder < $1.sortOrder }
    }

    var stableCombinationID: String {
        (modifiers.map(\.rawValue) + [keyEquivalent]).joined(separator: "+")
    }
}

struct CommandShortcutPreference: Codable, Equatable, Sendable {
    let commandID: String
    let keyEquivalent: String?
    let modifiers: [String]

    init(
        commandID: String,
        keyEquivalent: String?,
        modifiers: [String]
    ) {
        self.commandID = commandID
        self.keyEquivalent = keyEquivalent
        self.modifiers = modifiers
    }

    init(
        commandID: NativeCommandID,
        keyEquivalent: String?,
        modifiers: [String]
    ) {
        self.init(
            commandID: commandID.rawValue,
            keyEquivalent: keyEquivalent,
            modifiers: modifiers
        )
    }
}

struct NativeCommandDescriptor: Equatable, Sendable {
    let id: NativeCommandID
    let title: String
    let defaultShortcut: NativeCommandShortcut
}

struct NativeCommandCatalog: Equatable, Sendable {
    let commands: [NativeCommandDescriptor]

    static let keyboardNavigationCommandIDs = Set(
        TorrentDetailPane.commandNavigationOrder.map(\.navigationCommandID)
            + TorrentFilterStatus.allCases.map(\.navigationCommandID)
    )

    static let current = NativeCommandCatalog(commands: [
        descriptor(.addTorrent, "Add Torrent", "o", [.command]),
        descriptor(.toggleInfoPane, "Show or Hide Info Pane", "f12", []),
        descriptor(.showGeneralDetails, "Show General Details", "g", [.option]),
        descriptor(.showFilesDetails, "Show Files Details", "f", [.option]),
        descriptor(.showPeersDetails, "Show Peers Details", "p", [.option]),
        descriptor(.showTrackersDetails, "Show Trackers Details", "k", [.option]),
        descriptor(.showStatisticsDetails, "Show Statistics Details", "s", [.option]),
        descriptor(.filterAllTorrents, "Filter All Torrents", "1", [.option]),
        descriptor(.filterDownloadingTorrents, "Filter Downloading Torrents", "2", [.option]),
        descriptor(.filterDoneTorrents, "Filter Done Torrents", "3", [.option]),
        descriptor(.filterActiveTorrents, "Filter Active Torrents", "4", [.option]),
        descriptor(.filterInactiveTorrents, "Filter Inactive Torrents", "5", [.option]),
        descriptor(.filterStoppedTorrents, "Filter Stopped Torrents", "6", [.option]),
        descriptor(.filterErrorTorrents, "Filter Error Torrents", "7", [.option]),
        descriptor(.filterWaitingTorrents, "Filter Waiting Torrents", "8", [.option]),
        descriptor(.toggleConnection, "Connect", "k", [.command]),
        descriptor(.cancelConnection, "Cancel or Disconnect", "k", [.command, .shift]),
        descriptor(.refresh, "Refresh", "r", [.command]),
        descriptor(.start, "Start", "return", [.command]),
        descriptor(.startNow, "Start Now", "return", [.command, .option]),
        descriptor(.stop, "Stop", ".", [.command]),
        descriptor(.verify, "Verify Local Data", "v", [.command, .option]),
        descriptor(.reannounce, "Reannounce", "r", [.command, .shift]),
        descriptor(.properties, "Properties", "i", [.command]),
        descriptor(.remove, "Remove", "delete", []),
        descriptor(.removeAndDeleteData, "Remove and Delete Data", "delete", [.shift]),
        descriptor(.queueTop, "Move to Top", "upArrow", [.command, .option]),
        descriptor(.queueUp, "Move Up", "upArrow", [.command]),
        descriptor(.queueDown, "Move Down", "downArrow", [.command]),
        descriptor(.queueBottom, "Move to Bottom", "downArrow", [.command, .option]),
        descriptor(.setLabels, "Set Labels", "l", [.command, .shift])
    ])

    private static func descriptor(
        _ id: NativeCommandID,
        _ title: String,
        _ keyEquivalent: String,
        _ modifiers: [NativeShortcutModifier]
    ) -> NativeCommandDescriptor {
        NativeCommandDescriptor(
            id: id,
            title: title,
            defaultShortcut: NativeCommandShortcut(
                normalizedKeyEquivalent: keyEquivalent,
                normalizedModifiers: modifiers
            )
        )
    }
}

extension TorrentDetailPane {
    static let commandNavigationOrder: [Self] = [
        .overview,
        .files,
        .peers,
        .trackers,
        .statistics
    ]

    var commandTitle: String {
        switch self {
        case .overview: "General"
        case .files: "Files"
        case .peers: "Peers"
        case .trackers: "Trackers"
        case .statistics: "Statistics"
        }
    }

    var navigationCommandID: NativeCommandID {
        switch self {
        case .overview: .showGeneralDetails
        case .files: .showFilesDetails
        case .peers: .showPeersDetails
        case .trackers: .showTrackersDetails
        case .statistics: .showStatisticsDetails
        }
    }
}

extension TorrentFilterStatus {
    var navigationCommandID: NativeCommandID {
        switch self {
        case .all: .filterAllTorrents
        case .downloading: .filterDownloadingTorrents
        case .done: .filterDoneTorrents
        case .active: .filterActiveTorrents
        case .inactive: .filterInactiveTorrents
        case .stopped: .filterStoppedTorrents
        case .error: .filterErrorTorrents
        case .waiting: .filterWaitingTorrents
        }
    }
}

enum NativeNavigationAction: Equatable {
    case showDetailPane(TorrentDetailPane)
    case selectStatusFilter(TorrentFilterStatus)
}

extension NativeCommandID {
    var navigationAction: NativeNavigationAction? {
        if let pane = TorrentDetailPane.commandNavigationOrder.first(where: {
            $0.navigationCommandID == self
        }) {
            return .showDetailPane(pane)
        }
        if let status = TorrentFilterStatus.allCases.first(where: {
            $0.navigationCommandID == self
        }) {
            return .selectStatusFilter(status)
        }
        return nil
    }
}

struct NativeCommandShortcutBinding: Equatable, Sendable {
    let commandID: NativeCommandID
    let shortcut: NativeCommandShortcut?
}

enum CommandShortcutValidationCode: String, Equatable, Hashable, Sendable {
    case duplicateCommand
    case duplicateShortcut
    case invalidKeyEquivalent
    case invalidModifier
    case missingKeyEquivalent
    case reservedShortcut
    case unsafeUnmodifiedKey
    case unknownCommand
}

struct CommandShortcutValidationIssue: Equatable, Error, Sendable {
    let code: CommandShortcutValidationCode
    let commandIDs: [String]
    let message: String
}

struct CommandShortcutImportPlan: Equatable, Sendable {
    let proposedBindings: [NativeCommandShortcutBinding]
    let issues: [CommandShortcutValidationIssue]

    var validatedBindings: [NativeCommandShortcutBinding]? {
        issues.isEmpty ? proposedBindings : nil
    }
}

struct CommandShortcutPreferenceUpgrade: Equatable, Sendable {
    let shortcutOverrides: [CommandShortcutPreference]
    let importPlan: CommandShortcutImportPlan
}
