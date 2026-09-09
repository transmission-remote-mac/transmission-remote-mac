// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation
import XCTest
@testable import TransmissionRemoteMac

@MainActor
final class IntakeAutomationPreferencesStoreTests: XCTestCase {
    func testMissingAndMalformedStorageCanonicaliseToSafeDefaults() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        defaults.set(Data("not-json".utf8), forKey: IntakeAutomationPreferencesStore.storageKey)

        let store = IntakeAutomationPreferencesStore(userDefaults: defaults)

        XCTAssertEqual(store.preferences, .defaults)
        XCTAssertEqual(
            try JSONDecoder().decode(
                IntakeAutomationPreferences.self,
                from: XCTUnwrap(
                    defaults.data(forKey: IntakeAutomationPreferencesStore.storageKey)
                )
            ),
            .defaults
        )
    }

    func testSavePublishesAndPersistsOnlyThePreferencePayload() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let store = IntakeAutomationPreferencesStore(userDefaults: defaults)
        let preferences = IntakeAutomationPreferences(
            clipboardIntake: ClipboardTorrentIntakePolicy(isEnabled: true),
            sourceTorrentDeletion: .afterSuccessfulNonDuplicateAdd,
            updateChecks: UpdateCheckPolicy(
                automaticChecksEnabled: true,
                automaticCadenceHours: 48
            )
        )

        try store.save(preferences)

        XCTAssertEqual(store.preferences, preferences)
        XCTAssertEqual(
            try JSONDecoder().decode(
                IntakeAutomationPreferences.self,
                from: XCTUnwrap(
                    defaults.data(forKey: IntakeAutomationPreferencesStore.storageKey)
                )
            ),
            preferences
        )
    }

    func testSourceDeletionChoiceSurvivesStoreRecreation() throws {
        let suiteName = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = IntakeAutomationPreferences(
            clipboardIntake: .defaults,
            sourceTorrentDeletion: .afterSuccessfulNonDuplicateAdd,
            updateChecks: .defaults
        )

        try IntakeAutomationPreferencesStore(userDefaults: defaults).save(preferences)
        let reloadedStore = IntakeAutomationPreferencesStore(userDefaults: defaults)

        XCTAssertEqual(reloadedStore.preferences, preferences)
        XCTAssertEqual(
            reloadedStore.preferences.sourceTorrentDeletion,
            .afterSuccessfulNonDuplicateAdd
        )
    }

    func testFutureSchemaRemainsUntouchedUntilAnExplicitSave() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let futureData = Data(#"{"schemaVersion":99,"futureValue":"keep"}"#.utf8)
        defaults.set(futureData, forKey: IntakeAutomationPreferencesStore.storageKey)

        let store = IntakeAutomationPreferencesStore(userDefaults: defaults)

        XCTAssertEqual(store.preferences, .defaults)
        XCTAssertEqual(defaults.data(forKey: IntakeAutomationPreferencesStore.storageKey), futureData)
        try store.save(.defaults)
        XCTAssertNotEqual(defaults.data(forKey: IntakeAutomationPreferencesStore.storageKey), futureData)
    }
}
