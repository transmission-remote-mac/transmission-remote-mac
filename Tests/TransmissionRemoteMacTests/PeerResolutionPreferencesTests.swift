// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation
import XCTest
@testable import TransmissionRemoteMac

@MainActor
final class PeerResolutionPreferencesTests: XCTestCase {
    func testLegacyPreferencesMigrateWithDefaultDatabaseSourceAndKeepCountryChoices() throws {
        let suiteName = "PeerResolutionMigrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            Data(#"{"schemaVersion":1,"resolveHostNames":true,"resolveCountries":true,"showCountryFlags":true}"#.utf8),
            forKey: PeerResolutionPreferencesStore.storageKey
        )

        let migrated = PeerResolutionPreferencesStore(userDefaults: defaults).preferences

        XCTAssertTrue(migrated.resolveHostNames)
        XCTAssertTrue(migrated.resolveCountries)
        XCTAssertTrue(migrated.showCountryFlags)
        XCTAssertEqual(migrated.countryDatabaseSourceURL, "")
        XCTAssertNil(try PeerCountryDownloadSource.validatedCustomURL(migrated.countryDatabaseSourceURL))
    }

    func testMalformedSourceValueDoesNotEraseOtherDecodedPreferences() throws {
        let data = Data(#"{"schemaVersion":2,"resolveCountries":true,"showCountryFlags":true,"countryDatabaseSourceURL":42}"#.utf8)

        let decoded = try JSONDecoder().decode(PeerResolutionPreferences.self, from: data)

        XCTAssertTrue(decoded.resolveCountries)
        XCTAssertTrue(decoded.showCountryFlags)
        XCTAssertEqual(decoded.countryDatabaseSourceURL, "")
    }

    func testCustomDatabaseSourcePersistsWithoutChangingRuntimeResolutionValues() throws {
        let suiteName = "PeerResolutionCustomSourceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var preferences = PeerResolutionPreferences.defaults
        preferences.resolveCountries = true
        preferences.showCountryFlags = true
        let originalEffective = preferences.effective(countryDatabaseAvailable: true)
        preferences.countryDatabaseSourceURL = "https://country.example/current.csv.gz"

        try PeerResolutionPreferencesStore(userDefaults: defaults).save(preferences)

        let reloaded = PeerResolutionPreferencesStore(userDefaults: defaults).preferences
        XCTAssertEqual(reloaded, preferences)
        XCTAssertEqual(reloaded.effective(countryDatabaseAvailable: true), originalEffective)
        XCTAssertEqual(reloaded.effective(countryDatabaseAvailable: false), .defaults)
        XCTAssertEqual(
            try PeerCountryDownloadSource.validatedCustomURL(reloaded.countryDatabaseSourceURL)?.absoluteString,
            "https://country.example/current.csv.gz"
        )
    }

    func testInvalidCustomDatabaseSourceCannotOverwriteSavedPreferences() throws {
        let suiteName = "PeerResolutionInvalidSourceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = PeerResolutionPreferencesStore(userDefaults: defaults)
        let originalData = defaults.data(forKey: PeerResolutionPreferencesStore.storageKey)
        var invalid = PeerResolutionPreferences.defaults
        invalid.countryDatabaseSourceURL = "http://country.example/current.csv"

        XCTAssertThrowsError(try store.save(invalid))
        XCTAssertEqual(store.preferences, .defaults)
        XCTAssertEqual(defaults.data(forKey: PeerResolutionPreferencesStore.storageKey), originalData)
    }

    func testResettingDatabaseSourceRestoresDefaultWithoutEnablingResolution() throws {
        let suiteName = "PeerResolutionResetSourceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = PeerResolutionPreferencesStore(userDefaults: defaults)
        var preferences = PeerResolutionPreferences.defaults
        preferences.countryDatabaseSourceURL = "https://country.example/current.csv"
        try store.save(preferences)
        preferences.countryDatabaseSourceURL = ""

        try store.save(preferences)

        XCTAssertEqual(PeerResolutionPreferencesStore(userDefaults: defaults).preferences, .defaults)
        XCTAssertNil(try PeerCountryDownloadSource.validatedCustomURL(store.preferences.countryDatabaseSourceURL))
    }

    func testDefaultsAreOptInAndCountryFeaturesRequireDatabase() {
        XCTAssertEqual(PeerResolutionPreferences.defaults, PeerResolutionPreferences(
            resolveHostNames: false,
            resolveCountries: false,
            showCountryFlags: false
        ))

        let enabled = PeerResolutionPreferences(
            resolveHostNames: true,
            resolveCountries: true,
            showCountryFlags: true
        )
        XCTAssertEqual(enabled.effective(countryDatabaseAvailable: false), PeerResolutionPreferences(
            resolveHostNames: true,
            resolveCountries: false,
            showCountryFlags: false
        ))
        XCTAssertEqual(enabled.effective(countryDatabaseAvailable: true), enabled)
    }

    func testPreferencesPersistWhileAvailabilityIsAppliedOnlyToRuntimeValues() throws {
        let suiteName = "PeerResolutionPreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let saved = PeerResolutionPreferences(
            resolveHostNames: true,
            resolveCountries: true,
            showCountryFlags: true
        )
        let store = PeerResolutionPreferencesStore(userDefaults: defaults)

        try store.save(saved)
        XCTAssertEqual(
            PeerResolutionPreferencesStore(userDefaults: defaults).preferences,
            saved
        )

        XCTAssertEqual(store.preferences, saved)
        XCTAssertEqual(store.preferences.effective(countryDatabaseAvailable: false), PeerResolutionPreferences(
            resolveHostNames: true,
            resolveCountries: false,
            showCountryFlags: false
        ))
    }

    func testFutureSchemaSurvivesInitializationUntilExplicitSave() throws {
        let suiteName = "PeerResolutionFuturePreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let futureData = Data(#"{"schemaVersion":99,"futureValue":"keep"}"#.utf8)
        defaults.set(futureData, forKey: PeerResolutionPreferencesStore.storageKey)
        let store = PeerResolutionPreferencesStore(userDefaults: defaults)

        XCTAssertEqual(store.preferences, .defaults)
        XCTAssertEqual(defaults.data(forKey: PeerResolutionPreferencesStore.storageKey), futureData)
        try store.save(.defaults)
        XCTAssertNotEqual(defaults.data(forKey: PeerResolutionPreferencesStore.storageKey), futureData)
    }

    func testIsolatedAppStoreNeverUsesProductionCountryDatabasePath() throws {
        let suiteName = "PeerResolutionAppStoreIsolationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let profileStore = ConnectionProfileStore(
            fileURL: directory.appendingPathComponent("profiles.json")
        )

        let store = AppStore(
            profileStore: profileStore,
            userDefaults: defaults,
            downloadCompletionNotifier: PeerResolutionTestNotifier()
        )

        XCTAssertTrue(store.peerCountryDatabaseController.usesEphemeralRepository)
        XCTAssertNotEqual(
            store.peerCountryDatabaseController.storageURL.standardizedFileURL,
            PeerCountryDatabaseRepository.defaultDestinationURL().standardizedFileURL
        )
        XCTAssertTrue(
            store.peerCountryDatabaseController.storageURL.path.hasPrefix(
                FileManager.default.temporaryDirectory.standardizedFileURL.path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: store.peerCountryDatabaseController.storageURL.path
            )
        )
    }

    func testDatabaseLoadingStateDoesNotErasePersistedCountryChoices() async throws {
        let suiteName = "PeerResolutionLoadingPreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let profileStore = ConnectionProfileStore(
            fileURL: directory.appendingPathComponent("profiles.json")
        )
        let preferencesStore = PeerResolutionPreferencesStore(userDefaults: defaults)
        let saved = PeerResolutionPreferences(
            resolveHostNames: true,
            resolveCountries: true,
            showCountryFlags: true
        )
        try preferencesStore.save(saved)
        let databaseController = PeerCountryDatabaseController(
            repository: .ephemeral()
        )
        XCTAssertEqual(databaseController.status, .loading)

        let appStore = AppStore(
            profileStore: profileStore,
            userDefaults: defaults,
            downloadCompletionNotifier: PeerResolutionTestNotifier(),
            peerResolutionPreferencesStore: preferencesStore,
            peerCountryDatabaseController: databaseController
        )

        XCTAssertEqual(
            appStore.peerResolutionPreferences,
            saved.effective(countryDatabaseAvailable: false)
        )
        XCTAssertEqual(preferencesStore.preferences, saved)
        let becameUnavailable = await waitUntil {
            databaseController.status == .unavailable
        }
        XCTAssertTrue(becameUnavailable)
        for _ in 0 ..< 10 {
            await Task.yield()
        }
        XCTAssertEqual(
            appStore.peerResolutionPreferences,
            saved.effective(countryDatabaseAvailable: false)
        )
        XCTAssertEqual(preferencesStore.preferences, saved)
        XCTAssertEqual(
            PeerResolutionPreferencesStore(userDefaults: defaults).preferences,
            saved
        )
    }

    func testRemovingCountryDatabaseDisablesRuntimeWithoutErasingSavedIntent() async throws {
        let suiteName = "PeerResolutionRemovalPreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let profileStore = ConnectionProfileStore(
            fileURL: directory.appendingPathComponent("profiles.json")
        )
        let preferencesStore = PeerResolutionPreferencesStore(userDefaults: defaults)
        let saved = PeerResolutionPreferences(
            resolveHostNames: true,
            resolveCountries: true,
            showCountryFlags: true
        )
        try preferencesStore.save(saved)
        let databaseController = PeerCountryDatabaseController(
            repository: .ephemeral()
        )
        let sourceURL = directory.appendingPathComponent("dbip-country-lite-2026-09.csv")
        try Data(#""1.0.0.0","1.0.0.255","AU""#.utf8).write(to: sourceURL)
        _ = try await databaseController.importDatabase(from: sourceURL)
        let appStore = AppStore(
            profileStore: profileStore,
            userDefaults: defaults,
            downloadCompletionNotifier: PeerResolutionTestNotifier(),
            peerResolutionPreferencesStore: preferencesStore,
            peerCountryDatabaseController: databaseController
        )
        XCTAssertEqual(appStore.peerResolutionPreferences, saved)

        try await databaseController.removeDatabase()
        let runtimeDisabled = await waitUntil {
            appStore.peerResolutionPreferences
                == saved.effective(countryDatabaseAvailable: false)
        }

        XCTAssertTrue(runtimeDisabled)
        XCTAssertEqual(preferencesStore.preferences, saved)
        XCTAssertEqual(
            PeerResolutionPreferencesStore(userDefaults: defaults).preferences,
            saved
        )
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0 ..< 100 {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }
}

private struct PeerResolutionTestNotifier: DownloadCompletionNotifying {
    func notifyDownloadCompleted(torrentName: String) {}
}
