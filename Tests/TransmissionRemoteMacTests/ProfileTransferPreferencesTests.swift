// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation
import XCTest
@testable import TransmissionRemoteMac

final class ProfileTransferPreferencesTests: XCTestCase {
    func testDefaultsMatchExistingFiniteSessionPresetsAndContainNoAuthenticationSecrets() {
        let preferences = ProfileTransferPreferences.defaults

        XCTAssertEqual(
            preferences.downloadSpeedPresetsKBps,
            [50, 100, 250, 500, 1_000, 2_500]
        )
        XCTAssertEqual(preferences.uploadSpeedPresetsKBps, [10, 25, 50, 100, 250, 500])
        XCTAssertEqual(preferences.destinationHistoryLimit, 50)
        XCTAssertEqual(preferences.addDestinationRules, .empty)
        XCTAssertFalse(ProfileTransferPreferences.containsAuthenticationSecrets)
    }

    func testSpeedPresetsAreBoundedDeduplicatedSortedAndCountLimited() {
        let candidates = [
            999_999,
            0,
            -1,
            1_000_000,
            3,
            2,
            1,
            3
        ] + Array(4 ... 30).reversed()

        let preferences = ProfileTransferPreferences(
            downloadSpeedPresetsKBps: candidates,
            uploadSpeedPresetsKBps: [500, 25, 25, 1, 999_999]
        )

        XCTAssertEqual(preferences.downloadSpeedPresetsKBps, Array(1 ... 20))
        XCTAssertEqual(preferences.uploadSpeedPresetsKBps, [1, 25, 500, 999_999])
    }

    func testSettingSpeedPresetsNormalizesTheSelectedDirectionOnly() {
        var preferences = ProfileTransferPreferences()

        preferences.setSpeedPresets([100, 50, 100, 0], for: .download)

        XCTAssertEqual(preferences.downloadSpeedPresetsKBps, [50, 100])
        XCTAssertEqual(preferences.speedPresetsKBps(for: .download), [50, 100])
        XCTAssertEqual(
            preferences.uploadSpeedPresetsKBps,
            ProfileTransferPreferences.defaultUploadSpeedPresetsKBps
        )
    }

    func testHistoryInitializationPreservesValidRemotePathsAndMostRecentOrdering() {
        let preserved = "/srv//Anime/../Season 1/épisode #1/"
        let trailingSpace = "/srv/downloads/keep "
        let preferences = ProfileTransferPreferences(
            destinationHistoryLimit: 3,
            addDestinationHistory: [preserved, "relative", trailingSpace, preserved, "/fourth"],
            moveDestinationHistory: ["/move/a", "/move/b"]
        )

        XCTAssertEqual(preferences.addDestinationHistory, [preserved, trailingSpace, "/fourth"])
        XCTAssertEqual(preferences.moveDestinationHistory, ["/move/a", "/move/b"])
    }

    func testHistoryRecordRemoveAndClearOperationsArePureAndBounded() throws {
        var preferences = ProfileTransferPreferences(
            destinationHistoryLimit: 3,
            addDestinationHistory: ["/a", "/b", "/c"],
            moveDestinationHistory: ["/move/a", "/move/b"]
        )

        XCTAssertTrue(try preferences.recordDestination("/b", for: .add))
        XCTAssertEqual(preferences.addDestinationHistory, ["/b", "/a", "/c"])
        XCTAssertTrue(try preferences.recordDestination("/d", for: .add))
        XCTAssertEqual(preferences.addDestinationHistory, ["/d", "/b", "/a"])
        XCTAssertFalse(preferences.removeDestination("/missing", from: .add))
        XCTAssertTrue(preferences.removeDestination("/b", from: .add))
        XCTAssertEqual(preferences.addDestinationHistory, ["/d", "/a"])

        preferences.clearDestinations(for: .move)
        XCTAssertTrue(preferences.moveDestinationHistory.isEmpty)
        XCTAssertEqual(preferences.addDestinationHistory, ["/d", "/a"])

        preferences.clearAllDestinations()
        XCTAssertTrue(preferences.addDestinationHistory.isEmpty)
        XCTAssertTrue(preferences.moveDestinationHistory.isEmpty)
    }

    func testHistoryLimitIsClampedAndZeroDisablesRecording() throws {
        var preferences = ProfileTransferPreferences(
            destinationHistoryLimit: 500,
            addDestinationHistory: (1 ... 80).map { "/add/\($0)" }
        )

        XCTAssertEqual(preferences.destinationHistoryLimit, 50)
        XCTAssertEqual(preferences.addDestinationHistory.count, 50)

        preferences.setDestinationHistoryLimit(-10)
        XCTAssertEqual(preferences.destinationHistoryLimit, 0)
        XCTAssertTrue(preferences.addDestinationHistory.isEmpty)
        XCTAssertFalse(try preferences.recordDestination("/ignored", for: .add))
    }

