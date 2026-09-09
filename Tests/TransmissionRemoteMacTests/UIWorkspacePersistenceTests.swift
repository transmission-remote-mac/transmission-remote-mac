// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation
import XCTest
@testable import TransmissionRemoteMac

@MainActor
final class UIWorkspacePersistenceTests: XCTestCase {
    func testRoundTripPreservesWorkspaceAndReusesSecondaryTableLayouts() throws {
        let files = SecondaryTableLayoutPreference.defaults(for: .files)
            .settingColumnVisibility(false, columnID: SecondaryTableColumnID.Files.priority, for: .files)
            .settingSort(
                SecondaryTableSortPreference(
                    columnID: SecondaryTableColumnID.Files.progress,
                    direction: .descending
                ),
                for: .files
            )
        let preferences = UIWorkspacePreferences(
            sidebarGrouping: SidebarGroupingPreferences(
                showsTrackers: false,
                showsLabels: true,
                showsDownloadFolders: false
            ),
            filterPane: WorkspaceVisibilityPreference(isVisible: false),
            statusSummary: WorkspaceVisibilityPreference(isVisible: false),
            sidebarWidth: 314,
            infoPane: InfoPaneWorkspacePreferences(
                isVisible: false,
                height: 456,
                selectedDetailPane: .files
            ),
            mainWindow: MainWindowPlacement(
                frame: WorkspaceRect(x: -1600, y: 40, width: 1200, height: 780),
                displayIdentifier: "left-display"
            ),
            secondaryTables: SecondaryTableWorkspacePreferences(files: files)
        )

        let data = try UIWorkspacePersistenceService.encode(preferences)
        let decoded = UIWorkspacePersistenceService.decode(data)

        XCTAssertEqual(decoded, preferences)
        XCTAssertFalse(decoded.filterPane.isVisible)
        XCTAssertFalse(decoded.statusSummary.isVisible)
        XCTAssertEqual(decoded.sidebarWidth, 314)
        XCTAssertEqual(decoded.secondaryTables.files, files)
    }

