// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation
import XCTest
@testable import TransmissionRemoteMac

@MainActor
final class ApplicationBehaviorPreferencesStoreTests: XCTestCase {
    func testMissingStoragePersistsSafeDefaults() throws {
        let defaults = makeUserDefaults()
        let store = ApplicationBehaviorPreferencesStore(userDefaults: defaults)

        XCTAssertEqual(store.preferences, .defaults)
        let data = try XCTUnwrap(
            defaults.data(forKey: ApplicationBehaviorPreferencesStore.storageKey)
        )
        XCTAssertEqual(
            try JSONDecoder().decode(ApplicationBehaviorPreferences.self, from: data),
            .defaults
        )
    }

    func testSavePublishesAndRoundTripsOneCanonicalPayload() throws {
        let defaults = makeUserDefaults()
        let store = ApplicationBehaviorPreferencesStore(userDefaults: defaults)
        let preferences = ApplicationBehaviorPreferences(
            speedAveraging: SpeedAveragingPolicy(
                isEnabled: true,
                sampleLimit: 8,
                windowSeconds: 45
            ),
            completionNotificationsEnabled: false,
            promptsForDownloadOptions: false,
            addDefaults: AddTorrentDefaults(
                startIntent: .paused,
                priority: .high,
                unwantedFiles: .allUnwantedWhenFileListKnown,
                peerLimit: 80
            )
        )

        try store.save(preferences)

        XCTAssertEqual(store.preferences, preferences)
        XCTAssertEqual(
            ApplicationBehaviorPreferencesStore(userDefaults: defaults).preferences,
            preferences
        )
    }

    func testSchemaZeroStorageMigratesToCurrentCanonicalSchema() throws {
        let defaults = makeUserDefaults()
        defaults.set(
            Data(
                """
                {
                    "averageSpeeds": true,
                    "speedAverageSamples": 5,
                    "speedAverageWindowSeconds": 30,
                    "notifyOnCompletion": false,
                    "startPaused": true,
                    "addPriority": 1,
                    "markAllFilesUnwanted": true,
                    "addPeerLimit": 75
                }
                """.utf8
            ),
            forKey: ApplicationBehaviorPreferencesStore.storageKey
        )

        let store = ApplicationBehaviorPreferencesStore(userDefaults: defaults)
        let canonicalData = try XCTUnwrap(
            defaults.data(forKey: ApplicationBehaviorPreferencesStore.storageKey)
        )
        let canonicalObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: canonicalData) as? [String: Any]
        )

        XCTAssertTrue(store.preferences.speedAveraging.isEnabled)
        XCTAssertFalse(store.preferences.completionNotificationsEnabled)
        XCTAssertEqual(store.preferences.addDefaults.peerLimit, 75)
        XCTAssertEqual(canonicalObject["schemaVersion"] as? Int, 2)
        XCTAssertNil(canonicalObject["averageSpeeds"])
    }

    func testMalformedStorageIsReplacedWithSafeDefaults() throws {
        let defaults = makeUserDefaults()
        defaults.set(Data("not-json".utf8), forKey: ApplicationBehaviorPreferencesStore.storageKey)

        let store = ApplicationBehaviorPreferencesStore(userDefaults: defaults)

        XCTAssertEqual(store.preferences, .defaults)
        XCTAssertNoThrow(try JSONDecoder().decode(
            ApplicationBehaviorPreferences.self,
            from: XCTUnwrap(defaults.data(
                forKey: ApplicationBehaviorPreferencesStore.storageKey
            ))
        ))
    }

    func testFutureSchemaRemainsUntouchedUntilAnExplicitSave() throws {
        let defaults = makeUserDefaults()
        let futureData = Data(#"{"schemaVersion":99,"futureValue":"keep"}"#.utf8)
        defaults.set(futureData, forKey: ApplicationBehaviorPreferencesStore.storageKey)

        let store = ApplicationBehaviorPreferencesStore(userDefaults: defaults)

        XCTAssertEqual(store.preferences, .defaults)
        XCTAssertEqual(defaults.data(forKey: ApplicationBehaviorPreferencesStore.storageKey), futureData)
        try store.save(.defaults)
        XCTAssertNotEqual(defaults.data(forKey: ApplicationBehaviorPreferencesStore.storageKey), futureData)
    }

    private func makeUserDefaults() -> UserDefaults {
        let suiteName = "ApplicationBehaviorPreferencesStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }
}
