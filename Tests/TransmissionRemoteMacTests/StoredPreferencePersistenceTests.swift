// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation
import XCTest
@testable import TransmissionRemoteMac

@MainActor
final class StoredPreferencePersistenceTests: XCTestCase {
    func testAllTypedStoresKeepCurrentCanonicalBytesWithoutInitializationWrites() throws {
        for kind in PreferenceStoreKind.allCases {
            let defaults = makeUserDefaults()
            let canonical = try kind.canonicalData()
            defaults.set(canonical, forKey: kind.storageKey)
            defaults.writeCount = 0

            XCTAssertTrue(kind.open(defaults).hasDefaults())
            XCTAssertTrue(kind.open(defaults).hasDefaults())

            XCTAssertEqual(defaults.writeCount, 0)
            XCTAssertEqual(defaults.data(forKey: kind.storageKey), canonical)
        }
    }

    func testAllTypedStoresRepairMissingCorruptAndSchemaZeroStorageOnlyOnce() throws {
        for kind in PreferenceStoreKind.allCases {
            let payloads: [Data?] = [
                nil,
                Data("not-json".utf8),
                Data(#"{"schemaVersion":0}"#.utf8),
                Data(#"{"schemaVersion":true}"#.utf8),
                Data(#"{"schemaVersion":1.5}"#.utf8)
            ]
            for payload in payloads {
                let defaults = makeUserDefaults()
                if let payload { defaults.set(payload, forKey: kind.storageKey) }
                defaults.writeCount = 0

                XCTAssertTrue(kind.open(defaults).hasDefaults())
                XCTAssertEqual(defaults.writeCount, 1)
                let repaired = try XCTUnwrap(defaults.data(forKey: kind.storageKey))
                XCTAssertTrue(kind.open(defaults).hasDefaults())
                XCTAssertEqual(defaults.writeCount, 1)
                XCTAssertEqual(defaults.data(forKey: kind.storageKey), repaired)
            }
        }
    }

    func testAllTypedStoresNormalizeNumericBooleanFieldsInsteadOfTreatingThemAsEqual() throws {
        for kind in PreferenceStoreKind.allCases {
            let defaults = makeUserDefaults()
            var object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: kind.canonicalData()) as? [String: Any]
            )
            switch kind {
            case .behavior:
                object["completionNotificationsEnabled"] = 1
            case .intake:
                object["clipboardIntake"] = ["isEnabled": 0]
            case .peer:
                object["resolveHostNames"] = 0
            }
            let invalid = try JSONSerialization.data(withJSONObject: object)
            defaults.set(invalid, forKey: kind.storageKey)
            defaults.writeCount = 0

            XCTAssertTrue(kind.open(defaults).hasDefaults())
            XCTAssertEqual(defaults.writeCount, 1)
            XCTAssertNotEqual(defaults.data(forKey: kind.storageKey), invalid)
            XCTAssertTrue(kind.open(defaults).hasDefaults())
            XCTAssertEqual(defaults.writeCount, 1)
        }
    }

    func testFutureSchemaBytesSurviveRepeatedInitializationUntilExplicitSave() throws {
        for kind in PreferenceStoreKind.allCases {
            let defaults = makeUserDefaults()
            let future = Data("{ \"schemaVersion\": 99, \"unknown\": [true, 1, null] }\n".utf8)
            defaults.set(future, forKey: kind.storageKey)
            defaults.writeCount = 0
            let store = kind.open(defaults)
            XCTAssertTrue(store.hasDefaults())
            XCTAssertTrue(kind.open(defaults).hasDefaults())
            XCTAssertEqual(defaults.writeCount, 0)
            XCTAssertEqual(defaults.data(forKey: kind.storageKey), future)

            try store.saveChanged()

            XCTAssertTrue(store.hasChanged())
            XCTAssertTrue(kind.open(defaults).hasChanged())
            XCTAssertEqual(defaults.writeCount, 1)
            XCTAssertNotEqual(defaults.data(forKey: kind.storageKey), future)
        }
    }

    func testCurrentSchemaBoundsAreCanonicalizedOnceWithoutLosingValidFields() throws {
        let defaults = makeUserDefaults()
        defaults.set(Data("""
            {
                "schemaVersion": 1,
                "speedAveraging": {"isEnabled": true, "sampleLimit": 999, "windowSeconds": 0},
                "completionNotificationsEnabled": false,
                "addDefaults": {
                    "startIntent": "paused", "priority": 1,
                    "unwantedFiles": "daemonDefault", "peerLimit": 999999
                }
            }
            """.utf8), forKey: ApplicationBehaviorPreferencesStore.storageKey)
        defaults.set(Data("""
            {
                "schemaVersion": 1,
                "clipboardIntake": {"isEnabled": true},
                "sourceTorrentDeletion": "afterSuccessfulNonDuplicateAdd",
                "updateChecks": {"automaticChecksEnabled": true, "automaticCadenceHours": 9999}
            }
            """.utf8), forKey: IntakeAutomationPreferencesStore.storageKey)
        defaults.writeCount = 0

        let behavior = ApplicationBehaviorPreferencesStore(userDefaults: defaults).preferences
        XCTAssertTrue(behavior.speedAveraging.isEnabled)
        XCTAssertEqual(behavior.speedAveraging.sampleLimit, 120)
        XCTAssertEqual(behavior.speedAveraging.windowSeconds, 1)
        XCTAssertEqual(behavior.addDefaults.startIntent, .paused)
        XCTAssertNil(behavior.addDefaults.peerLimit)
        let intake = IntakeAutomationPreferencesStore(userDefaults: defaults).preferences
        XCTAssertTrue(intake.clipboardIntake.isEnabled)
        XCTAssertEqual(intake.sourceTorrentDeletion, .afterSuccessfulNonDuplicateAdd)
        XCTAssertEqual(intake.updateChecks.automaticCadenceHours, 720)
        XCTAssertEqual(defaults.writeCount, 2)
        XCTAssertEqual(ApplicationBehaviorPreferencesStore(userDefaults: defaults).preferences, behavior)
        XCTAssertEqual(IntakeAutomationPreferencesStore(userDefaults: defaults).preferences, intake)
        XCTAssertEqual(defaults.writeCount, 2)
    }

    func testTypedStoresPublishExplicitSavesOnlyAfterEncodingSucceeds() throws {
        for kind in PreferenceStoreKind.allCases {
            let defaults = makeUserDefaults()
            let encoder = ControlledPreferenceEncoder()
            let store = kind.open(defaults, encoder: encoder)
            let original = defaults.data(forKey: kind.storageKey)
            defaults.writeCount = 0
            encoder.shouldFail = true

            XCTAssertThrowsError(try store.saveChanged())
            XCTAssertTrue(store.hasDefaults())
            XCTAssertEqual(defaults.writeCount, 0)
            XCTAssertEqual(defaults.data(forKey: kind.storageKey), original)

            encoder.shouldFail = false
            try store.saveChanged()
            XCTAssertTrue(store.hasChanged())
            XCTAssertTrue(kind.open(defaults).hasChanged())
            XCTAssertEqual(defaults.writeCount, 1)
        }
    }

    func testSchemaZeroMigrationKeepsBehaviorAndPeerChoicesButIntakeDefaults() throws {
        let defaults = makeUserDefaults()
        defaults.set(Data(#"{"startPaused":true,"notifyOnCompletion":false}"#.utf8),
                     forKey: ApplicationBehaviorPreferencesStore.storageKey)
        defaults.set(Data(#"{"resolveHostNames":true}"#.utf8),
                     forKey: PeerResolutionPreferencesStore.storageKey)
        defaults.set(Data(#"{"sourceTorrentDeletion":"afterSuccessfulNonDuplicateAdd"}"#.utf8),
                     forKey: IntakeAutomationPreferencesStore.storageKey)
        defaults.writeCount = 0

        let behavior = ApplicationBehaviorPreferencesStore(userDefaults: defaults).preferences
        XCTAssertEqual(behavior.addDefaults.startIntent, .paused)
        XCTAssertFalse(behavior.completionNotificationsEnabled)
        XCTAssertTrue(PeerResolutionPreferencesStore(userDefaults: defaults).preferences.resolveHostNames)
        XCTAssertEqual(IntakeAutomationPreferencesStore(userDefaults: defaults).preferences, .defaults)
        XCTAssertEqual(defaults.writeCount, 3)
        for kind in PreferenceStoreKind.allCases { _ = kind.open(defaults) }
        XCTAssertEqual(defaults.writeCount, 3)
    }

    private func makeUserDefaults() -> WriteCountingPreferenceDefaults {
        let suiteName = "StoredPreferencePersistenceTests.\(UUID().uuidString)"
        let defaults = WriteCountingPreferenceDefaults(suiteName: suiteName)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }
}

private final class WriteCountingPreferenceDefaults: UserDefaults {
    var writeCount = 0

    override func set(_ value: Any?, forKey defaultName: String) {
        writeCount += 1
        super.set(value, forKey: defaultName)
    }
}

private final class ControlledPreferenceEncoder: JSONEncoder, @unchecked Sendable {
    var shouldFail = false

    override func encode<T: Encodable>(_ value: T) throws -> Data {
        if shouldFail { throw EncodingError.invalidValue(value, .init(codingPath: [], debugDescription: "fixture")) }
        return try super.encode(value)
    }
}

@MainActor
private struct PreferenceStoreActions {
    let hasDefaults: () -> Bool
    let hasChanged: () -> Bool
    let saveChanged: () throws -> Void
}

@MainActor
private enum PreferenceStoreKind: CaseIterable {
    case behavior, intake, peer

    var storageKey: String {
        switch self {
        case .behavior: ApplicationBehaviorPreferencesStore.storageKey
        case .intake: IntakeAutomationPreferencesStore.storageKey
        case .peer: PeerResolutionPreferencesStore.storageKey
        }
    }

    func canonicalData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        switch self {
        case .behavior: return try encoder.encode(ApplicationBehaviorPreferences.defaults)
        case .intake: return try encoder.encode(IntakeAutomationPreferences.defaults)
        case .peer: return try encoder.encode(PeerResolutionPreferences.defaults)
        }
    }

    func open(_ defaults: UserDefaults, encoder: JSONEncoder = JSONEncoder()) -> PreferenceStoreActions {
        switch self {
        case .behavior:
            let store = ApplicationBehaviorPreferencesStore(userDefaults: defaults, encoder: encoder)
            var changed = ApplicationBehaviorPreferences.defaults
            changed.completionNotificationsEnabled = false
            return PreferenceStoreActions(
                hasDefaults: { store.preferences == .defaults },
                hasChanged: { store.preferences == changed },
                saveChanged: { try store.save(changed) }
            )
        case .intake:
            let store = IntakeAutomationPreferencesStore(userDefaults: defaults, encoder: encoder)
            var changed = IntakeAutomationPreferences.defaults
            changed.sourceTorrentDeletion = .afterSuccessfulNonDuplicateAdd
            return PreferenceStoreActions(
                hasDefaults: { store.preferences == .defaults },
                hasChanged: { store.preferences == changed },
                saveChanged: { try store.save(changed) }
            )
        case .peer:
            let store = PeerResolutionPreferencesStore(userDefaults: defaults, encoder: encoder)
            var changed = PeerResolutionPreferences.defaults
            changed.resolveHostNames = true
            return PreferenceStoreActions(
                hasDefaults: { store.preferences == .defaults },
                hasChanged: { store.preferences == changed },
                saveChanged: { try store.save(changed) }
            )
        }
    }
}
