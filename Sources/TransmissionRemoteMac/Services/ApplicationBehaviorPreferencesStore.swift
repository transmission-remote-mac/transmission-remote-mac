// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Combine
import Foundation

@MainActor
final class ApplicationBehaviorPreferencesStore: ObservableObject {
    nonisolated static let storageKey = "application.behaviorPreferences.v1"
    static let shared = ApplicationBehaviorPreferencesStore(
        userDefaults: ApplicationUserDefaultsFactory.defaultStore
    )

    @Published private(set) var preferences: ApplicationBehaviorPreferences

    private let persistence: StoredPreferencePersistence

    init(
        userDefaults: UserDefaults = .standard,
        storageKey: String = ApplicationBehaviorPreferencesStore.storageKey,
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
            defaults: ApplicationBehaviorPreferences.defaults,
            currentSchemaVersion: ApplicationBehaviorPreferences.currentSchemaVersion
        )
    }

    func save(_ preferences: ApplicationBehaviorPreferences) throws {
        try persistence.save(preferences)
        self.preferences = preferences
    }
}