    func testSchemaContainsNoAuthenticationOrSecretMaterial() throws {
        let data = try UIWorkspacePersistenceService.encode(.defaults)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8)).lowercased()

        XCTAssertFalse(UIWorkspacePreferences.containsAuthenticationSecrets)
        for forbiddenTerm in [
            "password",
            "username",
            "credential",
            "token",
            "privatekey",
            "pkcs12",
            "keychain",
            "bookmark",
            "hostname",
            "rpcpath",
        ] {
            XCTAssertFalse(json.contains(forbiddenTerm), forbiddenTerm)
        }
    }

    func testMalformedAndFutureDocumentsSafelyUseDefaults() throws {
        let malformed = Data(
            """
            {
              "schemaVersion": 1,
              "sidebarGrouping": "broken",
              "infoPane": {"isVisible": "broken", "height": "broken", "selectedDetailPane": "removed"},
              "mainWindow": {"frame": {"x": "broken"}},
              "secondaryTables": {"files": 123}
            }
            """.utf8
        )
        let future = Data(
            """
            {"schemaVersion": 999, "infoPane": {"isVisible": false, "height": 999, "selectedDetailPane": "files"}}
            """.utf8
        )

        XCTAssertEqual(UIWorkspacePersistenceService.decode(malformed), .defaults)
        XCTAssertEqual(UIWorkspacePersistenceService.decode(future), .defaults)
        XCTAssertEqual(UIWorkspacePersistenceService.decode(Data("not-json".utf8)), .defaults)
        XCTAssertEqual(UIWorkspacePersistenceService.decode(nil), .defaults)
    }

    func testSchemaZeroMigrationPreservesValidLegacyValuesAndDefaultsBadOnes() {
        let legacy = Data(
            """
            {
              "showTrackerGroups": false,
              "showLabelGroups": true,
              "showDownloadFolderGroups": false,
              "infoPaneVisible": false,
              "infoPaneHeight": 444,
              "selectedDetailPane": "trackers",
              "mainWindowFrame": {"x": -1400, "y": 20, "width": 1100, "height": 700},
              "mainWindowDisplayIdentifier": "legacy-left"
            }
            """.utf8
        )

        let decoded = UIWorkspacePersistenceService.decode(legacy)

        XCTAssertFalse(decoded.sidebarGrouping.showsTrackers)
        XCTAssertTrue(decoded.sidebarGrouping.showsLabels)
        XCTAssertFalse(decoded.sidebarGrouping.showsDownloadFolders)
        XCTAssertEqual(decoded.infoPane, InfoPaneWorkspacePreferences(
            isVisible: false,
            height: 444,
            selectedDetailPane: .trackers
        ))
        XCTAssertEqual(decoded.mainWindow?.displayIdentifier, "legacy-left")
        XCTAssertEqual(decoded.secondaryTables, .defaults)
    }

    func testInfoPaneHeightAndUnknownPaneNormalizeSafely() {
        let data = Data(
            """
            {
              "schemaVersion": 1,
              "infoPane": {"isVisible": true, "height": -50, "selectedDetailPane": "future-pane"}
            }
            """.utf8
        )

        let decoded = UIWorkspacePersistenceService.decode(data)

        XCTAssertEqual(decoded.infoPane.height, InfoPaneWorkspacePreferences.minimumPersistedHeight)
        XCTAssertEqual(decoded.infoPane.selectedDetailPane, .overview)
    }

    func testNonPositiveWindowDimensionsAreDiscarded() {
        let data = Data(
            #"{"schemaVersion":2,"mainWindow":{"frame":{"x":10,"y":10,"width":0,"height":-20}}}"#.utf8
        )

        let decoded = UIWorkspacePersistenceService.decode(data)

        XCTAssertNil(decoded.mainWindow)
    }

    func testOlderSchemaDefaultsAndMalformedCurrentWidthsNormalize() {
        let schemaOne = Data(
            """
            {"schemaVersion": 1, "sidebarGrouping": {}, "infoPane": {}, "secondaryTables": {}}
            """.utf8
        )
        let tooSmall = Data(
            """
            {"schemaVersion": 2, "sidebarWidth": -50}
            """.utf8
        )
        let tooLarge = Data(
            """
            {"schemaVersion": 2, "sidebarWidth": 50000}
            """.utf8
        )

        XCTAssertEqual(
            UIWorkspacePersistenceService.decode(schemaOne).sidebarWidth,
            UIWorkspacePreferences.defaultSidebarWidth
        )
        XCTAssertTrue(UIWorkspacePersistenceService.decode(schemaOne).filterPane.isVisible)
        XCTAssertTrue(UIWorkspacePersistenceService.decode(schemaOne).statusSummary.isVisible)
        XCTAssertEqual(
            UIWorkspacePersistenceService.decode(tooSmall).sidebarWidth,
            UIWorkspacePreferences.minimumSidebarWidth
        )
        XCTAssertEqual(
            UIWorkspacePersistenceService.decode(tooLarge).sidebarWidth,
            UIWorkspacePreferences.maximumSidebarWidth
        )
    }

    func testOlderAndMalformedOptionalPaneStateDefaultsVisible() {
        let schemaTwo = Data(
            #"{"schemaVersion":2,"sidebarWidth":310}"#.utf8
        )
        let malformedCurrent = Data(
            #"{"schemaVersion":3,"filterPane":{"isVisible":"broken"},"statusSummary":{"isVisible":9}}"#.utf8
        )

        XCTAssertTrue(UIWorkspacePersistenceService.decode(schemaTwo).filterPane.isVisible)
        XCTAssertTrue(UIWorkspacePersistenceService.decode(schemaTwo).statusSummary.isVisible)
        XCTAssertTrue(UIWorkspacePersistenceService.decode(malformedCurrent).filterPane.isVisible)
        XCTAssertTrue(UIWorkspacePersistenceService.decode(malformedCurrent).statusSummary.isVisible)
    }

    func testWorkspaceStorePersistsLayoutChangesWithoutDroppingOtherState() throws {
        let suiteName = "UIWorkspacePersistenceTests.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let initial = UIWorkspacePreferences(
            sidebarGrouping: SidebarGroupingPreferences(showsTrackers: false),
            filterPane: WorkspaceVisibilityPreference(isVisible: false),
            statusSummary: WorkspaceVisibilityPreference(isVisible: false),
            sidebarWidth: 260,
            infoPane: InfoPaneWorkspacePreferences(
                isVisible: true,
                height: 300,
                selectedDetailPane: .files
            )
        )
        userDefaults.set(
            try UIWorkspacePersistenceService.encode(initial),
            forKey: SettingsPortabilityPreferenceKeys.workspace
        )
        let store = UIWorkspacePreferencesStore(userDefaults: userDefaults)
        let placement = MainWindowPlacement(
            frame: WorkspaceRect(x: 40, y: 50, width: 1200, height: 760),
            displayIdentifier: "42"
        )

        store.updateSidebarWidth(344)
        store.updateInfoPaneHeight(418)
        store.updateInfoPaneVisibility(false)
        store.updateSelectedDetailPane(.trackers)
        store.updateMainWindowPlacement(placement)

        let persisted = UIWorkspacePersistenceService.decode(
            userDefaults.data(forKey: SettingsPortabilityPreferenceKeys.workspace)
        )
        XCTAssertTrue(store.hadPersistedPreferencesAtLaunch)
        XCTAssertEqual(persisted.sidebarGrouping, initial.sidebarGrouping)
        XCTAssertEqual(persisted.filterPane, initial.filterPane)
        XCTAssertEqual(persisted.statusSummary, initial.statusSummary)
        XCTAssertEqual(persisted.sidebarWidth, 344)
        XCTAssertEqual(persisted.infoPane, InfoPaneWorkspacePreferences(
            isVisible: false,
            height: 418,
            selectedDetailPane: .trackers
        ))
        XCTAssertEqual(persisted.mainWindow, placement)
        XCTAssertEqual(store.preferences, persisted)
    }

    func testOptionalPaneVisibilityPersistsWithoutDroppingOtherWorkspaceState() throws {
        let suiteName = "UIWorkspacePersistenceTests.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let initial = UIWorkspacePreferences(
            sidebarGrouping: SidebarGroupingPreferences(
                showsTrackers: false,
                showsLabels: true,
                showsDownloadFolders: false
            ),
            sidebarWidth: 388,
            infoPane: InfoPaneWorkspacePreferences(
                isVisible: false,
                height: 470,
                selectedDetailPane: .trackers
            ),
            mainWindow: MainWindowPlacement(
                frame: WorkspaceRect(x: -1_200, y: 55, width: 1_100, height: 730),
                displayIdentifier: "left"
            ),
            secondaryTables: SecondaryTableWorkspacePreferences(
                peers: .defaults(for: .peers).settingColumnVisibility(
                    false,
                    columnID: SecondaryTableColumnID.Peers.client,
                    for: .peers
                )
            )
        )
        userDefaults.set(
            try UIWorkspacePersistenceService.encode(initial),
            forKey: SettingsPortabilityPreferenceKeys.workspace
        )
        let store = UIWorkspacePreferencesStore(userDefaults: userDefaults)

        store.updateFilterPaneVisibility(false)
        store.updateStatusSummaryVisibility(false)

        let reloaded = UIWorkspacePreferencesStore(userDefaults: userDefaults).preferences
        XCTAssertFalse(reloaded.filterPane.isVisible)
        XCTAssertFalse(reloaded.statusSummary.isVisible)
        XCTAssertEqual(reloaded.sidebarGrouping, initial.sidebarGrouping)
        XCTAssertEqual(reloaded.sidebarWidth, initial.sidebarWidth)
        XCTAssertEqual(reloaded.infoPane, initial.infoPane)
        XCTAssertEqual(reloaded.mainWindow, initial.mainWindow)
        XCTAssertEqual(reloaded.secondaryTables, initial.secondaryTables)

        store.toggleFilterPaneVisibility()
        XCTAssertTrue(store.preferences.filterPane.isVisible)
        store.toggleStatusSummaryVisibility()
        XCTAssertTrue(store.preferences.statusSummary.isVisible)
    }

    func testSidebarGroupingSavePersistsWithoutDroppingUnrelatedWorkspaceState() throws {
        let suiteName = "UIWorkspacePersistenceTests.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let initial = UIWorkspacePreferences(
            filterPane: WorkspaceVisibilityPreference(isVisible: false),
            statusSummary: WorkspaceVisibilityPreference(isVisible: false),
            sidebarWidth: 388,
            infoPane: InfoPaneWorkspacePreferences(
                isVisible: false,
                height: 470,
                selectedDetailPane: .files
            ),
            mainWindow: MainWindowPlacement(
                frame: WorkspaceRect(x: -1_200, y: 55, width: 1_100, height: 730),
                displayIdentifier: "left"
            ),
            secondaryTables: SecondaryTableWorkspacePreferences(
                files: .defaults(for: .files).settingColumnVisibility(
                    false,
                    columnID: SecondaryTableColumnID.Files.priority,
                    for: .files
                )
            )
        )
        userDefaults.set(
            try UIWorkspacePersistenceService.encode(initial),
            forKey: SettingsPortabilityPreferenceKeys.workspace
        )
        let store = UIWorkspacePreferencesStore(userDefaults: userDefaults)
        let grouping = SidebarGroupingPreferences(
            showsTrackers: false,
            showsLabels: true,
            showsDownloadFolders: false
        )

        try store.saveSidebarGrouping(grouping)

        let reloaded = UIWorkspacePreferencesStore(userDefaults: userDefaults).preferences
        XCTAssertEqual(store.preferences.sidebarGrouping, grouping)
        XCTAssertEqual(reloaded.sidebarGrouping, grouping)
        XCTAssertEqual(reloaded.filterPane, initial.filterPane)
        XCTAssertEqual(reloaded.statusSummary, initial.statusSummary)
        XCTAssertEqual(reloaded.sidebarWidth, initial.sidebarWidth)
        XCTAssertEqual(reloaded.infoPane, initial.infoPane)
        XCTAssertEqual(reloaded.mainWindow, initial.mainWindow)
        XCTAssertEqual(reloaded.secondaryTables, initial.secondaryTables)
    }

    func testMainWindowPlacementSourceTracksLocalWritesAndClearsExternalReplacement() throws {
        let suiteName = "UIWorkspacePersistenceTests.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let store = UIWorkspacePreferencesStore(userDefaults: userDefaults)
        let sourceID = UUID()
        let localPlacement = MainWindowPlacement(
            frame: WorkspaceRect(x: 40, y: 50, width: 1_200, height: 760),
            displayIdentifier: "42"
        )
        let externalPlacement = MainWindowPlacement(
            frame: WorkspaceRect(x: 80, y: 90, width: 980, height: 700),
            displayIdentifier: "84"
        )

        store.updateMainWindowPlacement(localPlacement, sourceID: sourceID)
        XCTAssertEqual(store.mainWindowPlacementSourceID, sourceID)

        store.updateSidebarWidth(344)
        XCTAssertEqual(store.mainWindowPlacementSourceID, sourceID)

        var importedPreferences = store.preferences
        importedPreferences.mainWindow = externalPlacement
        store.replace(with: importedPreferences)

        XCTAssertEqual(store.preferences.mainWindow, externalPlacement)
        XCTAssertNil(store.mainWindowPlacementSourceID)
    }

    func testSidebarGroupingRenderingDecisionRequiresVisibilityAndContent() {
        let grouping = SidebarGroupingPreferences(
            showsTrackers: false,
            showsLabels: true,
            showsDownloadFolders: true
        )

        XCTAssertFalse(grouping.shouldRender(.trackers, hasContent: true))
        XCTAssertFalse(grouping.shouldRender(.trackers, hasContent: false))
        XCTAssertTrue(grouping.shouldRender(.labels, hasContent: true))
        XCTAssertFalse(grouping.shouldRender(.labels, hasContent: false))
        XCTAssertTrue(grouping.shouldRender(.downloadFolders, hasContent: true))
        XCTAssertFalse(grouping.shouldRender(.downloadFolders, hasContent: false))
    }
}
