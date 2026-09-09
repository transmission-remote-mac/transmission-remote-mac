// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation
import XCTest
@testable import TransmissionRemoteMac

@MainActor
final class SettingsPortabilityCoordinatorTests: XCTestCase {
    func testPreMountExportReadsCompletePersistedTableStateDeterministically() throws {
        let fixture = try makeFixture()
        let tableValue = try makeTableValue(variant: 1)
        let expected = try TableColumnCustomizationPortabilityService.validated(tableValue)
        store(tableValue, in: fixture.userDefaults)
        var workspace = UIWorkspacePreferences.defaults
        workspace.filterPane = WorkspaceVisibilityPreference(isVisible: false)
        workspace.statusSummary = WorkspaceVisibilityPreference(isVisible: false)
        fixture.userDefaults.set(
            try UIWorkspacePersistenceService.encode(workspace),
            forKey: SettingsPortabilityPreferenceKeys.workspace
        )
        fixture.runtime.state.visibleTorrentColumns = [.name]

        let firstExport = try fixture.coordinator.exportData()
        let secondExport = try fixture.coordinator.exportData()
        let document = try SettingsPortabilityService.decodeAndValidate(firstExport)

        XCTAssertEqual(firstExport, secondExport)
        XCTAssertEqual(
            document.applicationPreferences.tableColumnCustomizations,
            tableValue
        )
        XCTAssertEqual(
            Set(document.applicationPreferences.torrentTable.visibleColumnIDs),
            Set(expected.visibleTorrentColumns.map(\.rawValue))
        )
        XCTAssertFalse(document.applicationPreferences.workspace.filterPane.isVisible)
        XCTAssertFalse(document.applicationPreferences.workspace.statusSummary.isVisible)
        XCTAssertNotEqual(
            Set(document.applicationPreferences.torrentTable.visibleColumnIDs),
            Set(fixture.runtime.state.visibleTorrentColumns.map(\.rawValue))
        )
    }

    func testImportRoundTripsCompleteMainAndSecondaryTablePayloads() throws {
        let fixture = try makeFixture()
        let tableValue = try makeTableValue(variant: 1)
        let expectedMain = try NativeTableColumnCustomizationFixtureInspector.inspect(
            tableValue.main.encodedValue
        )
        let expectedPeers = try NativeTableColumnCustomizationFixtureInspector.inspect(
            tableValue.peers.encodedValue
        )
        var preferences = try makePreferences(tableValue: tableValue)
        preferences.workspace.filterPane = WorkspaceVisibilityPreference(isVisible: false)
        preferences.workspace.statusSummary = WorkspaceVisibilityPreference(isVisible: false)
        let data = try SettingsPortabilityService.encode(snapshot: SettingsExportSnapshot(
            profiles: [fixture.profile],
            selectedProfileID: fixture.profile.id,
            applicationPreferences: preferences
        ))

        try fixture.coordinator.prepareImport(data, sourceName: "portable.json")
        _ = try fixture.coordinator.confirmImport()

        assertStored(tableValue, in: fixture.userDefaults)
        let reexported = try SettingsPortabilityService.decodeAndValidate(
            fixture.coordinator.exportData()
        )
        XCTAssertEqual(reexported.applicationPreferences.tableColumnCustomizations, tableValue)
        XCTAssertFalse(reexported.applicationPreferences.workspace.filterPane.isVisible)
        XCTAssertFalse(reexported.applicationPreferences.workspace.statusSummary.isVisible)
        let reexportedTableValue = try XCTUnwrap(
            reexported.applicationPreferences.tableColumnCustomizations
        )
        XCTAssertEqual(
            try NativeTableColumnCustomizationFixtureInspector.inspect(
                reexportedTableValue.main.encodedValue
            ),
            expectedMain
        )
        XCTAssertEqual(
            try NativeTableColumnCustomizationFixtureInspector.inspect(
                reexportedTableValue.peers.encodedValue
            ),
            expectedPeers
        )
    }

