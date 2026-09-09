// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation

enum ApplicationSettingsSaveTrigger: Equatable {
    case explicit
    case viewDisappeared
}

enum ApplicationSettingsSaveError: Error, Equatable {
    case invalidDraft(trigger: ApplicationSettingsSaveTrigger, issues: [String])
    case persistenceFailed(message: String, rollbackFailures: [String])
}

struct ApplicationSettingsPersistenceStep {
    var save: @MainActor () throws -> Void
    var rollback: @MainActor () throws -> Void
}

extension ApplicationSettingsSaveError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidDraft(let trigger, let issues):
            let prefix = trigger == .viewDisappeared
                ? "Changes were not saved before Settings closed."
                : "Changes were not saved."
            return [prefix, issues.first].compactMap { $0 }.joined(separator: " ")
        case .persistenceFailed(let message, let rollbackFailures):
            guard !rollbackFailures.isEmpty else { return message }
            return "\(message) Rollback failed: \(rollbackFailures.joined(separator: "; "))"
        }
    }
}

@MainActor
struct ApplicationSettingsSaveCoordinator {
    private let behaviorPreferencesStore: ApplicationBehaviorPreferencesStore
    private let interactionPreferencesStore: ApplicationInteractionPreferencesStore
    private let intakeAutomationPreferencesStore: IntakeAutomationPreferencesStore
    private let watchFolderPreferencesStore: WatchFolderPreferencesStore
    private let workspacePreferencesStore: UIWorkspacePreferencesStore
    private let peerResolutionPreferencesStore: PeerResolutionPreferencesStore
    private let persistPollingPreferences: @MainActor (PollingPreferences) -> Void
    private let applyRuntimeSnapshot: @MainActor (PersistedApplicationSettingsSnapshot) -> Void
    private let releaseChannelConfigured: Bool
    private let shortcutValidationService = CommandShortcutValidationService()

    init(
        behaviorPreferencesStore: ApplicationBehaviorPreferencesStore,
        interactionPreferencesStore: ApplicationInteractionPreferencesStore,
        intakeAutomationPreferencesStore: IntakeAutomationPreferencesStore,
        watchFolderPreferencesStore: WatchFolderPreferencesStore,
        workspacePreferencesStore: UIWorkspacePreferencesStore,
        peerResolutionPreferencesStore: PeerResolutionPreferencesStore,
        releaseChannelConfigured: Bool = UpdateCheckPolicyService.releaseChannelConfigured,
        persistPollingPreferences: @escaping @MainActor (PollingPreferences) -> Void,
        applyRuntimeSnapshot: @escaping @MainActor (PersistedApplicationSettingsSnapshot) -> Void
    ) {
        self.behaviorPreferencesStore = behaviorPreferencesStore
        self.interactionPreferencesStore = interactionPreferencesStore
        self.intakeAutomationPreferencesStore = intakeAutomationPreferencesStore
        self.watchFolderPreferencesStore = watchFolderPreferencesStore
        self.workspacePreferencesStore = workspacePreferencesStore
        self.peerResolutionPreferencesStore = peerResolutionPreferencesStore
        self.releaseChannelConfigured = releaseChannelConfigured
        self.persistPollingPreferences = persistPollingPreferences
        self.applyRuntimeSnapshot = applyRuntimeSnapshot
    }

