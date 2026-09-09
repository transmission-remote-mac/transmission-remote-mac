// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import TransmissionRemoteMac

@MainActor
final class ApplicationSettingsSaveCoordinatorTests: XCTestCase {
    func testDraftSessionCoalescesAutomaticSaveWithinOnePresentation() {
        let session = ApplicationSettingsDraftSession()
        let draft = makeDefaultDraft()

        session.beginPresentation()
        XCTAssertTrue(session.claimAutomaticSaveAttempt(for: draft))
        XCTAssertFalse(session.claimAutomaticSaveAttempt(for: draft))

        session.beginPresentation()
        XCTAssertTrue(session.claimAutomaticSaveAttempt(for: draft))
    }

    func testSettingsWindowCloseCommitsDeleteChoiceAndRecreatedStoreRestoresIt() throws {
        let context = try makeContext()
        defer { context.defaults.removePersistentDomain(forName: context.suiteName) }
        var draft = makeDefaultDraft()
        draft.intake.sourceTorrentDeletion = .afterSuccessfulNonDuplicateAdd
        var result: Result<
            PersistedApplicationSettingsSnapshot?,
            ApplicationSettingsSaveError
        >?
        let settingsWindow = NSWindow(
            contentRect: .zero,
            styleMask: [],
            backing: .buffered,
            defer: false
        )
        settingsWindow.contentView = NSHostingView(rootView:
            Color.clear.background {
                SettingsWindowLifecycleBridge {
                    result = context.coordinator.commitIfNeeded(
                        trigger: .viewDisappeared,
                        draft: draft,
                        currentPollingPreferences: .defaults
                    )
                }
                .frame(width: 0, height: 0)
            }
        )
        settingsWindow.contentView?.layoutSubtreeIfNeeded()

        NotificationCenter.default.post(
            name: NSWindow.willCloseNotification,
            object: settingsWindow
        )

        let snapshot = try XCTUnwrap(try XCTUnwrap(result).get())
        XCTAssertEqual(
            snapshot.intake.sourceTorrentDeletion,
            .afterSuccessfulNonDuplicateAdd
        )
        XCTAssertEqual(context.recorder.snapshots, [snapshot])
        XCTAssertEqual(context.intakeStore.preferences, snapshot.intake)
        XCTAssertEqual(
            IntakeAutomationPreferencesStore(userDefaults: context.defaults)
                .preferences.sourceTorrentDeletion,
            .afterSuccessfulNonDuplicateAdd
        )
    }