    func testCancelDiscardsPreviewWithoutWritingAnyStore() throws {
        let fixture = try makeFixture()
        let baselineProfileData = try Data(contentsOf: fixture.profileFileURL)
        let baselineDefaults = try defaultsData(fixture.userDefaults)
        let baselineFileWriteCount = fixture.fileWriter.writeCount
        let importedProfile = try ConnectionProfile.validated(
            id: UUID(),
            name: "Away",
            host: "away.example"
        )
        let data = try SettingsPortabilityService.encode(snapshot: SettingsExportSnapshot(
            profiles: [importedProfile],
            selectedProfileID: importedProfile.id,
            applicationPreferences: .init()
        ))

        try fixture.coordinator.prepareImport(data, sourceName: "portable.json")
        XCTAssertNotNil(fixture.coordinator.preview)

        fixture.coordinator.cancelImport()

        XCTAssertNil(fixture.coordinator.preview)
        XCTAssertEqual(try Data(contentsOf: fixture.profileFileURL), baselineProfileData)
        XCTAssertEqual(try defaultsData(fixture.userDefaults), baselineDefaults)
        XCTAssertEqual(fixture.fileWriter.writeCount, baselineFileWriteCount)
        XCTAssertEqual(fixture.didCommitCount(), 0)
    }

    func testUnchangedProfileStillWarnsWhenPortableCredentialNeedsReentry() throws {
        let fixture = try makeFixture()
        var exportedProfile = fixture.profile
        exportedProfile.password = "redacted-on-export"
        let data = try SettingsPortabilityService.encode(snapshot: SettingsExportSnapshot(
            profiles: [exportedProfile],
            selectedProfileID: exportedProfile.id,
            applicationPreferences: .init()
        ))

        try fixture.coordinator.prepareImport(data, sourceName: "portable.json")

        XCTAssertEqual(
            fixture.coordinator.preview?.plan.profileSkips,
            [SettingsProfileImportSkip(profileID: fixture.profile.id, reason: .unchanged)]
        )
        XCTAssertEqual(
            fixture.coordinator.preview?.credentialNotices,
            [SettingsImportCredentialNotice(
                profileID: fixture.profile.id,
                profileName: fixture.profile.name,
                kind: .rpcPassword
            )]
        )
    }

    func testProfileCommitFailureRollsBackPreviouslyAppliedPreferences() throws {
        let fixture = try makeFixture()
        let baselineTableValue = try makeTableValue(variant: 0)
        let importedTableValue = try makeTableValue(variant: 1)
        store(baselineTableValue, in: fixture.userDefaults)
        let updatedProfile = try ConnectionProfile.validated(
            id: fixture.profile.id,
            name: fixture.profile.name,
            host: "replacement.example"
        )
        let importedPolling = PollingPreferences(
            foregroundIntervalSeconds: 9,
            backgroundIntervalSeconds: 45,
            backgroundPolicy: .suspend
        )
        var importedPreferences = try makePreferences(
            tableValue: importedTableValue,
            polling: importedPolling
        )
        importedPreferences.watchFolderConfiguration = WatchFolderConfiguration(
            isEnabled: false,
            sourceBookmarkData: nil,
            remoteDestination: "/imported",
            scanIntervalSeconds: 90,
            successPolicy: .deleteSource,
            processedFolderBookmarkData: nil
        )
        let data = try SettingsPortabilityService.encode(snapshot: SettingsExportSnapshot(
            profiles: [updatedProfile],
            selectedProfileID: updatedProfile.id,
            applicationPreferences: importedPreferences
        ))
        try fixture.coordinator.prepareImport(data, sourceName: "portable.json")
        fixture.coordinator.collisionPolicy = .updateMatchingIdentifier
        let baselineProfileData = try Data(contentsOf: fixture.profileFileURL)
        let baselineDefaults = try defaultsData(fixture.userDefaults)
        let baselineBehavior = fixture.behaviorStore.preferences
        let baselineInteraction = fixture.interactionStore.preferences
        let baselineIntake = fixture.intakeStore.preferences
        let baselinePeerResolution = fixture.peerResolutionStore.preferences
        let baselineWatchSnapshot = fixture.watchStore.snapshot
        fixture.fileWriter.shouldFail = true

        XCTAssertThrowsError(try fixture.coordinator.confirmImport())

        XCTAssertEqual(try Data(contentsOf: fixture.profileFileURL), baselineProfileData)
        XCTAssertEqual(try defaultsData(fixture.userDefaults), baselineDefaults)
        XCTAssertEqual(fixture.behaviorStore.preferences, baselineBehavior)
        XCTAssertEqual(fixture.interactionStore.preferences, baselineInteraction)
        XCTAssertEqual(fixture.intakeStore.preferences, baselineIntake)
        XCTAssertEqual(fixture.peerResolutionStore.preferences, baselinePeerResolution)
        XCTAssertEqual(fixture.watchStore.snapshot, baselineWatchSnapshot)
        assertStored(baselineTableValue, in: fixture.userDefaults)
        XCTAssertEqual(fixture.didCommitCount(), 0)
        XCTAssertNotNil(fixture.coordinator.preview)
    }

