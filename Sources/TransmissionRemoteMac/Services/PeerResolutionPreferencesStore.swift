// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Combine
import Foundation

@MainActor
final class PeerResolutionPreferencesStore: ObservableObject {
    nonisolated static let storageKey = "application.peerResolutionPreferences.v1"
    static let shared = PeerResolutionPreferencesStore(
        userDefaults: ApplicationUserDefaultsFactory.defaultStore
    )

    @Published private(set) var preferences: PeerResolutionPreferences

    private let persistence: StoredPreferencePersistence

    init(
        userDefaults: UserDefaults = .standard,
        storageKey: String = PeerResolutionPreferencesStore.storageKey,
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
            defaults: PeerResolutionPreferences.defaults,
            currentSchemaVersion: PeerResolutionPreferences.currentSchemaVersion
        )
    }

    func save(_ preferences: PeerResolutionPreferences) throws {
        _ = try PeerCountryDownloadSource.validatedCustomURL(preferences.countryDatabaseSourceURL)
        try persistence.save(preferences)
        self.preferences = preferences
    }
}
