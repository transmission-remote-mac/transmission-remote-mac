// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation

enum SidebarDynamicGroup: String, CaseIterable, Sendable {
    case trackers
    case labels
    case downloadFolders
}

/// Non-secret visibility choices for the dynamic sidebar groups.
struct SidebarGroupingPreferences: Codable, Equatable, Sendable {
    static let defaults = SidebarGroupingPreferences()

    var showsTrackers: Bool
    var showsLabels: Bool
    var showsDownloadFolders: Bool

    init(
        showsTrackers: Bool = true,
        showsLabels: Bool = true,
        showsDownloadFolders: Bool = true
    ) {
        self.showsTrackers = showsTrackers
        self.showsLabels = showsLabels
        self.showsDownloadFolders = showsDownloadFolders
    }

    func isVisible(_ group: SidebarDynamicGroup) -> Bool {
        switch group {
        case .trackers:
            showsTrackers
        case .labels:
            showsLabels
        case .downloadFolders:
            showsDownloadFolders
        }
    }

    func shouldRender(_ group: SidebarDynamicGroup, hasContent: Bool) -> Bool {
        hasContent && isVisible(group)
    }
}

/// Default-on visibility for optional main-window workspace elements.
struct WorkspaceVisibilityPreference: Codable, Equatable, Sendable {
    static let defaults = WorkspaceVisibilityPreference()

    var isVisible: Bool

    init(isVisible: Bool = true) {
        self.isVisible = isVisible
    }
}

struct InfoPaneWorkspacePreferences: Codable, Equatable, Sendable {
    static let defaultHeight = 320.0
    static let minimumPersistedHeight = 120.0
    static let maximumPersistedHeight = 10_000.0
    static let defaults = InfoPaneWorkspacePreferences()

    var isVisible: Bool
    var height: Double
    var selectedDetailPane: TorrentDetailPane

    init(
        isVisible: Bool = true,
        height: Double = Self.defaultHeight,
        selectedDetailPane: TorrentDetailPane = .overview
    ) {
        self.isVisible = isVisible
        self.height = Self.normalizedHeight(height)
        self.selectedDetailPane = selectedDetailPane
    }

    init(from decoder: Decoder) throws {
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
            self = .defaults
            return
        }

        isVisible = (try? container.decode(Bool.self, forKey: .isVisible)) ?? Self.defaults.isVisible
        height = Self.normalizedHeight(
            (try? container.decode(Double.self, forKey: .height)) ?? Self.defaults.height
        )
        let paneIdentifier = try? container.decode(String.self, forKey: .selectedDetailPane)
        selectedDetailPane = paneIdentifier.flatMap(TorrentDetailPane.init(workspaceIdentifier:))
            ?? Self.defaults.selectedDetailPane
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isVisible, forKey: .isVisible)
        try container.encode(Self.normalizedHeight(height), forKey: .height)
        try container.encode(selectedDetailPane.workspaceIdentifier, forKey: .selectedDetailPane)
    }

    private static func normalizedHeight(_ height: Double) -> Double {
        guard height.isFinite else { return defaultHeight }
        return min(max(height, minimumPersistedHeight), maximumPersistedHeight)
    }

    private enum CodingKeys: String, CodingKey {
        case isVisible
        case height
        case selectedDetailPane
    }
}

struct WorkspaceRect: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    var hasFiniteGeometry: Bool {
        x.isFinite && y.isFinite && width.isFinite && height.isFinite
    }
}

struct MainWindowPlacement: Codable, Equatable, Sendable {
    var frame: WorkspaceRect
    var displayIdentifier: String?

    init(frame: WorkspaceRect, displayIdentifier: String?) {
        self.frame = frame
        self.displayIdentifier = displayIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}

/// Reuses the table-specific normalization and stable raw representation instead
/// of introducing a second column/sort persistence model.
struct SecondaryTableWorkspacePreferences: Codable, Equatable, Sendable {
    static let defaults = SecondaryTableWorkspacePreferences()

    var files: SecondaryTableLayoutPreference
    var peers: SecondaryTableLayoutPreference
    var trackers: SecondaryTableLayoutPreference