    func testRecordRejectsInvalidRemoteDestinationWithoutMutation() {
        var preferences = ProfileTransferPreferences(addDestinationHistory: ["/existing"])

        XCTAssertThrowsError(try preferences.recordDestination("relative", for: .add)) { error in
            XCTAssertEqual(error as? RemotePOSIXDestinationValidationError, .notAbsolute)
        }
        XCTAssertEqual(preferences.addDestinationHistory, ["/existing"])
    }

    func testSettingDestinationRulesChangesOnlyTheValidatedSnapshot() throws {
        let rule = try destinationRule(
            label: "Video",
            destination: "/srv//Video/../TV/épisodes ",
            extensions: ["mkv"]
        )
        let snapshot = try AddTorrentDestinationRulesSnapshot(
            defaultDestination: "/srv//Default/../Incoming/ ",
            rules: [rule]
        )
        var preferences = ProfileTransferPreferences(
            downloadSpeedPresetsKBps: [125],
            uploadSpeedPresetsKBps: [25],
            destinationHistoryLimit: 2,
            addDestinationHistory: ["/existing"]
        )

        preferences.setAddDestinationRules(snapshot)

        XCTAssertEqual(preferences.addDestinationRules, snapshot)
        XCTAssertEqual(
            preferences.addDestinationRules.defaultDestination,
            "/srv//Default/../Incoming/ "
        )
        XCTAssertEqual(
            preferences.addDestinationRules.rules.map(\.destination),
            ["/srv//Video/../TV/épisodes "]
        )
        XCTAssertEqual(preferences.downloadSpeedPresetsKBps, [125])
        XCTAssertEqual(preferences.uploadSpeedPresetsKBps, [25])
        XCTAssertEqual(preferences.addDestinationHistory, ["/existing"])
    }

    func testCodableSchemaRoundTripsOnlyExplicitNonSecretFields() throws {
        let firstRule = try destinationRule(
            label: "Video",
            destination: "/downloads//Video/../TV ",
            extensions: ["mkv"]
        )
        let secondRule = try destinationRule(
            label: "Linux",
            destination: "/downloads/linux",
            nameTokens: ["linux"]
        )
        let destinationRules = try AddTorrentDestinationRulesSnapshot(
            defaultDestination: "/downloads//Default/../Incoming ",
            rules: [firstRule, secondRule]
        )
        let preferences = ProfileTransferPreferences(
            downloadSpeedPresetsKBps: [500, 50],
            uploadSpeedPresetsKBps: [25],
            destinationHistoryLimit: 4,
            addDestinationHistory: ["/downloads"],
            moveDestinationHistory: ["/archive"],
            addDestinationRules: destinationRules
        )

        let data = try JSONEncoder().encode(preferences)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["schemaVersion"] as? Int, 2)
        XCTAssertEqual(
            Set(object.keys),
            [
                "schemaVersion",
                "downloadSpeedPresetsKBps",
                "uploadSpeedPresetsKBps",
                "destinationHistoryLimit",
                "addDestinationHistory",
                "moveDestinationHistory",
                "addDestinationRules"
            ]
        )
        let decoded = try JSONDecoder().decode(ProfileTransferPreferences.self, from: data)