    func testProfileCommitFailureRestoresFuturePreferenceBytesAndRuntimeValue() throws {
        let futureBehavior = Data(#"{"schemaVersion":999,"future":"keep-exactly"}"#.utf8)
        let fixture = try makeFixture { userDefaults in
            userDefaults.set(
                futureBehavior,
                forKey: ApplicationBehaviorPreferencesStore.storageKey
            )
        }
        let updatedProfile = try ConnectionProfile.validated(
            id: fixture.profile.id,
            name: fixture.profile.name,
            host: "replacement.example"
        )
        var importedBehavior = ApplicationBehaviorPreferences.defaults
        importedBehavior.completionNotificationsEnabled = false
        let data = try SettingsPortabilityService.encode(snapshot: SettingsExportSnapshot(
            profiles: [updatedProfile],
            selectedProfileID: updatedProfile.id,
            applicationPreferences: SettingsExportPreferences(behavior: importedBehavior)
        ))
        try fixture.coordinator.prepareImport(data, sourceName: "portable.json")
        fixture.coordinator.collisionPolicy = .updateMatchingIdentifier
        fixture.fileWriter.shouldFail = true

        XCTAssertThrowsError(try fixture.coordinator.confirmImport())

        XCTAssertEqual(
            fixture.userDefaults.data(forKey: ApplicationBehaviorPreferencesStore.storageKey),
            futureBehavior
        )
        XCTAssertEqual(fixture.behaviorStore.preferences, .defaults)
        XCTAssertEqual(fixture.didCommitCount(), 0)
        XCTAssertNotNil(fixture.coordinator.preview)
    }

    func testProfileCommitFailureRestoresFutureWatchFolderBytesAndExactRuntimeSnapshot() throws {
        let futureWatchFolder = Data(#"{"schemaVersion":999,"future":"keep-exactly"}"#.utf8)
        let fixture = try makeFixture { userDefaults in
            userDefaults.set(
                futureWatchFolder,
                forKey: WatchFolderPreferencesStore.storageKey
            )
        }
        let baselineSnapshot = fixture.watchStore.snapshot
        let updatedProfile = try ConnectionProfile.validated(
            id: fixture.profile.id,
            name: fixture.profile.name,
            host: "replacement.example"
        )
        let importedWatchFolder = WatchFolderConfiguration(
            isEnabled: false,
            sourceBookmarkData: nil,
            remoteDestination: "/imported",
            scanIntervalSeconds: 90,
            successPolicy: .deleteSource,
            processedFolderBookmarkData: nil
        )
        let data = try SettingsPortabilityService.encode(snapshot: SettingsExportSnapshot(
            profiles: [updatedProfile],
            selectedProfileID: updatedProfile.id,
            applicationPreferences: SettingsExportPreferences(
                watchFolderConfiguration: importedWatchFolder
            )
        ))
        try fixture.coordinator.prepareImport(data, sourceName: "portable.json")
        fixture.coordinator.collisionPolicy = .updateMatchingIdentifier
        fixture.fileWriter.shouldFail = true

        XCTAssertThrowsError(try fixture.coordinator.confirmImport())

        XCTAssertEqual(
            fixture.userDefaults.data(forKey: WatchFolderPreferencesStore.storageKey),
            futureWatchFolder
        )
        XCTAssertEqual(fixture.watchStore.snapshot, baselineSnapshot)
        XCTAssertEqual(fixture.didCommitCount(), 0)
        XCTAssertNotNil(fixture.coordinator.preview)
    }

    func testConfirmAppliesProfileAndPreferencesThenCommitsRuntimeOnce() throws {
        let fixture = try makeFixture()
        let updatedProfile = try ConnectionProfile.validated(
            id: fixture.profile.id,
            name: fixture.profile.name,
            host: "replacement.example"
        )
        let importedPolling = PollingPreferences(
            foregroundIntervalSeconds: 8,
            backgroundIntervalSeconds: 34,
            backgroundPolicy: .suspend
        )
        let data = try SettingsPortabilityService.encode(snapshot: SettingsExportSnapshot(
            profiles: [updatedProfile],
            selectedProfileID: updatedProfile.id,
            applicationPreferences: SettingsExportPreferences(polling: importedPolling)
        ))
        let baselineFileWriteCount = fixture.fileWriter.writeCount
        try fixture.coordinator.prepareImport(data, sourceName: "portable.json")
        fixture.coordinator.collisionPolicy = .updateMatchingIdentifier

        let result = try fixture.coordinator.confirmImport()

        XCTAssertEqual(result.collection.profiles.first?.host, "replacement.example")
        XCTAssertEqual(result.preferences.polling, importedPolling)
        XCTAssertEqual(
            try fixture.profileStore.load().profiles.first?.host,
            "replacement.example"
        )
        XCTAssertEqual(PollingPreferences.load(from: fixture.userDefaults), importedPolling)
        XCTAssertEqual(fixture.fileWriter.writeCount, baselineFileWriteCount + 1)
        XCTAssertEqual(fixture.didCommitCount(), 1)
        XCTAssertNil(fixture.coordinator.preview)
    }

    func testConfirmRejectsAndRefreshesStalePreviewBeforeAnyWrite() throws {
        let fixture = try makeFixture()
        let updatedProfile = try ConnectionProfile.validated(
            id: fixture.profile.id,
            name: fixture.profile.name,
            host: "replacement.example"
        )
        let data = try SettingsPortabilityService.encode(snapshot: SettingsExportSnapshot(
            profiles: [updatedProfile],
            selectedProfileID: updatedProfile.id,
            applicationPreferences: SettingsExportPreferences()
        ))
        try fixture.coordinator.prepareImport(data, sourceName: "portable.json")
        fixture.coordinator.collisionPolicy = .updateMatchingIdentifier
        let baselineProfileData = try Data(contentsOf: fixture.profileFileURL)
        let baselineDefaults = try defaultsData(fixture.userDefaults)
        let baselineFileWriteCount = fixture.fileWriter.writeCount
        fixture.runtime.state.profiles = [updatedProfile]

        XCTAssertThrowsError(try fixture.coordinator.confirmImport()) { error in
            XCTAssertEqual(
                error as? SettingsPortabilityCoordinatorError,
                .previewOutOfDate
            )
        }

        XCTAssertEqual(try Data(contentsOf: fixture.profileFileURL), baselineProfileData)
        XCTAssertEqual(try defaultsData(fixture.userDefaults), baselineDefaults)
        XCTAssertEqual(fixture.fileWriter.writeCount, baselineFileWriteCount)
        XCTAssertEqual(fixture.didCommitCount(), 0)
        XCTAssertEqual(
            fixture.coordinator.preview?.plan.profileSkips,
            [SettingsProfileImportSkip(profileID: updatedProfile.id, reason: .unchanged)]
        )
    }

    private func makeFixture(
        configureDefaults: (UserDefaults) -> Void = { _ in }
    ) throws -> SettingsPortabilityCoordinatorFixture {
        let suiteName = "SettingsPortabilityCoordinatorTests.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
        configureDefaults(userDefaults)

        let behaviorStore = ApplicationBehaviorPreferencesStore(userDefaults: userDefaults)
        let interactionStore = ApplicationInteractionPreferencesStore(userDefaults: userDefaults)
        let intakeStore = IntakeAutomationPreferencesStore(userDefaults: userDefaults)
        let peerResolutionStore = PeerResolutionPreferencesStore(userDefaults: userDefaults)
        let watchStore = WatchFolderPreferencesStore(userDefaults: userDefaults)
        let polling = PollingPreferences.load(from: userDefaults)
        let profile = try ConnectionProfile.validated(
            id: UUID(),
            name: "Home",
            host: "home.example"
        )
        let profileFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("settings-portability-\(UUID().uuidString).json")
        let fileWriter = SettingsPortabilityTestFileWriter()
        let profileStore = ConnectionProfileStore(
            fileURL: profileFileURL,
            passwordStore: SettingsPortabilityTestPasswordStore(),
            proxyPasswordStore: SettingsPortabilityTestProxyPasswordStore(),
            clientIdentityStore: SettingsPortabilityTestIdentityStore(),
            fileWriter: fileWriter
        )
        try profileStore.save(ConnectionProfileCollection(
            profiles: [profile],
            selectedProfileID: profile.id
        ))

        var commitCount = 0
        let runtime = SettingsPortabilityTestRuntime(
            state: SettingsPortabilityRuntimeState(
                profiles: [profile],
                selectedProfileID: profile.id,
                polling: polling,
                visibleTorrentColumns: Set(
                    TorrentTableColumnID.allCases.filter(\.isVisibleByDefault)
                ),
                torrentSort: TorrentTableDefaults.sort,
                isInfoPaneVisible: UIWorkspacePreferences.defaults.infoPane.isVisible,
                selectedDetailPane: UIWorkspacePreferences.defaults.infoPane.selectedDetailPane
            )
        )
        let coordinator = SettingsPortabilityCoordinator(
            profileStore: profileStore,
            userDefaults: userDefaults,
            behaviorPreferencesStore: behaviorStore,
            interactionPreferencesStore: interactionStore,
            intakeAutomationPreferencesStore: intakeStore,
            peerResolutionPreferencesStore: peerResolutionStore,
            watchFolderPreferencesStore: watchStore,
            currentState: { runtime.state },
            didCommit: { _ in commitCount += 1 }
        )
        return SettingsPortabilityCoordinatorFixture(
            userDefaults: userDefaults,
            profile: profile,
            profileFileURL: profileFileURL,
            fileWriter: fileWriter,
            profileStore: profileStore,
            behaviorStore: behaviorStore,
            interactionStore: interactionStore,
            intakeStore: intakeStore,
            peerResolutionStore: peerResolutionStore,
            watchStore: watchStore,
            runtime: runtime,
            coordinator: coordinator,
            didCommitCount: { commitCount }
        )
    }

    private func defaultsData(_ userDefaults: UserDefaults) throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: userDefaults.dictionaryRepresentation(),
            format: .xml,
            options: 0
        )
    }