    func evaluate(
        _ draft: ApplicationSettingsDraft,
        currentPollingPreferences: PollingPreferences
    ) -> ApplicationSettingsDraftEvaluation {
        var issues: [String] = []

        let foregroundInterval = parseInteger(
            draft.polling.foregroundInterval,
            in: PollingPreferences.allowedIntervalSeconds
        )
        let backgroundInterval = parseInteger(
            draft.polling.backgroundInterval,
            in: PollingPreferences.allowedIntervalSeconds
        )
        if foregroundInterval == nil || backgroundInterval == nil {
            issues.append("Polling intervals must be whole seconds between 1 and 999.")
        }
        let polling = PollingPreferences(
            foregroundIntervalSeconds: foregroundInterval
                ?? currentPollingPreferences.foregroundIntervalSeconds,
            backgroundIntervalSeconds: backgroundInterval
                ?? currentPollingPreferences.backgroundIntervalSeconds,
            backgroundPolicy: draft.polling.backgroundPolicy,
            adaptiveIdleEnabled: draft.polling.adaptiveIdleEnabled
        )

        let currentBehavior = behaviorPreferencesStore.preferences
        let parsedSampleLimit = parseInteger(
            draft.behavior.speedAverageSampleLimit,
            in: SpeedAveragingPolicy.allowedSampleLimit
        )
        let parsedWindowSeconds = parseInteger(
            draft.behavior.speedAverageWindowSeconds,
            in: SpeedAveragingPolicy.allowedWindowSeconds
        )
        if draft.behavior.speedAveragingEnabled,
           (parsedSampleLimit == nil || parsedWindowSeconds == nil) {
            issues.append("Speed averaging values must be whole numbers within their displayed ranges.")
        }
        let peerLimit = parseOptionalInteger(
            draft.behavior.addPeerLimit,
            in: AddTorrentPeerLimitParser.validRange
        )
        if !peerLimit.isValid {
            issues.append("The new-torrent peer limit must be blank or within its displayed range.")
        }
        let behavior = ApplicationBehaviorPreferences(
            speedAveraging: SpeedAveragingPolicy(
                isEnabled: draft.behavior.speedAveragingEnabled,
                sampleLimit: parsedSampleLimit
                    ?? currentBehavior.speedAveraging.sampleLimit,
                windowSeconds: parsedWindowSeconds
                    ?? currentBehavior.speedAveraging.windowSeconds
            ),
            completionNotificationsEnabled: draft.behavior.completionNotificationsEnabled,
            promptsForDownloadOptions: draft.behavior.promptsForDownloadOptions,
            addDefaults: AddTorrentDefaults(
                startIntent: draft.behavior.addStartIntent,
                priority: draft.behavior.addPriority,
                unwantedFiles: draft.behavior.addUnwantedFiles,
                peerLimit: peerLimit.isValid
                    ? peerLimit.value
                    : currentBehavior.addDefaults.peerLimit
            )
        )

        let currentIntake = intakeAutomationPreferencesStore.preferences
        let parsedUpdateCadence = parseInteger(
            draft.intake.automaticUpdateCadenceHours,
            in: UpdateCheckPolicy.allowedAutomaticCadenceHours
        )
        let automaticUpdateChecksEnabled = releaseChannelConfigured
            && draft.intake.automaticUpdateChecksEnabled
        if automaticUpdateChecksEnabled, parsedUpdateCadence == nil {
            issues.append("The update cadence must be a whole number from 1 to 720 hours.")
        }
        let intake = IntakeAutomationPreferences(
            clipboardIntake: ClipboardTorrentIntakePolicy(
                isEnabled: draft.intake.clipboardIntakeEnabled
            ),
            sourceTorrentDeletion: draft.intake.sourceTorrentDeletion,
            updateChecks: UpdateCheckPolicy(
                automaticChecksEnabled: automaticUpdateChecksEnabled,
                automaticCadenceHours: parsedUpdateCadence
                    ?? currentIntake.updateChecks.automaticCadenceHours
            )
        )

        let currentWatchFolder = watchFolderPreferencesStore.configuration
        let parsedWatchInterval = parseInteger(
            draft.watchFolder.scanInterval,
            in: WatchFolderConfiguration.allowedScanIntervalSeconds
        )
        let parsedRemoteDestination = parseRemoteDestination(
            draft.watchFolder.remoteDestination
        )
        if draft.watchFolder.isEnabled,
           (parsedWatchInterval == nil || parsedRemoteDestination == nil) {
            issues.append(
                "Watch-folder automation needs an absolute daemon destination and a 5 to 3600 second interval."
            )
        }
        let watchFolderConfiguration: WatchFolderConfiguration
        if draft.watchFolder.isEnabled {
            watchFolderConfiguration = WatchFolderConfiguration(
                isEnabled: true,
                sourceBookmarkData: draft.watchFolder.sourceBookmarkData,
                remoteDestination: parsedRemoteDestination
                    ?? currentWatchFolder.remoteDestination,
                scanIntervalSeconds: parsedWatchInterval
                    ?? currentWatchFolder.scanIntervalSeconds,
                successPolicy: draft.watchFolder.successPolicy,
                submissionPolicy: draft.watchFolder.submissionPolicy,
                processedFolderBookmarkData: draft.watchFolder.processedFolderBookmarkData,
                configurationRevision: currentWatchFolder.configurationRevision
            )
        } else {
            watchFolderConfiguration = WatchFolderConfiguration(
                isEnabled: false,
                sourceBookmarkData: currentWatchFolder.sourceBookmarkData,
                remoteDestination: currentWatchFolder.remoteDestination,
                scanIntervalSeconds: currentWatchFolder.scanIntervalSeconds,
                successPolicy: currentWatchFolder.successPolicy,
                submissionPolicy: currentWatchFolder.submissionPolicy,
                processedFolderBookmarkData: currentWatchFolder.processedFolderBookmarkData,
                configurationRevision: currentWatchFolder.configurationRevision
            )
        }
        if draft.watchFolder.isEnabled, !watchFolderConfiguration.isReadyToScan {
            issues.append(
                "Watch-folder automation needs a selected folder and a processed-files folder when moving sources."
            )
        }

        let shortcutPlan = shortcutValidationService.makeImportPlan(
            from: draft.interaction.shortcutOverrides
        )
        issues.append(contentsOf: shortcutPlan.issues.map(\.message))

        var peerResolution = draft.peerResolution
        do {
            peerResolution.countryDatabaseSourceURL = try PeerCountryDownloadSource
                .validatedCustomURL(draft.peerResolution.countryDatabaseSourceURL)?.absoluteString ?? ""
        } catch {
            issues.append(error.localizedDescription)
        }

        let validatedSettings: ValidatedApplicationSettings?
        if issues.isEmpty {
            validatedSettings = ValidatedApplicationSettings(
                polling: polling,
                behavior: behavior,
                intake: intake,
                watchFolderConfiguration: watchFolderConfiguration,
                sidebarGrouping: draft.sidebarGrouping,
                interaction: draft.interaction,
                peerResolution: peerResolution
            )
        } else {
            validatedSettings = nil
        }

        return ApplicationSettingsDraftEvaluation(
            validatedSettings: validatedSettings,
            validationIssues: issues,
            hasChanges: hasChanges(
                draft,
                polling: polling,
                behavior: behavior,
                intake: intake,
                watchFolder: watchFolderConfiguration,
                currentPollingPreferences: currentPollingPreferences
            )
        )
    }