    func testEveryApplicationPreferenceCategoryPersistsAndMatchesRuntimeSnapshot() throws {
        let context = try makeContext()
        defer { context.defaults.removePersistentDomain(forName: context.suiteName) }
        var draft = makeDefaultDraft()
        draft.polling = ApplicationPollingSettingsDraft(
            foregroundInterval: "7",
            backgroundInterval: "45",
            backgroundPolicy: .suspend,
            adaptiveIdleEnabled: true
        )
        draft.behavior = ApplicationBehaviorSettingsDraft(
            speedAveragingEnabled: true,
            speedAverageSampleLimit: "12",
            speedAverageWindowSeconds: "90",
            completionNotificationsEnabled: false,
            addStartIntent: .paused,
            addPriority: .high,
            addUnwantedFiles: .allUnwantedWhenFileListKnown,
            addPeerLimit: "60",
            promptsForDownloadOptions: false
        )
        draft.intake = ApplicationIntakeSettingsDraft(
            clipboardIntakeEnabled: true,
            sourceTorrentDeletion: .afterSuccessfulNonDuplicateAdd,
            automaticUpdateChecksEnabled: false,
            automaticUpdateCadenceHours: "48"
        )
        draft.watchFolder = ApplicationWatchFolderSettingsDraft(
            isEnabled: true,
            sourceBookmarkData: Data([0x01]),
            remoteDestination: "/remote/archive",
            scanInterval: "90",
            successPolicy: .deleteSource,
            submissionPolicy: .submitDirectly,
            processedFolderBookmarkData: nil
        )
        draft.sidebarGrouping = SidebarGroupingPreferences(
            showsTrackers: false,
            showsLabels: true,
            showsDownloadFolders: false
        )
        draft.interaction = ApplicationInteractionPreferences(
            dateDisplay: DateDisplayPreferences(mode: .relative),
            shortcutOverrides: []
        )
        draft.peerResolution = PeerResolutionPreferences(
            resolveHostNames: true,
            resolveCountries: false,
            showCountryFlags: false
        )

        let result = context.coordinator.commitIfNeeded(
            trigger: .explicit,
            draft: draft,
            currentPollingPreferences: .defaults
        )
        let snapshot = try XCTUnwrap(try result.get())
        let reloadedBehavior = ApplicationBehaviorPreferencesStore(
            userDefaults: context.defaults
        )
        let reloadedInteraction = ApplicationInteractionPreferencesStore(
            userDefaults: context.defaults
        )
        let reloadedIntake = IntakeAutomationPreferencesStore(
            userDefaults: context.defaults
        )
        let reloadedWatchFolder = WatchFolderPreferencesStore(
            userDefaults: context.defaults
        )
        let reloadedWorkspace = UIWorkspacePreferencesStore(
            userDefaults: context.defaults
        )
        let reloadedPeerResolution = PeerResolutionPreferencesStore(
            userDefaults: context.defaults
        )

        XCTAssertEqual(PollingPreferences.load(from: context.defaults), snapshot.polling)
        XCTAssertEqual(reloadedBehavior.preferences, snapshot.behavior)
        XCTAssertFalse(snapshot.behavior.promptsForDownloadOptions)
        XCTAssertEqual(reloadedInteraction.preferences, snapshot.interaction)
        XCTAssertEqual(reloadedIntake.preferences, snapshot.intake)
        XCTAssertEqual(reloadedWatchFolder.snapshot, snapshot.watchFolder)
        XCTAssertEqual(
            reloadedWorkspace.preferences.sidebarGrouping,
            snapshot.sidebarGrouping
        )
        XCTAssertEqual(reloadedPeerResolution.preferences, snapshot.peerResolution)
        XCTAssertEqual(context.recorder.snapshots, [snapshot])
        XCTAssertEqual(snapshot.polling.foregroundIntervalSeconds, 7)
        XCTAssertEqual(snapshot.polling.backgroundIntervalSeconds, 45)
        XCTAssertEqual(snapshot.polling.backgroundPolicy, .suspend)
        XCTAssertTrue(snapshot.polling.adaptiveIdleEnabled)
        XCTAssertTrue(snapshot.behavior.speedAveraging.isEnabled)
        XCTAssertEqual(snapshot.behavior.speedAveraging.sampleLimit, 12)
        XCTAssertEqual(snapshot.behavior.speedAveraging.windowSeconds, 90)
        XCTAssertFalse(snapshot.behavior.completionNotificationsEnabled)
        XCTAssertEqual(snapshot.behavior.addDefaults.startIntent, .paused)
        XCTAssertEqual(snapshot.behavior.addDefaults.priority, .high)
        XCTAssertEqual(
            snapshot.behavior.addDefaults.unwantedFiles,
            .allUnwantedWhenFileListKnown
        )
        XCTAssertEqual(snapshot.behavior.addDefaults.peerLimit, 60)
        XCTAssertTrue(snapshot.intake.clipboardIntake.isEnabled)
        XCTAssertEqual(
            snapshot.intake.sourceTorrentDeletion,
            .afterSuccessfulNonDuplicateAdd
        )
        XCTAssertFalse(snapshot.intake.updateChecks.automaticChecksEnabled)
        XCTAssertEqual(snapshot.intake.updateChecks.automaticCadenceHours, 48)
        XCTAssertTrue(snapshot.watchFolder.configuration.isEnabled)
        XCTAssertEqual(snapshot.watchFolder.configuration.sourceBookmarkData, Data([0x01]))
        XCTAssertEqual(snapshot.watchFolder.configuration.remoteDestination, "/remote/archive")
        XCTAssertEqual(snapshot.watchFolder.configuration.scanIntervalSeconds, 90)
        XCTAssertEqual(snapshot.watchFolder.configuration.successPolicy, .deleteSource)
        XCTAssertEqual(snapshot.watchFolder.configuration.submissionPolicy, .submitDirectly)
        XCTAssertEqual(snapshot.sidebarGrouping, draft.sidebarGrouping)
        XCTAssertEqual(snapshot.interaction.dateDisplay.mode, .relative)
        XCTAssertTrue(snapshot.interaction.shortcutOverrides.isEmpty)
        XCTAssertTrue(snapshot.peerResolution.resolveHostNames)
    }