    private func makeTableValue(variant: Int) throws -> PortableTableColumnCustomizations {
        if variant == 1 {
            return NativeTableColumnCustomizationFixtures.portableValue
        }
        let visibleTorrentColumns: Set<TorrentTableColumnID> = variant == 0
            ? [.name, .labels, .size]
            : [.name, .done, .uploaded]
        let secondaryTables = SecondaryTableWorkspacePreferences(
            files: SecondaryTableLayoutPreference(
                hiddenColumnIDs: variant == 0
                    ? [SecondaryTableColumnID.Files.priority]
                    : [SecondaryTableColumnID.Files.completed],
                sortPreference: SecondaryTableDefaults.fileSort
            ),
            peers: SecondaryTableLayoutPreference(
                hiddenColumnIDs: variant == 0
                    ? [SecondaryTableColumnID.Peers.port]
                    : [SecondaryTableColumnID.Peers.client],
                sortPreference: SecondaryTableDefaults.peerSort
            ),
            trackers: SecondaryTableLayoutPreference(
                hiddenColumnIDs: variant == 0
                    ? [SecondaryTableColumnID.Trackers.downloads]
                    : [SecondaryTableColumnID.Trackers.status],
                sortPreference: SecondaryTableDefaults.trackerSort
            )
        )
        return try TableColumnCustomizationPortabilityService.legacyPortableValue(
            visibleTorrentColumns: visibleTorrentColumns,
            secondaryTables: secondaryTables
        )
    }

