// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation
import XCTest
@testable import TransmissionRemoteMac

@MainActor
final class ApplicationInteractionPreferencesStoreTests: XCTestCase {
    func testMissingPreferencesPersistSafeDefaults() throws {
        try withTemporaryDefaults { defaults, storageKey in
            let store = ApplicationInteractionPreferencesStore(
                userDefaults: defaults,
                storageKey: storageKey
            )

            XCTAssertEqual(store.preferences, .defaults)
            let data = try XCTUnwrap(defaults.data(forKey: storageKey))
            XCTAssertEqual(
                ApplicationInteractionPreferencesCodec().decodeOrDefaults(data).preferences,
                .defaults
            )
            XCTAssertEqual(
                store.shortcut(for: .cancelConnection)?.stableCombinationID,
                "command+shift+k"
            )
        }
    }

    func testValidPreferencesPersistAndReloadWithValidatedShortcuts() throws {
        try withTemporaryDefaults { defaults, storageKey in
            let preferences = ApplicationInteractionPreferences(
                dateDisplay: DateDisplayPreferences(mode: .relative),
                shortcutOverrides: [
                    CommandShortcutPreference(
                        commandID: .refresh,
                        keyEquivalent: "n",
                        modifiers: ["command"]
                    )
                ]
            )
            let store = ApplicationInteractionPreferencesStore(
                userDefaults: defaults,
                storageKey: storageKey
            )

            try store.save(preferences)
            let reloaded = ApplicationInteractionPreferencesStore(
                userDefaults: defaults,
                storageKey: storageKey
            )

            XCTAssertEqual(reloaded.preferences, preferences)
            XCTAssertEqual(reloaded.shortcut(for: .refresh)?.stableCombinationID, "command+n")
            XCTAssertEqual(reloaded.shortcut(for: .start)?.stableCombinationID, "command+return")
        }
    }

    func testOldCatalogOverrideWinsOverNewDefaultWithoutResettingDateDisplay() throws {
        try withTemporaryDefaults { defaults, storageKey in
            let oldOverride = CommandShortcutPreference(
                commandID: .refresh,
                keyEquivalent: "g",
                modifiers: ["option"]
            )
            let storedPreferences = ApplicationInteractionPreferences(
                dateDisplay: DateDisplayPreferences(mode: .relative),
                shortcutOverrides: [oldOverride]
            )
            let codec = ApplicationInteractionPreferencesCodec()
            defaults.set(try codec.encode(storedPreferences), forKey: storageKey)

            let store = ApplicationInteractionPreferencesStore(
                userDefaults: defaults,
                storageKey: storageKey
            )

            XCTAssertEqual(store.preferences.dateDisplay.mode, .relative)
            XCTAssertEqual(store.shortcut(for: .refresh)?.stableCombinationID, "option+g")
            XCTAssertNil(store.shortcut(for: .showGeneralDetails))
            XCTAssertEqual(store.shortcut(for: .showFilesDetails)?.stableCombinationID, "option+f")
            XCTAssertEqual(store.preferences.shortcutOverrides.first, oldOverride)
            XCTAssertEqual(
                store.preferences.shortcutOverrides.filter { $0.keyEquivalent == nil }.map(\.commandID),
                [NativeCommandID.showGeneralDetails.rawValue]
            )

            let persistedData = try XCTUnwrap(defaults.data(forKey: storageKey))
            let persistedPreferences = codec.decodeOrDefaults(persistedData).preferences
            XCTAssertEqual(persistedPreferences, store.preferences)

            let reloaded = ApplicationInteractionPreferencesStore(
                userDefaults: defaults,
                storageKey: storageKey
            )
            XCTAssertEqual(reloaded.preferences, store.preferences)
            XCTAssertEqual(reloaded.shortcut(for: .refresh)?.stableCombinationID, "option+g")
            XCTAssertNil(reloaded.shortcut(for: .showGeneralDetails))
        }
    }

    func testInvalidPersistedOrNewShortcutsFailClosedToDefaults() throws {
        try withTemporaryDefaults { defaults, storageKey in
            let invalid = ApplicationInteractionPreferences(
                dateDisplay: DateDisplayPreferences(mode: .relative),
                shortcutOverrides: [
                    CommandShortcutPreference(
                        commandID: .refresh,
                        keyEquivalent: "i",
                        modifiers: ["command"]
                    )
                ]
            )
            let codec = ApplicationInteractionPreferencesCodec()
            defaults.set(try codec.encode(invalid), forKey: storageKey)

            let store = ApplicationInteractionPreferencesStore(
                userDefaults: defaults,
                storageKey: storageKey
            )
            XCTAssertEqual(store.preferences, .defaults)

            XCTAssertThrowsError(try store.save(invalid)) { error in
                guard case ApplicationInteractionPreferencesStoreError.invalidShortcuts = error else {
                    return XCTFail("Expected invalid shortcut error, received \(error).")
                }
            }
            XCTAssertEqual(store.preferences, .defaults)
        }
    }

    func testFutureSchemaRemainsUntouchedUntilAnExplicitSave() throws {
        try withTemporaryDefaults { defaults, storageKey in
            let futureData = Data(#"{"version":99,"futureValue":"keep"}"#.utf8)
            defaults.set(futureData, forKey: storageKey)

            let store = ApplicationInteractionPreferencesStore(
                userDefaults: defaults,
                storageKey: storageKey
            )

            XCTAssertEqual(store.preferences, .defaults)
            XCTAssertEqual(defaults.data(forKey: storageKey), futureData)
            try store.save(.defaults)
            XCTAssertNotEqual(defaults.data(forKey: storageKey), futureData)
        }
    }

    private func withTemporaryDefaults(
        _ body: (UserDefaults, String) throws -> Void
    ) throws {
        let suiteName = "ApplicationInteractionPreferencesStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let storageKey = "interaction-preferences"
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(defaults, storageKey)
    }
}