    func testSidebarGroupingAutoSaveReloadsCleanlyAndPreservesWorkspaceLayout() throws {
        let context = try makeContext()
        defer { context.defaults.removePersistentDomain(forName: context.suiteName) }
        let initialWorkspace = UIWorkspacePreferences(
            sidebarWidth: 376,
            infoPane: InfoPaneWorkspacePreferences(
                isVisible: false,
                height: 512,
                selectedDetailPane: .peers
            ),
            mainWindow: MainWindowPlacement(
                frame: WorkspaceRect(x: 30, y: 40, width: 1_200, height: 780),
                displayIdentifier: "external-display"
            )
        )
        context.workspaceStore.replace(with: initialWorkspace)
        var draft = makeDefaultDraft()
        draft.sidebarGrouping = SidebarGroupingPreferences(
            showsTrackers: false,
            showsLabels: false,
            showsDownloadFolders: true
        )

        let result = context.coordinator.commitIfNeeded(
            trigger: .viewDisappeared,
            draft: draft,
            currentPollingPreferences: .defaults
        )
        let snapshot = try XCTUnwrap(try result.get())
        let reloadedWorkspace = UIWorkspacePreferencesStore(
            userDefaults: context.defaults
        ).preferences
        var reopenedDraft = makeDefaultDraft()
        reopenedDraft.sidebarGrouping = reloadedWorkspace.sidebarGrouping
        let reopenedEvaluation = context.coordinator.evaluate(
            reopenedDraft,
            currentPollingPreferences: .defaults
        )

        XCTAssertEqual(snapshot.sidebarGrouping, draft.sidebarGrouping)
        XCTAssertEqual(reloadedWorkspace.sidebarGrouping, draft.sidebarGrouping)
        XCTAssertEqual(reloadedWorkspace.sidebarWidth, initialWorkspace.sidebarWidth)
        XCTAssertEqual(reloadedWorkspace.infoPane, initialWorkspace.infoPane)
        XCTAssertEqual(reloadedWorkspace.mainWindow, initialWorkspace.mainWindow)
        XCTAssertEqual(context.recorder.snapshots, [snapshot])
        XCTAssertFalse(reopenedEvaluation.hasChanges)
    }

    func testInvalidDraftReturnsVisibleCloseFailureWithoutPersistingOrResettingDraft() throws {
        let context = try makeContext()
        defer { context.defaults.removePersistentDomain(forName: context.suiteName) }
        var draft = makeDefaultDraft()
        draft.polling.foregroundInterval = "invalid"
        let originalDraft = draft

        let result = context.coordinator.commitIfNeeded(
            trigger: .viewDisappeared,
            draft: draft,
            currentPollingPreferences: .defaults
        )

        guard case .failure(.invalidDraft(let trigger, let issues)) = result else {
            return XCTFail("Expected invalid draft failure")
        }
        XCTAssertEqual(trigger, .viewDisappeared)
        XCTAssertEqual(issues, ["Polling intervals must be whole seconds between 1 and 999."])
        XCTAssertEqual(draft, originalDraft)
        XCTAssertTrue(context.recorder.snapshots.isEmpty)
        XCTAssertEqual(context.intakeStore.preferences, .defaults)
    }

    func testDisabledDependentFieldsReuseLastValidValuesInsteadOfBlockingSave() throws {
        let context = try makeContext()
        defer { context.defaults.removePersistentDomain(forName: context.suiteName) }
        var draft = makeDefaultDraft()
        draft.behavior.speedAveragingEnabled = false
        draft.behavior.speedAverageSampleLimit = "invalid"
        draft.behavior.speedAverageWindowSeconds = "invalid"
        draft.intake.automaticUpdateChecksEnabled = false
        draft.intake.automaticUpdateCadenceHours = "invalid"
        draft.watchFolder.isEnabled = false
        draft.watchFolder.remoteDestination = "relative/path"
        draft.watchFolder.scanInterval = "invalid"
        draft.intake.sourceTorrentDeletion = .afterSuccessfulNonDuplicateAdd

        let evaluation = context.coordinator.evaluate(
            draft,
            currentPollingPreferences: .defaults
        )

        XCTAssertTrue(evaluation.validationIssues.isEmpty)
        XCTAssertEqual(
            evaluation.validatedSettings?.behavior.speedAveraging,
            SpeedAveragingPolicy.defaults
        )
        XCTAssertEqual(
            evaluation.validatedSettings?.intake.updateChecks,
            UpdateCheckPolicy.defaults
        )
        XCTAssertEqual(
            evaluation.validatedSettings?.watchFolderConfiguration,
            WatchFolderConfiguration.defaults
        )
    }