    private func makePreferences(
        tableValue: PortableTableColumnCustomizations,
        polling: PollingPreferences = .defaults
    ) throws -> SettingsExportPreferences {
        let tableSnapshot = try TableColumnCustomizationPortabilityService.validated(tableValue)
        let workspace = UIWorkspacePreferences(
            secondaryTables: SecondaryTableWorkspacePreferences(
                files: SecondaryTableLayoutPreference(
                    hiddenColumnIDs: tableSnapshot.hiddenFileColumnIDs,
                    sortPreference: SecondaryTableDefaults.fileSort
                ),
                peers: SecondaryTableLayoutPreference(
                    hiddenColumnIDs: tableSnapshot.hiddenPeerColumnIDs,
                    sortPreference: SecondaryTableDefaults.peerSort
                ),
                trackers: SecondaryTableLayoutPreference(
                    hiddenColumnIDs: tableSnapshot.hiddenTrackerColumnIDs,
                    sortPreference: SecondaryTableDefaults.trackerSort
                )
            )
        )
        return SettingsExportPreferences(
            polling: polling,
            workspace: workspace,
            visibleTorrentColumns: tableSnapshot.visibleTorrentColumns,
            tableColumnCustomizations: tableValue
        )
    }

    private func store(
        _ tableValue: PortableTableColumnCustomizations,
        in userDefaults: UserDefaults
    ) {
        userDefaults.set(
            tableValue.main.encodedValue,
            forKey: TorrentTableColumnPreferenceKeys.customization
        )
        userDefaults.set(
            tableValue.files.encodedValue,
            forKey: SecondaryTablePreferenceKeys.fileColumns
        )
        userDefaults.set(
            tableValue.peers.encodedValue,
            forKey: SecondaryTablePreferenceKeys.peerColumns
        )
        userDefaults.set(
            tableValue.trackers.encodedValue,
            forKey: SecondaryTablePreferenceKeys.trackerColumns
        )
    }