    func commitIfNeeded(
        trigger: ApplicationSettingsSaveTrigger,
        draft: ApplicationSettingsDraft,
        currentPollingPreferences: PollingPreferences
    ) -> Result<PersistedApplicationSettingsSnapshot?, ApplicationSettingsSaveError> {
        let evaluation = evaluate(
            draft,
            currentPollingPreferences: currentPollingPreferences
        )
        guard evaluation.hasChanges else { return .success(nil) }
        guard let validated = evaluation.validatedSettings else {
            return .failure(.invalidDraft(
                trigger: trigger,
                issues: evaluation.validationIssues
            ))
        }

        let previousBehavior = behaviorPreferencesStore.preferences
        let previousInteraction = interactionPreferencesStore.preferences
        let previousIntake = intakeAutomationPreferencesStore.preferences
        let previousWatchFolder = watchFolderPreferencesStore.configuration
        let previousWatchFolderTransaction = watchFolderPreferencesStore.makeTransactionSnapshot()
        let previousSidebarGrouping = workspacePreferencesStore.preferences.sidebarGrouping
        let previousPeerResolution = peerResolutionPreferencesStore.preferences
        var persistenceSteps: [ApplicationSettingsPersistenceStep] = []
        if validated.behavior != previousBehavior {
            persistenceSteps.append(ApplicationSettingsPersistenceStep(
                save: { try behaviorPreferencesStore.save(validated.behavior) },
                rollback: { try behaviorPreferencesStore.save(previousBehavior) }
            ))
        }
        if validated.interaction != previousInteraction {
            persistenceSteps.append(ApplicationSettingsPersistenceStep(
                save: { try interactionPreferencesStore.save(validated.interaction) },
                rollback: { try interactionPreferencesStore.save(previousInteraction) }
            ))
        }
        if validated.intake != previousIntake {
            persistenceSteps.append(ApplicationSettingsPersistenceStep(
                save: { try intakeAutomationPreferencesStore.save(validated.intake) },
                rollback: { try intakeAutomationPreferencesStore.save(previousIntake) }
            ))
        }
        if validated.watchFolderConfiguration != previousWatchFolder {
            persistenceSteps.append(ApplicationSettingsPersistenceStep(
                save: {
                    try watchFolderPreferencesStore.saveConfiguration(
                        validated.watchFolderConfiguration
                    )
                },
                rollback: {
                    watchFolderPreferencesStore.restoreTransactionSnapshot(
                        previousWatchFolderTransaction
                    )
                }
            ))
        }
        if validated.sidebarGrouping != previousSidebarGrouping {
            persistenceSteps.append(ApplicationSettingsPersistenceStep(
                save: {
                    try workspacePreferencesStore.saveSidebarGrouping(
                        validated.sidebarGrouping
                    )
                },
                rollback: {
                    try workspacePreferencesStore.saveSidebarGrouping(
                        previousSidebarGrouping
                    )
                }
            ))
        }
        if validated.peerResolution != previousPeerResolution {
            persistenceSteps.append(ApplicationSettingsPersistenceStep(
                save: { try peerResolutionPreferencesStore.save(validated.peerResolution) },
                rollback: { try peerResolutionPreferencesStore.save(previousPeerResolution) }
            ))
        }
        let persistenceResult = Self.commitPersistenceSteps(persistenceSteps)
        if case .failure(let error) = persistenceResult {
            return .failure(error)
        }
        if validated.polling != currentPollingPreferences {
            persistPollingPreferences(validated.polling)
        }

        let snapshot = PersistedApplicationSettingsSnapshot(
            polling: validated.polling,
            behavior: behaviorPreferencesStore.preferences,
            intake: intakeAutomationPreferencesStore.preferences,
            watchFolder: watchFolderPreferencesStore.snapshot,
            sidebarGrouping: workspacePreferencesStore.preferences.sidebarGrouping,
            interaction: interactionPreferencesStore.preferences,
            peerResolution: peerResolutionPreferencesStore.preferences
        )
        applyRuntimeSnapshot(snapshot)
        return .success(snapshot)
    }