    func testDisabledInvalidWatchFolderChildrenDoNotCreateAFalseSavedChange() throws {
        let context = try makeContext()
        defer { context.defaults.removePersistentDomain(forName: context.suiteName) }
        var draft = makeDefaultDraft()
        draft.watchFolder.remoteDestination = "relative/path"
        draft.watchFolder.scanInterval = "invalid"

        let evaluation = context.coordinator.evaluate(
            draft,
            currentPollingPreferences: .defaults
        )
        let result = context.coordinator.commitIfNeeded(
            trigger: .explicit,
            draft: draft,
            currentPollingPreferences: .defaults
        )

        XCTAssertTrue(evaluation.validationIssues.isEmpty)
        XCTAssertFalse(evaluation.hasChanges)
        XCTAssertEqual(
            evaluation.validatedSettings?.watchFolderConfiguration,
            WatchFolderConfiguration.defaults
        )
        XCTAssertNil(try result.get())
        XCTAssertTrue(context.recorder.snapshots.isEmpty)
    }

    func testEnabledInvalidWatchFolderChildrenFailCloseSaveWithoutPersistence() throws {
        let context = try makeContext()
        defer { context.defaults.removePersistentDomain(forName: context.suiteName) }
        var draft = makeDefaultDraft()
        draft.watchFolder = ApplicationWatchFolderSettingsDraft(
            isEnabled: true,
            sourceBookmarkData: Data([0x01]),
            remoteDestination: "relative/path",
            scanInterval: "invalid",
            successPolicy: .keepSource,
            processedFolderBookmarkData: nil
        )

        let result = context.coordinator.commitIfNeeded(
            trigger: .viewDisappeared,
            draft: draft,
            currentPollingPreferences: .defaults
        )

        guard case .failure(.invalidDraft(let trigger, let issues)) = result else {
            return XCTFail("Expected invalid watch-folder draft failure")
        }
        XCTAssertEqual(trigger, .viewDisappeared)
        XCTAssertEqual(
            issues,
            [
                "Watch-folder automation needs an absolute daemon destination and a 5 to 3600 second interval.",
                "Watch-folder automation needs a selected folder and a processed-files folder when moving sources."
            ]
        )
        XCTAssertEqual(
            context.watchFolderStore.configuration,
            WatchFolderConfiguration.defaults
        )
        XCTAssertTrue(context.recorder.snapshots.isEmpty)
    }

