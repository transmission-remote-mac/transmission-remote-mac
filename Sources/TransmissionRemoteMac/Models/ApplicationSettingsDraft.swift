// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation

struct ApplicationPollingSettingsDraft: Equatable {
    var foregroundInterval: String
    var backgroundInterval: String
    var backgroundPolicy: BackgroundPollingPolicy
    var adaptiveIdleEnabled: Bool
}

struct ApplicationBehaviorSettingsDraft: Equatable {
    var speedAveragingEnabled: Bool
    var speedAverageSampleLimit: String
    var speedAverageWindowSeconds: String
    var completionNotificationsEnabled: Bool
    var addStartIntent: AddTorrentStartIntent
    var addPriority: AddTorrentDefaultPriority
    var addUnwantedFiles: AddTorrentUnwantedFilesDefault
    var addPeerLimit: String
    var promptsForDownloadOptions: Bool = true
}

struct ApplicationIntakeSettingsDraft: Equatable {
    var clipboardIntakeEnabled: Bool
    var sourceTorrentDeletion: SourceTorrentDeletionPolicy
    var automaticUpdateChecksEnabled: Bool
    var automaticUpdateCadenceHours: String
}

struct ApplicationWatchFolderSettingsDraft: Equatable {
    var isEnabled: Bool
    var sourceBookmarkData: Data?
    var remoteDestination: String
    var scanInterval: String
    var successPolicy: WatchFolderSuccessPolicy
    var submissionPolicy: WatchFolderSubmissionPolicy = .confirmBeforeAdding
    var processedFolderBookmarkData: Data?
}

struct ApplicationSettingsDraft: Equatable {
    var polling: ApplicationPollingSettingsDraft
    var behavior: ApplicationBehaviorSettingsDraft
    var intake: ApplicationIntakeSettingsDraft
    var watchFolder: ApplicationWatchFolderSettingsDraft
    var sidebarGrouping: SidebarGroupingPreferences
    var interaction: ApplicationInteractionPreferences
    var peerResolution: PeerResolutionPreferences
}

struct ValidatedApplicationSettings: Equatable {
    var polling: PollingPreferences
    var behavior: ApplicationBehaviorPreferences
    var intake: IntakeAutomationPreferences
    var watchFolderConfiguration: WatchFolderConfiguration
    var sidebarGrouping: SidebarGroupingPreferences
    var interaction: ApplicationInteractionPreferences
    var peerResolution: PeerResolutionPreferences
}

struct PersistedApplicationSettingsSnapshot: Equatable {
    var polling: PollingPreferences
    var behavior: ApplicationBehaviorPreferences
    var intake: IntakeAutomationPreferences
    var watchFolder: WatchFolderPreferencesSnapshot
    var sidebarGrouping: SidebarGroupingPreferences
    var interaction: ApplicationInteractionPreferences
    var peerResolution: PeerResolutionPreferences
}

struct ApplicationSettingsDraftEvaluation: Equatable {
    var validatedSettings: ValidatedApplicationSettings?
    var validationIssues: [String]
    var hasChanges: Bool
}

struct ShortcutEditorDraft: Equatable {
    var keyEquivalent: String
    var modifiers: Set<NativeShortcutModifier>

    init(shortcut: NativeCommandShortcut?) {
        keyEquivalent = shortcut?.keyEquivalent ?? ""
        modifiers = Set(shortcut?.modifiers ?? [])
    }

    init(preference: CommandShortcutPreference) {
        keyEquivalent = preference.keyEquivalent ?? ""
        modifiers = Set(preference.modifiers.compactMap(NativeShortcutModifier.init(rawValue:)))
    }
}

struct ApplicationShortcutDraftState: Equatable {
    var draftsByCommandID: [NativeCommandID: ShortcutEditorDraft]
    var customizedCommandIDs: Set<NativeCommandID>

    static func restoring(
        _ preferences: [CommandShortcutPreference]
    ) -> ApplicationShortcutDraftState {
        var draftsByCommandID: [NativeCommandID: ShortcutEditorDraft] = [:]
        var customizedCommandIDs: Set<NativeCommandID> = []
        for preference in preferences {
            guard let commandID = NativeCommandID(rawValue: preference.commandID) else {
                continue
            }
            customizedCommandIDs.insert(commandID)
            if draftsByCommandID[commandID] == nil {
                draftsByCommandID[commandID] = ShortcutEditorDraft(preference: preference)
            }
        }
        return ApplicationShortcutDraftState(
            draftsByCommandID: draftsByCommandID,
            customizedCommandIDs: customizedCommandIDs
        )
    }
}