    static func commitPersistenceSteps(
        _ steps: [ApplicationSettingsPersistenceStep]
    ) -> Result<Void, ApplicationSettingsSaveError> {
        var completedSteps: [ApplicationSettingsPersistenceStep] = []
        do {
            for step in steps {
                try step.save()
                completedSteps.append(step)
            }
            return .success(())
        } catch {
            let rollbackFailures = completedSteps.reversed().compactMap { step -> String? in
                do {
                    try step.rollback()
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }
            return .failure(.persistenceFailed(
                message: error.localizedDescription,
                rollbackFailures: rollbackFailures
            ))
        }
    }

    private func hasChanges(
        _ draft: ApplicationSettingsDraft,
        polling: PollingPreferences,
        behavior: ApplicationBehaviorPreferences,
        intake: IntakeAutomationPreferences,
        watchFolder: WatchFolderConfiguration,
        currentPollingPreferences: PollingPreferences
    ) -> Bool {
        polling != currentPollingPreferences
            || draft.polling.foregroundInterval
                != String(currentPollingPreferences.foregroundIntervalSeconds)
            || draft.polling.backgroundInterval
                != String(currentPollingPreferences.backgroundIntervalSeconds)
            || behavior != behaviorPreferencesStore.preferences
            || draft.behavior.speedAverageSampleLimit
                != String(behaviorPreferencesStore.preferences.speedAveraging.sampleLimit)
            || draft.behavior.speedAverageWindowSeconds
                != String(behaviorPreferencesStore.preferences.speedAveraging.windowSeconds)
            || draft.behavior.addPeerLimit
                != (behaviorPreferencesStore.preferences.addDefaults.peerLimit.map(String.init) ?? "")
            || intake != intakeAutomationPreferencesStore.preferences
            || draft.intake.automaticUpdateCadenceHours
                != String(intakeAutomationPreferencesStore.preferences.updateChecks.automaticCadenceHours)
            || watchFolder != watchFolderPreferencesStore.configuration
            || draft.sidebarGrouping
                != workspacePreferencesStore.preferences.sidebarGrouping
            || draft.interaction != interactionPreferencesStore.preferences
            || draft.peerResolution != peerResolutionPreferencesStore.preferences
    }

    private func parseInteger(_ text: String, in range: ClosedRange<Int>) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(trimmed), range.contains(value) else { return nil }
        return value
    }

    private func parseOptionalInteger(
        _ text: String,
        in range: ClosedRange<Int>
    ) -> (value: Int?, isValid: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return (nil, true) }
        guard let value = Int(trimmed), range.contains(value) else {
            return (nil, false)
        }
        return (value, true)
    }

    private func parseRemoteDestination(_ text: String) -> String? {
        guard !text.isEmpty else { return "" }
        return try? RemotePOSIXDestinationValidator.validated(text)
    }
}