    init(
        files: SecondaryTableLayoutPreference = .defaults(for: .files),
        peers: SecondaryTableLayoutPreference = .defaults(for: .peers),
        trackers: SecondaryTableLayoutPreference = .defaults(for: .trackers)
    ) {
        self.files = files.normalized(for: .files)
        self.peers = peers.normalized(for: .peers)
        self.trackers = trackers.normalized(for: .trackers)
    }

    init(from decoder: Decoder) throws {
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
            self = .defaults
            return
        }

        self.init(
            files: .restored(
                from: try? container.decode(String.self, forKey: .files),
                for: .files
            ),
            peers: .restored(
                from: try? container.decode(String.self, forKey: .peers),
                for: .peers
            ),
            trackers: .restored(
                from: try? container.decode(String.self, forKey: .trackers),
                for: .trackers
            )
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(files.normalized(for: .files).rawValue, forKey: .files)
        try container.encode(peers.normalized(for: .peers).rawValue, forKey: .peers)
        try container.encode(trackers.normalized(for: .trackers).rawValue, forKey: .trackers)
    }

    private enum CodingKeys: String, CodingKey {
        case files
        case peers
        case trackers
    }
}

/// A versioned, non-secret snapshot of UI-only workspace state.
struct UIWorkspacePreferences: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 3
    static let containsAuthenticationSecrets = false
    static let defaultSidebarWidth = 228.0
    static let minimumSidebarWidth = 180.0
    static let maximumSidebarWidth = 1_200.0
    static let defaults = UIWorkspacePreferences()

    var sidebarGrouping: SidebarGroupingPreferences
    /// The main torrent filter pane, presented as the native macOS sidebar.
    var filterPane: WorkspaceVisibilityPreference
    /// The compact transfer/session summary below the torrent list.
    var statusSummary: WorkspaceVisibilityPreference
    var sidebarWidth: Double
    var infoPane: InfoPaneWorkspacePreferences
    var mainWindow: MainWindowPlacement?
    var secondaryTables: SecondaryTableWorkspacePreferences

    init(
        sidebarGrouping: SidebarGroupingPreferences = .defaults,
        filterPane: WorkspaceVisibilityPreference = .defaults,
        statusSummary: WorkspaceVisibilityPreference = .defaults,
        sidebarWidth: Double = Self.defaultSidebarWidth,
        infoPane: InfoPaneWorkspacePreferences = .defaults,
        mainWindow: MainWindowPlacement? = nil,
        secondaryTables: SecondaryTableWorkspacePreferences = .defaults
    ) {
        self.sidebarGrouping = sidebarGrouping
        self.filterPane = filterPane
        self.statusSummary = statusSummary
        self.sidebarWidth = Self.normalizedSidebarWidth(sidebarWidth)
        self.infoPane = infoPane
        self.mainWindow = Self.validatedPlacement(mainWindow)
        self.secondaryTables = secondaryTables
    }

    init(from decoder: Decoder) throws {
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
            self = .defaults
            return
        }

        let schemaVersion = (try? container.decode(Int.self, forKey: .schemaVersion)) ?? 0
        guard (0 ... Self.currentSchemaVersion).contains(schemaVersion) else {
            self = .defaults
            return
        }

        if schemaVersion == 0 {
            self = Self.migratedSchemaZero(from: container)
            return
        }

        self.init(
            sidebarGrouping: (try? container.decode(
                SidebarGroupingPreferences.self,
                forKey: .sidebarGrouping
            )) ?? .defaults,
            filterPane: (try? container.decode(
                WorkspaceVisibilityPreference.self,
                forKey: .filterPane
            )) ?? .defaults,
            statusSummary: (try? container.decode(
                WorkspaceVisibilityPreference.self,
                forKey: .statusSummary
            )) ?? .defaults,
            sidebarWidth: (try? container.decode(Double.self, forKey: .sidebarWidth))
                ?? Self.defaultSidebarWidth,
            infoPane: (try? container.decode(
                InfoPaneWorkspacePreferences.self,
                forKey: .infoPane
            )) ?? .defaults,
            mainWindow: try? container.decodeIfPresent(
                MainWindowPlacement.self,
                forKey: .mainWindow
            ),
            secondaryTables: (try? container.decode(
                SecondaryTableWorkspacePreferences.self,
                forKey: .secondaryTables
            )) ?? .defaults
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(sidebarGrouping, forKey: .sidebarGrouping)
        try container.encode(filterPane, forKey: .filterPane)
        try container.encode(statusSummary, forKey: .statusSummary)
        try container.encode(Self.normalizedSidebarWidth(sidebarWidth), forKey: .sidebarWidth)
        try container.encode(infoPane, forKey: .infoPane)
        try container.encodeIfPresent(Self.validatedPlacement(mainWindow), forKey: .mainWindow)
        try container.encode(secondaryTables, forKey: .secondaryTables)
    }