    func testDisablingWatchFolderPreservesLastSavedChildrenDespiteInvalidDraftText() throws {
        let context = try makeContext()
        defer { context.defaults.removePersistentDomain(forName: context.suiteName) }
        let savedConfiguration = WatchFolderConfiguration(
            isEnabled: true,
            sourceBookmarkData: Data([0x01]),
            remoteDestination: "/saved/destination",
            scanIntervalSeconds: 90,
            successPolicy: .moveSource,
            submissionPolicy: .submitDirectly,
            processedFolderBookmarkData: Data([0x02])
        )
        try context.watchFolderStore.saveConfiguration(savedConfiguration)
        var draft = makeDefaultDraft()
        draft.watchFolder = ApplicationWatchFolderSettingsDraft(
            isEnabled: false,
            sourceBookmarkData: Data([0x03]),
            remoteDestination: "relative/path",
            scanInterval: "invalid",
            successPolicy: .deleteSource,
            submissionPolicy: .confirmBeforeAdding,
            processedFolderBookmarkData: nil
        )

        let result = context.coordinator.commitIfNeeded(
            trigger: .explicit,
            draft: draft,
            currentPollingPreferences: .defaults
        )
        let snapshot = try XCTUnwrap(try result.get())
        let reloadedConfiguration = WatchFolderPreferencesStore(
            userDefaults: context.defaults
        ).configuration

        XCTAssertFalse(snapshot.watchFolder.configuration.isEnabled)
        XCTAssertEqual(reloadedConfiguration, snapshot.watchFolder.configuration)
        XCTAssertEqual(
            snapshot.watchFolder.configuration.sourceBookmarkData,
            savedConfiguration.sourceBookmarkData
        )
        XCTAssertEqual(
            snapshot.watchFolder.configuration.remoteDestination,
            savedConfiguration.remoteDestination
        )
        XCTAssertEqual(
            snapshot.watchFolder.configuration.scanIntervalSeconds,
            savedConfiguration.scanIntervalSeconds
        )
        XCTAssertEqual(
            snapshot.watchFolder.configuration.successPolicy,
            savedConfiguration.successPolicy
        )
        XCTAssertEqual(
            snapshot.watchFolder.configuration.submissionPolicy,
            savedConfiguration.submissionPolicy
        )
        XCTAssertEqual(
            snapshot.watchFolder.configuration.processedFolderBookmarkData,
            savedConfiguration.processedFolderBookmarkData
        )
    }

    func testCountryResolutionIntentSurvivesCloseSaveAndStoreRecreation() throws {
        let context = try makeContext()
        defer { context.defaults.removePersistentDomain(forName: context.suiteName) }
        var draft = makeDefaultDraft()
        draft.peerResolution = PeerResolutionPreferences(
            resolveHostNames: true,
            resolveCountries: true,
            showCountryFlags: true
        )

        let result = context.coordinator.commitIfNeeded(
            trigger: .viewDisappeared,
            draft: draft,
            currentPollingPreferences: .defaults
        )
        let snapshot = try XCTUnwrap(try result.get())
        let reloaded = PeerResolutionPreferencesStore(
            userDefaults: context.defaults
        ).preferences
        var reopenedDraft = makeDefaultDraft()
        reopenedDraft.peerResolution = reloaded
        let reopenedEvaluation = context.coordinator.evaluate(
            reopenedDraft,
            currentPollingPreferences: .defaults
        )

        XCTAssertEqual(snapshot.peerResolution, draft.peerResolution)
        XCTAssertEqual(reloaded, draft.peerResolution)
        XCTAssertTrue(reopenedEvaluation.validationIssues.isEmpty)
        XCTAssertFalse(reopenedEvaluation.hasChanges)
    }

    func testCustomCountrySourceSurvivesCloseSaveAndReopenWithoutEnablingLookups() throws {
        let context = try makeContext()
        defer { context.defaults.removePersistentDomain(forName: context.suiteName) }
        var draft = makeDefaultDraft()
        draft.peerResolution.countryDatabaseSourceURL = " https://country.example/ranges.csv.gz "

        let snapshot = try XCTUnwrap(try context.coordinator.commitIfNeeded(
            trigger: .viewDisappeared,
            draft: draft,
            currentPollingPreferences: .defaults
        ).get())
        let reloaded = PeerResolutionPreferencesStore(userDefaults: context.defaults).preferences
        var reopened = makeDefaultDraft()
        reopened.peerResolution = reloaded

        XCTAssertEqual(reloaded.countryDatabaseSourceURL, "https://country.example/ranges.csv.gz")
        XCTAssertEqual(snapshot.peerResolution, reloaded)
        XCTAssertFalse(reloaded.resolveHostNames)
        XCTAssertFalse(reloaded.resolveCountries)
        XCTAssertFalse(reloaded.showCountryFlags)
        XCTAssertFalse(context.coordinator.evaluate(reopened, currentPollingPreferences: .defaults).hasChanges)
    }

