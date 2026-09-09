// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Combine
import Foundation

@MainActor
final class IntakeAutomationPreferencesStore: ObservableObject {
    nonisolated static let storageKey = "application.intakeAutomationPreferences.v1"
    static let shared = IntakeAutomationPreferencesStore(
        userDefaults: ApplicationUserDefaultsFactory.defaultStore
    )

    @Published private(set) var preferences: IntakeAutomationPreferences

    private let persistence: StoredPreferencePersistence

    init(
        userDefaults: UserDefaults = .standard,
        storageKey: String = IntakeAutomationPreferencesStore.storageKey,
        encoder: JSONEncoder = JSONEncoder(),
        decoder: JSONDecoder = JSONDecoder()
    ) {
        persistence = StoredPreferencePersistence(
            userDefaults: userDefaults,
            storageKey: storageKey,
            encoder: encoder,
            decoder: decoder
        )
        preferences = persistence.load(
            defaults: IntakeAutomationPreferences.defaults,
            currentSchemaVersion: IntakeAutomationPreferences.currentSchemaVersion
        )
    }

    func save(_ preferences: IntakeAutomationPreferences) throws {
        try persistence.save(preferences)
        self.preferences = preferences
    }
}