    private static func migratedSchemaZero(
        from container: KeyedDecodingContainer<CodingKeys>
    ) -> UIWorkspacePreferences {
        let sidebar = SidebarGroupingPreferences(
            showsTrackers: (try? container.decode(Bool.self, forKey: .showTrackerGroups)) ?? true,
            showsLabels: (try? container.decode(Bool.self, forKey: .showLabelGroups)) ?? true,
            showsDownloadFolders: (try? container.decode(Bool.self, forKey: .showDownloadFolderGroups)) ?? true
        )
        let paneIdentifier = try? container.decode(String.self, forKey: .selectedDetailPane)
        let infoPane = InfoPaneWorkspacePreferences(
            isVisible: (try? container.decode(Bool.self, forKey: .infoPaneVisible)) ?? true,
            height: (try? container.decode(Double.self, forKey: .infoPaneHeight))
                ?? InfoPaneWorkspacePreferences.defaultHeight,
            selectedDetailPane: paneIdentifier.flatMap(TorrentDetailPane.init(workspaceIdentifier:))
                ?? .overview
        )

        let frame = try? container.decode(WorkspaceRect.self, forKey: .mainWindowFrame)
        let displayIdentifier = try? container.decode(String.self, forKey: .mainWindowDisplayIdentifier)
        let placement = frame.map {
            MainWindowPlacement(frame: $0, displayIdentifier: displayIdentifier)
        }
        let secondaryTables = SecondaryTableWorkspacePreferences(
            files: .restored(
                from: try? container.decode(String.self, forKey: .filesTableLayout),
                for: .files
            ),
            peers: .restored(
                from: try? container.decode(String.self, forKey: .peersTableLayout),
                for: .peers
            ),
            trackers: .restored(
                from: try? container.decode(String.self, forKey: .trackersTableLayout),
                for: .trackers
            )
        )

        return UIWorkspacePreferences(
            sidebarGrouping: sidebar,
            filterPane: .defaults,
            statusSummary: .defaults,
            sidebarWidth: Self.defaultSidebarWidth,
            infoPane: infoPane,
            mainWindow: placement,
            secondaryTables: secondaryTables
        )
    }

    static func normalizedSidebarWidth(_ width: Double) -> Double {
        guard width.isFinite else { return defaultSidebarWidth }
        return min(max(width, minimumSidebarWidth), maximumSidebarWidth)
    }

    private static func validatedPlacement(_ placement: MainWindowPlacement?) -> MainWindowPlacement? {
        guard
            let placement,
            placement.frame.hasFiniteGeometry,
            placement.frame.width > 0,
            placement.frame.height > 0
        else {
            return nil
        }
        return MainWindowPlacement(
            frame: placement.frame,
            displayIdentifier: placement.displayIdentifier
        )
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case sidebarGrouping
        case filterPane
        case statusSummary
        case sidebarWidth
        case infoPane
        case mainWindow
        case secondaryTables

        // Schema-zero migration aliases. They decode only and are never emitted.
        case showTrackerGroups
        case showLabelGroups
        case showDownloadFolderGroups
        case infoPaneVisible
        case infoPaneHeight
        case selectedDetailPane
        case mainWindowFrame
        case mainWindowDisplayIdentifier
        case filesTableLayout
        case peersTableLayout
        case trackersTableLayout
    }
}

private extension TorrentDetailPane {
    init?(workspaceIdentifier: String) {
        switch workspaceIdentifier {
        case "overview": self = .overview
        case "files": self = .files
        case "peers": self = .peers
        case "trackers": self = .trackers
        case "statistics": self = .statistics
        default: return nil
        }
    }

    var workspaceIdentifier: String {
        switch self {
        case .overview: "overview"
        case .files: "files"
        case .peers: "peers"
        case .trackers: "trackers"
        case .statistics: "statistics"
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