    func testInvalidCountrySourceBlocksExplicitAndCloseSaveAndRetainsDraft() throws {
        let context = try makeContext()
        defer { context.defaults.removePersistentDomain(forName: context.suiteName) }
        let originalData = context.defaults.data(forKey: PeerResolutionPreferencesStore.storageKey)
        var draft = makeDefaultDraft()
        draft.peerResolution.countryDatabaseSourceURL = "http://country.example/ranges.csv"

        for trigger in [ApplicationSettingsSaveTrigger.explicit, .viewDisappeared] {
            let result = context.coordinator.commitIfNeeded(
                trigger: trigger,
                draft: draft,
                currentPollingPreferences: .defaults
            )
            guard case .failure(.invalidDraft(let savedTrigger, let issues)) = result else {
                return XCTFail("Invalid country source must block Save")
            }
            XCTAssertEqual(savedTrigger, trigger)
            XCTAssertEqual(issues.count, 1)
            let session = ApplicationSettingsDraftSession()
            session.handleSaveResult(result, retaining: draft)
            XCTAssertEqual(session.retainedDraft?.peerResolution.countryDatabaseSourceURL, draft.peerResolution.countryDatabaseSourceURL)
        }
        XCTAssertTrue(context.recorder.snapshots.isEmpty)
        XCTAssertEqual(context.peerResolutionStore.preferences, .defaults)
        XCTAssertEqual(context.defaults.data(forKey: PeerResolutionPreferencesStore.storageKey), originalData)
    }

    func testCountrySourceResetPersistsDefaultWithoutChangingSavedCountryChoices() throws {
        let context = try makeContext()
        defer { context.defaults.removePersistentDomain(forName: context.suiteName) }
        var saved = PeerResolutionPreferences(
            resolveHostNames: true,
            resolveCountries: true,
            showCountryFlags: true,
            countryDatabaseSourceURL: "https://country.example/ranges.csv"
        )
        try context.peerResolutionStore.save(saved)
        saved.countryDatabaseSourceURL = ""
        var draft = makeDefaultDraft()
        draft.peerResolution = saved

        let snapshot = try XCTUnwrap(try context.coordinator.commitIfNeeded(
            trigger: .explicit,
            draft: draft,
            currentPollingPreferences: .defaults
        ).get())

        XCTAssertEqual(snapshot.peerResolution, saved)
        XCTAssertEqual(PeerResolutionPreferencesStore(userDefaults: context.defaults).preferences, saved)
        XCTAssertNil(try PeerCountryDownloadSource.validatedCustomURL(snapshot.peerResolution.countryDatabaseSourceURL))
    }

    func testInvalidDraftSessionRetainsFailedSaveForTheNextPresentation() {
        let session = ApplicationSettingsDraftSession()
        var draft = makeDefaultDraft()
        draft.polling.foregroundInterval = "invalid"

        session.handleSaveResult(
            .failure(.invalidDraft(
                trigger: .viewDisappeared,
                issues: ["Polling is invalid."]
            )),
            retaining: draft
        )

        XCTAssertEqual(session.retainedDraft, draft)
        XCTAssertEqual(
            session.saveErrorMessage,
            "Changes were not saved before Settings closed. Polling is invalid."
        )

        session.handleSaveResult(.success(nil), retaining: draft)
        XCTAssertNil(session.retainedDraft)
        XCTAssertNil(session.saveErrorMessage)
    }

    func testPersistenceFailureRollsBackCompletedStepsAndReturnsError() {
        var events: [String] = []
        let result = ApplicationSettingsSaveCoordinator.commitPersistenceSteps([
            ApplicationSettingsPersistenceStep(
                save: { events.append("save-first") },
                rollback: { events.append("rollback-first") }
            ),
            ApplicationSettingsPersistenceStep(
                save: {
                    events.append("save-second")
                    throw ApplicationSettingsSaveCoordinatorTestError.writeFailed
                },
                rollback: { events.append("rollback-second") }
            )
        ])

        guard case .failure(let error) = result else {
            return XCTFail("Expected persistence failure")
        }
        XCTAssertEqual(
            error,
            .persistenceFailed(
                message: "Test settings write failed.",
                rollbackFailures: []
            )
        )
        XCTAssertEqual(events, ["save-first", "save-second", "rollback-first"])
    }