    private func assertStored(
        _ tableValue: PortableTableColumnCustomizations,
        in userDefaults: UserDefaults,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            userDefaults.data(forKey: TorrentTableColumnPreferenceKeys.customization),
            tableValue.main.encodedValue,
            file: file,
            line: line
        )
        XCTAssertEqual(
            userDefaults.data(forKey: SecondaryTablePreferenceKeys.fileColumns),
            tableValue.files.encodedValue,
            file: file,
            line: line
        )
        XCTAssertEqual(
            userDefaults.data(forKey: SecondaryTablePreferenceKeys.peerColumns),
            tableValue.peers.encodedValue,
            file: file,
            line: line
        )
        XCTAssertEqual(
            userDefaults.data(forKey: SecondaryTablePreferenceKeys.trackerColumns),
            tableValue.trackers.encodedValue,
            file: file,
            line: line
        )
    }
}

@MainActor
private struct SettingsPortabilityCoordinatorFixture {
    let userDefaults: UserDefaults
    let profile: ConnectionProfile
    let profileFileURL: URL
    let fileWriter: SettingsPortabilityTestFileWriter
    let profileStore: ConnectionProfileStore
    let behaviorStore: ApplicationBehaviorPreferencesStore
    let interactionStore: ApplicationInteractionPreferencesStore
    let intakeStore: IntakeAutomationPreferencesStore
    let peerResolutionStore: PeerResolutionPreferencesStore
    let watchStore: WatchFolderPreferencesStore
    let runtime: SettingsPortabilityTestRuntime
    let coordinator: SettingsPortabilityCoordinator
    let didCommitCount: () -> Int
}

@MainActor
private final class SettingsPortabilityTestRuntime {
    var state: SettingsPortabilityRuntimeState

    init(state: SettingsPortabilityRuntimeState) {
        self.state = state
    }
}

private enum SettingsPortabilityTestError: Error {
    case writeDenied
    case unsupportedIdentityImport
}

private final class SettingsPortabilityTestFileWriter: ConnectionProfileFileWriting {
    var shouldFail = false
    private(set) var writeCount = 0

    func write(_ data: Data, to fileURL: URL) throws {
        writeCount += 1
        guard !shouldFail else {
            throw SettingsPortabilityTestError.writeDenied
        }
        try data.write(to: fileURL, options: .atomic)
    }
}

private final class SettingsPortabilityTestPasswordStore: ConnectionPasswordStoring {
    private var passwords: [ConnectionProfile.ID: String] = [:]

    func password(for profileID: ConnectionProfile.ID) throws -> String? {
        passwords[profileID]
    }

    func setPassword(_ password: String, for profileID: ConnectionProfile.ID) throws {
        passwords[profileID] = password
    }

    func removePassword(for profileID: ConnectionProfile.ID) throws {
        passwords.removeValue(forKey: profileID)
    }
}

private final class SettingsPortabilityTestProxyPasswordStore: ConnectionProxyPasswordStoring {
    private var passwords: [ConnectionProfile.ID: String] = [:]

    func password(for profileID: ConnectionProfile.ID) throws -> String? {
        passwords[profileID]
    }

    func setPassword(_ password: String, for profileID: ConnectionProfile.ID) throws {
        passwords[profileID] = password
    }

    func removePassword(for profileID: ConnectionProfile.ID) throws {
        passwords.removeValue(forKey: profileID)
    }
}

private final class SettingsPortabilityTestIdentityStore: ConnectionClientIdentityStoring {
    func importAndBind(
        data: Data,
        passphrase: String,
        profileID: ConnectionProfile.ID,
        scheme: String,
        now: Date
    ) throws -> ClientIdentityMetadata {
        throw SettingsPortabilityTestError.unsupportedIdentityImport
    }

    func persistentReference(for profileID: ConnectionProfile.ID) throws -> Data? {
        nil
    }

    func restorePersistentReference(
        _ persistentReference: Data?,
        for profileID: ConnectionProfile.ID
    ) throws {}

    func removeBinding(for profileID: ConnectionProfile.ID) throws {}
}
