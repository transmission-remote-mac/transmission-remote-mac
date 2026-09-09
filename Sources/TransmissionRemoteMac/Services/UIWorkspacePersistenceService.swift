// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Combine
import Foundation

enum UIWorkspacePersistenceService {
    static func encode(_ preferences: UIWorkspacePreferences) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(preferences)
    }

    static func decode(_ data: Data?) -> UIWorkspacePreferences {
        guard let data,
              let decoded = try? JSONDecoder().decode(UIWorkspacePreferences.self, from: data) else {
            return .defaults
        }
        return decoded
    }
}

@MainActor
final class UIWorkspacePreferencesStore: ObservableObject {
    @Published private(set) var preferences: UIWorkspacePreferences

    let hadPersistedPreferencesAtLaunch: Bool
    private(set) var mainWindowPlacementSourceID: UUID?

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        let data = userDefaults.data(forKey: SettingsPortabilityPreferenceKeys.workspace)
        hadPersistedPreferencesAtLaunch = data != nil
        preferences = UIWorkspacePersistenceService.decode(data)
    }

    func replace(with preferences: UIWorkspacePreferences) {
        commit(preferences)
    }

    func saveSidebarGrouping(_ sidebarGrouping: SidebarGroupingPreferences) throws {
        var updated = preferences
        updated.sidebarGrouping = sidebarGrouping
        try commitThrowing(updated)
    }

    func updateFilterPaneVisibility(_ isVisible: Bool) {
        var updated = preferences
        updated.filterPane = WorkspaceVisibilityPreference(isVisible: isVisible)
        commit(updated)
    }

    func toggleFilterPaneVisibility() {
        updateFilterPaneVisibility(!preferences.filterPane.isVisible)
    }

    func updateStatusSummaryVisibility(_ isVisible: Bool) {
        var updated = preferences
        updated.statusSummary = WorkspaceVisibilityPreference(isVisible: isVisible)
        commit(updated)
    }

    func toggleStatusSummaryVisibility() {
        updateStatusSummaryVisibility(!preferences.statusSummary.isVisible)
    }

    func updateSidebarWidth(_ width: Double) {
        var updated = preferences
        updated.sidebarWidth = UIWorkspacePreferences.normalizedSidebarWidth(width)
        commit(updated)
    }

    func updateInfoPaneHeight(_ height: Double) {
        var updated = preferences
        updated.infoPane = InfoPaneWorkspacePreferences(
            isVisible: updated.infoPane.isVisible,
            height: height,
            selectedDetailPane: updated.infoPane.selectedDetailPane
        )
        commit(updated)
    }

    func updateInfoPaneVisibility(_ isVisible: Bool) {
        var updated = preferences
        updated.infoPane = InfoPaneWorkspacePreferences(
            isVisible: isVisible,
            height: updated.infoPane.height,
            selectedDetailPane: updated.infoPane.selectedDetailPane
        )
        commit(updated)
    }

    func updateSelectedDetailPane(_ pane: TorrentDetailPane) {
        var updated = preferences
        updated.infoPane = InfoPaneWorkspacePreferences(
            isVisible: updated.infoPane.isVisible,
            height: updated.infoPane.height,
            selectedDetailPane: pane
        )
        commit(updated)
    }

    func updateMainWindowPlacement(
        _ placement: MainWindowPlacement,
        sourceID: UUID? = nil
    ) {
        var updated = preferences
        updated.mainWindow = placement
        commit(updated, mainWindowPlacementSourceID: sourceID)
    }

    private func commit(
        _ updated: UIWorkspacePreferences,
        mainWindowPlacementSourceID: UUID? = nil
    ) {
        try? commitThrowing(
            updated,
            mainWindowPlacementSourceID: mainWindowPlacementSourceID
        )
    }

    private func commitThrowing(
        _ updated: UIWorkspacePreferences,
        mainWindowPlacementSourceID: UUID? = nil
    ) throws {
        guard updated != preferences else { return }
        let data = try UIWorkspacePersistenceService.encode(updated)
        userDefaults.set(data, forKey: SettingsPortabilityPreferenceKeys.workspace)
        if updated.mainWindow != preferences.mainWindow {
            self.mainWindowPlacementSourceID = mainWindowPlacementSourceID
        }
        preferences = updated
    }
}

struct WorkspaceSize: Equatable, Sendable {
    var width: Double
    var height: Double

    static let defaultMainWindowMinimum = WorkspaceSize(width: 820, height: 620)

    fileprivate var normalizedMinimum: WorkspaceSize {
        guard width.isFinite, height.isFinite, width > 0, height > 0 else {
            return .defaultMainWindowMinimum
        }
        return self
    }
}