    func testWatchFolderPersistenceRollbackRestoresExactRevisionAndRawBytes() throws {
        let context = try makeContext()
        defer { context.defaults.removePersistentDomain(forName: context.suiteName) }
        let baseline = context.watchFolderStore.makeTransactionSnapshot()
        let changedConfiguration = WatchFolderConfiguration(
            isEnabled: false,
            sourceBookmarkData: nil,
            remoteDestination: "/changed",
            scanIntervalSeconds: 90,
            successPolicy: .deleteSource,
            processedFolderBookmarkData: nil
        )

        let result = ApplicationSettingsSaveCoordinator.commitPersistenceSteps([
            ApplicationSettingsPersistenceStep(
                save: {
                    try context.watchFolderStore.saveConfiguration(changedConfiguration)
                },
                rollback: {
                    context.watchFolderStore.restoreTransactionSnapshot(baseline)
                }
            ),
            ApplicationSettingsPersistenceStep(
                save: { throw ApplicationSettingsSaveCoordinatorTestError.writeFailed },
                rollback: {}
            ),
        ])

        guard case .failure = result else {
            return XCTFail("Expected persistence failure")
        }
        XCTAssertEqual(context.watchFolderStore.snapshot, baseline.preferences)
        XCTAssertEqual(
            context.defaults.data(forKey: WatchFolderPreferencesStore.storageKey),
            baseline.persistedData
        )
    }

