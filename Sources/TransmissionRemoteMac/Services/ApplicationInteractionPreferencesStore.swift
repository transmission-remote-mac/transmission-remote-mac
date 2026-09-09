// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Combine
import Foundation

enum ApplicationInteractionPreferencesStoreError: Equatable, Error {
    case invalidShortcuts([CommandShortcutValidationIssue])
}

extension ApplicationInteractionPreferencesStoreError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .invalidShortcuts(issues):
            issues.first?.message ?? "Shortcut preferences are invalid."
        }
    }
}

@MainActor
final class ApplicationInteractionPreferencesStore: ObservableObject {
    nonisolated static let storageKey = "application.interactionPreferences.v2"
    static let shared = ApplicationInteractionPreferencesStore(
        userDefaults: ApplicationUserDefaultsFactory.defaultStore
    )

    @Published private(set) var preferences: ApplicationInteractionPreferences
    let dateDisplayFormattingService: DateDisplayFormattingService

    private(set) var shortcutBindings: [NativeCommandShortcutBinding]
    private let userDefaults: UserDefaults
    private let storageKey: String
    private let codec: ApplicationInteractionPreferencesCodec
    private let shortcutValidationService: CommandShortcutValidationService
    private var preservesUnsupportedFutureStorage: Bool

    init(
        userDefaults: UserDefaults = .standard,
        storageKey: String = ApplicationInteractionPreferencesStore.storageKey,
        codec: ApplicationInteractionPreferencesCodec = ApplicationInteractionPreferencesCodec(),
        shortcutValidationService: CommandShortcutValidationService = CommandShortcutValidationService(),
        dateDisplayFormattingService: DateDisplayFormattingService = DateDisplayFormattingService()
    ) {
        self.userDefaults = userDefaults
        self.storageKey = storageKey
        self.codec = codec
        self.shortcutValidationService = shortcutValidationService
        self.dateDisplayFormattingService = dateDisplayFormattingService

        let storedData = userDefaults.data(forKey: storageKey)
        preservesUnsupportedFutureStorage = StoredPreferenceSchema.isFutureVersion(
            in: storedData,
            key: "version",
            currentVersion: ApplicationInteractionPreferences.currentSchemaVersion
        )
        let decodeResult = codec.decodeOrDefaults(storedData)
        let decodedPlan = shortcutValidationService.makeImportPlan(
            from: decodeResult.preferences.shortcutOverrides
        )
        if preservesUnsupportedFutureStorage {
            preferences = .defaults
            shortcutBindings = shortcutValidationService.makeImportPlan(from: []).proposedBindings
        } else if decodeResult.usedDefaults {
            preferences = .defaults
            shortcutBindings = shortcutValidationService.makeImportPlan(from: []).proposedBindings
            persistDefaults()
        } else if let validatedBindings = decodedPlan.validatedBindings {
            preferences = decodeResult.preferences
            shortcutBindings = validatedBindings
        } else if let upgrade = shortcutValidationService.makeConflictSafeUpgrade(
            from: decodeResult.preferences.shortcutOverrides,
            newCommandIDs: NativeCommandCatalog.keyboardNavigationCommandIDs
        ) {
            let upgradedPreferences = ApplicationInteractionPreferences(
                dateDisplay: decodeResult.preferences.dateDisplay,
                shortcutOverrides: upgrade.shortcutOverrides
            )
            preferences = upgradedPreferences
            shortcutBindings = upgrade.importPlan.proposedBindings
            persist(upgradedPreferences)
        } else {
            preferences = .defaults
            shortcutBindings = shortcutValidationService.makeImportPlan(from: []).proposedBindings
            persistDefaults()
        }
    }

    func save(_ preferences: ApplicationInteractionPreferences) throws {
        let plan = shortcutValidationService.makeImportPlan(from: preferences.shortcutOverrides)
        guard let validatedBindings = plan.validatedBindings else {
            throw ApplicationInteractionPreferencesStoreError.invalidShortcuts(plan.issues)
        }

        let data = try codec.encode(preferences)
        userDefaults.set(data, forKey: storageKey)
        preservesUnsupportedFutureStorage = false
        shortcutBindings = validatedBindings
        self.preferences = preferences
    }

    func shortcut(for commandID: NativeCommandID) -> NativeCommandShortcut? {
        shortcutBindings.first { $0.commandID == commandID }?.shortcut
    }

    private func persistDefaults() {
        persist(.defaults)
    }

    private func persist(_ preferences: ApplicationInteractionPreferences) {
        guard let data = try? codec.encode(preferences) else { return }
        userDefaults.set(data, forKey: storageKey)
    }
}