struct WorkspaceDisplayDescriptor: Equatable, Sendable {
    var identifier: String
    var visibleFrame: WorkspaceRect

    fileprivate var isUsable: Bool {
        !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && visibleFrame.hasFiniteGeometry
            && visibleFrame.width > 0
            && visibleFrame.height > 0
    }
}

enum WorkspaceDisplaySelectionReason: Equatable, Sendable {
    case savedDisplay
    case greatestVisibleIntersection
}

struct MainWindowRestorationPlan: Equatable, Sendable {
    var frame: WorkspaceRect
    var displayIdentifier: String
    var selectionReason: WorkspaceDisplaySelectionReason
}

enum MainWindowRestorationPlanner {
    static func plan(
        savedPlacement: MainWindowPlacement?,
        displays: [WorkspaceDisplayDescriptor],
        minimumSize: WorkspaceSize = .defaultMainWindowMinimum
    ) -> MainWindowRestorationPlan? {
        guard let savedPlacement,
              savedPlacement.frame.hasFiniteGeometry else {
            return nil
        }

        let usableDisplays = displays.filter(\.isUsable)
        guard !usableDisplays.isEmpty else { return nil }

        let minimumSize = minimumSize.normalizedMinimum
        let selectionFrame = WorkspaceRect(
            x: savedPlacement.frame.x,
            y: savedPlacement.frame.y,
            width: max(savedPlacement.frame.width, minimumSize.width),
            height: max(savedPlacement.frame.height, minimumSize.height)
        )

        let selectedDisplay: WorkspaceDisplayDescriptor
        let selectionReason: WorkspaceDisplaySelectionReason
        if let savedIdentifier = savedPlacement.displayIdentifier,
           let savedDisplay = usableDisplays.first(where: { $0.identifier == savedIdentifier }) {
            selectedDisplay = savedDisplay
            selectionReason = .savedDisplay
        } else {
            selectedDisplay = bestIntersectionDisplay(for: selectionFrame, displays: usableDisplays)
            selectionReason = .greatestVisibleIntersection
        }

        return MainWindowRestorationPlan(
            frame: constrainedFrame(
                savedPlacement.frame,
                to: selectedDisplay.visibleFrame,
                minimumSize: minimumSize
            ),
            displayIdentifier: selectedDisplay.identifier,
            selectionReason: selectionReason
        )
    }

    private static func bestIntersectionDisplay(
        for frame: WorkspaceRect,
        displays: [WorkspaceDisplayDescriptor]
    ) -> WorkspaceDisplayDescriptor {
        displays.max { lhs, rhs in
            let lhsIntersection = intersectionArea(frame, lhs.visibleFrame)
            let rhsIntersection = intersectionArea(frame, rhs.visibleFrame)
            if lhsIntersection != rhsIntersection {
                return lhsIntersection < rhsIntersection
            }

            let lhsDistance = centerDistance(frame, lhs.visibleFrame)
            let rhsDistance = centerDistance(frame, rhs.visibleFrame)
            if lhsDistance != rhsDistance {
                return lhsDistance > rhsDistance
            }

            return lhs.identifier > rhs.identifier
        } ?? displays[0]
    }

    private static func constrainedFrame(
        _ frame: WorkspaceRect,
        to visibleFrame: WorkspaceRect,
        minimumSize: WorkspaceSize
    ) -> WorkspaceRect {
        let effectiveMinimumWidth = min(minimumSize.width, visibleFrame.width)
        let effectiveMinimumHeight = min(minimumSize.height, visibleFrame.height)
        let width = min(max(frame.width, effectiveMinimumWidth), visibleFrame.width)
        let height = min(max(frame.height, effectiveMinimumHeight), visibleFrame.height)
        let maximumX = visibleFrame.x + visibleFrame.width - width
        let maximumY = visibleFrame.y + visibleFrame.height - height

        return WorkspaceRect(
            x: min(max(frame.x, visibleFrame.x), maximumX),
            y: min(max(frame.y, visibleFrame.y), maximumY),
            width: width,
            height: height
        )
    }

    private static func intersectionArea(_ lhs: WorkspaceRect, _ rhs: WorkspaceRect) -> Double {
        let width = max(0, min(lhs.x + lhs.width, rhs.x + rhs.width) - max(lhs.x, rhs.x))
        let height = max(0, min(lhs.y + lhs.height, rhs.y + rhs.height) - max(lhs.y, rhs.y))
        return width * height
    }

    private static func centerDistance(_ lhs: WorkspaceRect, _ rhs: WorkspaceRect) -> Double {
        hypot(
            (lhs.x + lhs.width / 2) - (rhs.x + rhs.width / 2),
            (lhs.y + lhs.height / 2) - (rhs.y + rhs.height / 2)
        )
    }
}