    func testSavingOneCategoryPreservesUntouchedFuturePreferencePayloads() throws {
        let futureBehavior = Data(#"{"schemaVersion":999,"future":"behavior"}"#.utf8)
        let futureInteraction = Data(#"{"version":999,"future":"interaction"}"#.utf8)
        let futurePeerResolution = Data(#"{"schemaVersion":999,"future":"peers"}"#.utf8)
        let futureWorkspace = Data(#"{"schemaVersion":999,"future":"workspace"}"#.utf8)
        let futureWatchFolder = Data(#"{"schemaVersion":999,"future":"watch"}"#.utf8)
        let context = try makeContext { defaults in
            defaults.set(
                futureBehavior,
                forKey: ApplicationBehaviorPreferencesStore.storageKey
            )
            defaults.set(
                futureInteraction,
                forKey: ApplicationInteractionPreferencesStore.storageKey
            )
            defaults.set(
                futurePeerResolution,
                forKey: PeerResolutionPreferencesStore.storageKey
            )
            defaults.set(
                futureWorkspace,
                forKey: SettingsPortabilityPreferenceKeys.workspace
            )
            defaults.set(
                futureWatchFolder,
                forKey: WatchFolderPreferencesStore.storageKey
            )
        }
        defer { context.defaults.removePersistentDomain(forName: context.suiteName) }
        var draft = makeDefaultDraft()
        draft.intake.sourceTorrentDeletion = .afterSuccessfulNonDuplicateAdd

        let result = context.coordinator.commitIfNeeded(
            trigger: .explicit,
            draft: draft,
            currentPollingPreferences: .defaults
        )

        XCTAssertNotNil(try result.get())
        XCTAssertEqual(
            context.defaults.data(forKey: ApplicationBehaviorPreferencesStore.storageKey),
            futureBehavior
        )
        XCTAssertEqual(
            context.defaults.data(forKey: ApplicationInteractionPreferencesStore.storageKey),
            futureInteraction
        )
        XCTAssertEqual(
            context.defaults.data(forKey: PeerResolutionPreferencesStore.storageKey),
            futurePeerResolution
        )
        XCTAssertEqual(
            context.defaults.data(forKey: SettingsPortabilityPreferenceKeys.workspace),
            futureWorkspace
        )
        XCTAssertEqual(
            context.defaults.data(forKey: WatchFolderPreferencesStore.storageKey),
            futureWatchFolder
        )
    }

    func testShortcutDraftRecreationPreservesInvalidKeysAndEmptyKeyModifiers() {
        let state = ApplicationShortcutDraftState.restoring([
            CommandShortcutPreference(
                commandID: .refresh,
                keyEquivalent: "two keys",
                modifiers: ["command", "shift"]
            ),
            CommandShortcutPreference(
                commandID: .verify,
                keyEquivalent: nil,
                modifiers: ["option"]
            ),
            CommandShortcutPreference(
                commandID: .refresh,
                keyEquivalent: "duplicate",
                modifiers: []
            )
        ])

        XCTAssertEqual(state.customizedCommandIDs, [.refresh, .verify])
        XCTAssertEqual(state.draftsByCommandID[.refresh]?.keyEquivalent, "two keys")
        XCTAssertEqual(state.draftsByCommandID[.refresh]?.modifiers, [.command, .shift])
        XCTAssertEqual(state.draftsByCommandID[.verify]?.keyEquivalent, "")
        XCTAssertEqual(state.draftsByCommandID[.verify]?.modifiers, [.option])
    }

    private func makeContext(
        configureDefaults: (UserDefaults) -> Void = { _ in }
    ) throws -> ApplicationSettingsSaveCoordinatorTestContext {
        let suiteName = "ApplicationSettingsSaveCoordinatorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        configureDefaults(defaults)
        let behaviorStore = ApplicationBehaviorPreferencesStore(userDefaults: defaults)
        let interactionStore = ApplicationInteractionPreferencesStore(userDefaults: defaults)
        let intakeStore = IntakeAutomationPreferencesStore(userDefaults: defaults)
        let watchFolderStore = WatchFolderPreferencesStore(userDefaults: defaults)
        let workspaceStore = UIWorkspacePreferencesStore(userDefaults: defaults)
        let peerResolutionStore = PeerResolutionPreferencesStore(userDefaults: defaults)
        let recorder = ApplicationSettingsRuntimeSnapshotRecorder()
        let coordinator = ApplicationSettingsSaveCoordinator(
            behaviorPreferencesStore: behaviorStore,
            interactionPreferencesStore: interactionStore,
            intakeAutomationPreferencesStore: intakeStore,
            watchFolderPreferencesStore: watchFolderStore,
            workspacePreferencesStore: workspaceStore,
            peerResolutionPreferencesStore: peerResolutionStore,
            persistPollingPreferences: { $0.save(to: defaults) },
            applyRuntimeSnapshot: { recorder.snapshots.append($0) }
        )
        return ApplicationSettingsSaveCoordinatorTestContext(
            coordinator: coordinator,
            intakeStore: intakeStore,
            watchFolderStore: watchFolderStore,
            workspaceStore: workspaceStore,
            peerResolutionStore: peerResolutionStore,
            recorder: recorder,
            defaults: defaults,
            suiteName: suiteName
        )
    }

    private func makeDefaultDraft() -> ApplicationSettingsDraft {
        ApplicationSettingsDraft(
            polling: ApplicationPollingSettingsDraft(
                foregroundInterval: "5",
                backgroundInterval: "20",
                backgroundPolicy: .pollSlowly,
                adaptiveIdleEnabled: false
            ),
            behavior: ApplicationBehaviorSettingsDraft(
                speedAveragingEnabled: false,
                speedAverageSampleLimit: "20",
                speedAverageWindowSeconds: "120",
                completionNotificationsEnabled: true,
                addStartIntent: .start,
                addPriority: .normal,
                addUnwantedFiles: .daemonDefault,
                addPeerLimit: ""
            ),
            intake: ApplicationIntakeSettingsDraft(
                clipboardIntakeEnabled: false,
                sourceTorrentDeletion: .never,
                automaticUpdateChecksEnabled: false,
                automaticUpdateCadenceHours: "24"
            ),
            watchFolder: ApplicationWatchFolderSettingsDraft(
                isEnabled: false,
                sourceBookmarkData: nil,
                remoteDestination: "",
                scanInterval: "60",
                successPolicy: .keepSource,
                processedFolderBookmarkData: nil
            ),
            sidebarGrouping: .defaults,
            interaction: .defaults,
            peerResolution: .defaults
        )
    }
}

@MainActor
private struct ApplicationSettingsSaveCoordinatorTestContext {
    let coordinator: ApplicationSettingsSaveCoordinator
    let intakeStore: IntakeAutomationPreferencesStore
    let watchFolderStore: WatchFolderPreferencesStore
    let workspaceStore: UIWorkspacePreferencesStore
    let peerResolutionStore: PeerResolutionPreferencesStore
    let recorder: ApplicationSettingsRuntimeSnapshotRecorder
    let defaults: UserDefaults
    let suiteName: String
}

@MainActor
private final class ApplicationSettingsRuntimeSnapshotRecorder {
    var snapshots: [PersistedApplicationSettingsSnapshot] = []
}

private enum ApplicationSettingsSaveCoordinatorTestError: LocalizedError {
    case writeFailed

    var errorDescription: String? { "Test settings write failed." }
}