        XCTAssertEqual(decoded, preferences)
        XCTAssertEqual(decoded.addDestinationRules.rules.map(\.id), [firstRule.id, secondRule.id])
        XCTAssertEqual(
            decoded.addDestinationRules.defaultDestination,
            "/downloads//Default/../Incoming "
        )
        XCTAssertEqual(decoded.addDestinationRules.rules.map(\.destination), [
            "/downloads//Video/../TV ",
            "/downloads/linux"
        ])
    }

    func testSchemaZeroAliasesMigrateAndNormalize() throws {
        let data = Data(
            """
            {
                "downloadPresetsKBps": [500, 50, 500, 0],
                "uploadPresetsKBps": [100, 25],
                "historyLimit": 2,
                "addDestinations": ["/one", "relative", "/two", "/three"],
                "moveDestinations": ["/move", "/move"]
            }
            """.utf8
        )

        let preferences = try JSONDecoder().decode(ProfileTransferPreferences.self, from: data)

        XCTAssertEqual(preferences.downloadSpeedPresetsKBps, [50, 500])
        XCTAssertEqual(preferences.uploadSpeedPresetsKBps, [25, 100])
        XCTAssertEqual(preferences.destinationHistoryLimit, 2)
        XCTAssertEqual(preferences.addDestinationHistory, ["/one", "/two"])
        XCTAssertEqual(preferences.moveDestinationHistory, ["/move"])
        XCTAssertEqual(preferences.addDestinationRules, .empty)
    }

    func testSchemaOneAndMissingRulesFieldMigrateToEmptyRules() throws {
        let schemaOne = try JSONDecoder().decode(
            ProfileTransferPreferences.self,
            from: Data(
                """
                {
                    "schemaVersion": 1,
                    "downloadSpeedPresetsKBps": [125],
                    "uploadSpeedPresetsKBps": [25],
                    "destinationHistoryLimit": 2,
                    "addDestinationHistory": ["/one"],
                    "moveDestinationHistory": ["/move"]
                }
                """.utf8
            )
        )
        let missingCurrentField = try JSONDecoder().decode(
            ProfileTransferPreferences.self,
            from: Data(
                """
                {
                    "schemaVersion": 2,
                    "downloadSpeedPresetsKBps": [500],
                    "uploadSpeedPresetsKBps": [100]
                }
                """.utf8
            )
        )

        XCTAssertEqual(schemaOne.downloadSpeedPresetsKBps, [125])
        XCTAssertEqual(schemaOne.addDestinationHistory, ["/one"])
        XCTAssertEqual(schemaOne.addDestinationRules, .empty)
        XCTAssertEqual(missingCurrentField.downloadSpeedPresetsKBps, [500])
        XCTAssertEqual(missingCurrentField.uploadSpeedPresetsKBps, [100])
        XCTAssertEqual(missingCurrentField.addDestinationRules, .empty)
    }

    func testMalformedRulesFieldFallsBackWithoutDiscardingSiblingPreferences() throws {
        let malformed = try JSONDecoder().decode(
            ProfileTransferPreferences.self,
            from: Data(
                """
                {
                    "schemaVersion": 2,
                    "downloadSpeedPresetsKBps": [500, 50],
                    "uploadSpeedPresetsKBps": [25],
                    "destinationHistoryLimit": 3,
                    "addDestinationHistory": ["/downloads"],
                    "moveDestinationHistory": ["/archive"],
                    "addDestinationRules": "invalid"
                }
                """.utf8
            )
        )

        XCTAssertEqual(malformed.downloadSpeedPresetsKBps, [50, 500])
        XCTAssertEqual(malformed.uploadSpeedPresetsKBps, [25])
        XCTAssertEqual(malformed.destinationHistoryLimit, 3)
        XCTAssertEqual(malformed.addDestinationHistory, ["/downloads"])
        XCTAssertEqual(malformed.moveDestinationHistory, ["/archive"])
        XCTAssertEqual(malformed.addDestinationRules, .empty)
    }

    func testInvalidRulesPayloadFallsBackWithoutDiscardingSiblingPreferences() throws {
        let invalid = try JSONDecoder().decode(
            ProfileTransferPreferences.self,
            from: Data(
                """
                {
                    "schemaVersion": 2,
                    "downloadSpeedPresetsKBps": [125],
                    "uploadSpeedPresetsKBps": [75],
                    "destinationHistoryLimit": 1,
                    "addDestinationHistory": ["/kept"],
                    "moveDestinationHistory": [],
                    "addDestinationRules": {
                        "defaultDestination": "relative",
                        "rules": []
                    }
                }
                """.utf8
            )
        )

        XCTAssertEqual(invalid.downloadSpeedPresetsKBps, [125])
        XCTAssertEqual(invalid.uploadSpeedPresetsKBps, [75])
        XCTAssertEqual(invalid.destinationHistoryLimit, 1)
        XCTAssertEqual(invalid.addDestinationHistory, ["/kept"])
        XCTAssertEqual(invalid.addDestinationRules, .empty)
    }

    func testMissingMalformedAndFutureSchemasUseSafeDefaults() throws {
        let missing = try JSONDecoder().decode(
            ProfileTransferPreferences.self,
            from: Data("{}".utf8)
        )
        let malformed = try JSONDecoder().decode(
            ProfileTransferPreferences.self,
            from: Data(
                """
                {
                    "schemaVersion": 1,
                    "downloadSpeedPresetsKBps": "invalid",
                    "destinationHistoryLimit": "invalid",
                    "addDestinationHistory": 42
                }
                """.utf8
            )
        )
        let future = try JSONDecoder().decode(
            ProfileTransferPreferences.self,
            from: Data(#"{"schemaVersion": 99, "downloadSpeedPresetsKBps": [1]}"#.utf8)
        )

        XCTAssertEqual(missing, .defaults)
        XCTAssertEqual(malformed, .defaults)
        XCTAssertEqual(future, .defaults)
    }

    private func destinationRule(
        label: String,
        destination: String,
        extensions: [String] = [],
        nameTokens: [String] = []
    ) throws -> AddTorrentDestinationRule {
        try AddTorrentDestinationRule(
            label: label,
            destination: destination,
            extensions: extensions,
            nameTokens: nameTokens
        )
    }
}
