// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation
import XCTest
@testable import TransmissionRemoteMac

final class ApplicationBehaviorPreferencesTests: XCTestCase {
    func testDefaultsAreSafeNonSecretAndDoNotOverrideDaemonAddBehaviour() {
        let preferences = ApplicationBehaviorPreferences.defaults

        XCTAssertEqual(preferences.speedAveraging, .defaults)
        XCTAssertFalse(preferences.speedAveraging.isEnabled)
        XCTAssertTrue(preferences.completionNotificationsEnabled)
        XCTAssertEqual(preferences.addDefaults, .defaults)
        XCTAssertEqual(preferences.addDefaults.startIntent, .start)
        XCTAssertEqual(preferences.addDefaults.priority, .normal)
        XCTAssertEqual(preferences.addDefaults.unwantedFiles, .daemonDefault)
        XCTAssertNil(preferences.addDefaults.peerLimit)
        XCTAssertTrue(preferences.promptsForDownloadOptions)
        XCTAssertFalse(ApplicationBehaviorPreferences.containsAuthenticationSecrets)
    }

    func testNumericInputsAreClampedOrRejectedPredictably() {
        let lowPolicy = SpeedAveragingPolicy(
            isEnabled: true,
            sampleLimit: -10,
            windowSeconds: 0
        )
        let highPolicy = SpeedAveragingPolicy(
            isEnabled: true,
            sampleLimit: 1_000,
            windowSeconds: 100_000
        )
        let invalidAddDefaults = AddTorrentDefaults(
            startIntent: .paused,
            priority: .high,
            unwantedFiles: .daemonDefault,
            peerLimit: 0
        )

        XCTAssertEqual(lowPolicy.sampleLimit, SpeedAveragingPolicy.allowedSampleLimit.lowerBound)
        XCTAssertEqual(lowPolicy.windowSeconds, SpeedAveragingPolicy.allowedWindowSeconds.lowerBound)
        XCTAssertEqual(highPolicy.sampleLimit, SpeedAveragingPolicy.allowedSampleLimit.upperBound)
        XCTAssertEqual(highPolicy.windowSeconds, SpeedAveragingPolicy.allowedWindowSeconds.upperBound)
        XCTAssertNil(invalidAddDefaults.peerLimit)
    }

    func testUnwantedDefaultRequiresAnExplicitValidFileList() {
        let defaults = AddTorrentDefaults(
            startIntent: .paused,
            priority: .low,
            unwantedFiles: .allUnwantedWhenFileListKnown,
            peerLimit: 40
        )

        XCTAssertNil(defaults.unwantedFileIndexes(forExplicitFileIndexes: nil))
        XCTAssertNil(defaults.unwantedFileIndexes(forExplicitFileIndexes: [0, -1]))
        XCTAssertEqual(defaults.unwantedFileIndexes(forExplicitFileIndexes: []), [])
        XCTAssertEqual(
            defaults.unwantedFileIndexes(forExplicitFileIndexes: [4, 1, 4, 0]),
            [0, 1, 4]
        )
    }

    func testDaemonDefaultNeverSynthesizesUnwantedIndexes() {
        XCTAssertNil(
            AddTorrentDefaults.defaults.unwantedFileIndexes(forExplicitFileIndexes: [0, 1])
        )
    }

    func testCurrentSchemaRoundTripsOnlyNonSecretBehaviourFields() throws {
        let preferences = ApplicationBehaviorPreferences(
            speedAveraging: SpeedAveragingPolicy(
                isEnabled: false,
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

        let data = try JSONEncoder().encode(preferences)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["schemaVersion"] as? Int, 2)
        XCTAssertEqual(
            Set(object.keys),
            [
                "schemaVersion",
                "speedAveraging",
                "completionNotificationsEnabled",
                "promptsForDownloadOptions",
                "addDefaults"
            ]
        )
        XCTAssertNil(object["pollingInterval"])
        XCTAssertEqual(object["completionNotificationsEnabled"] as? Bool, false)
        XCTAssertEqual(object["promptsForDownloadOptions"] as? Bool, false)
        let addDefaults = try XCTUnwrap(object["addDefaults"] as? [String: Any])
        XCTAssertNil(addDefaults["promptsForDownloadOptions"])
        XCTAssertEqual(
            try JSONDecoder().decode(ApplicationBehaviorPreferences.self, from: data),
            preferences
        )
    }

    func testSchemaZeroAliasesMigrateAndNormalize() throws {
        let data = Data(
            """
            {
                "averageSpeeds": false,
                "speedAverageSamples": 500,
                "speedAverageWindowSeconds": 0,
                "notifyOnCompletion": true,
                "startPaused": true,
                "addPriority": -1,
                "markAllFilesUnwanted": true,
                "addPeerLimit": 60
            }
            """.utf8
        )

        let preferences = try JSONDecoder().decode(ApplicationBehaviorPreferences.self, from: data)

        XCTAssertFalse(preferences.speedAveraging.isEnabled)
        XCTAssertEqual(
            preferences.speedAveraging.sampleLimit,
            SpeedAveragingPolicy.allowedSampleLimit.upperBound
        )
        XCTAssertEqual(
            preferences.speedAveraging.windowSeconds,
            SpeedAveragingPolicy.allowedWindowSeconds.lowerBound
        )
        XCTAssertTrue(preferences.completionNotificationsEnabled)
        XCTAssertEqual(preferences.addDefaults.startIntent, .paused)
        XCTAssertEqual(preferences.addDefaults.priority, .low)
        XCTAssertEqual(
            preferences.addDefaults.unwantedFiles,
            .allUnwantedWhenFileListKnown
        )
        XCTAssertEqual(preferences.addDefaults.peerLimit, 60)
        XCTAssertTrue(preferences.promptsForDownloadOptions)
    }

    func testMalformedCurrentFieldsUseSafeDefaultsAndNormalizeValidNumbers() throws {
        let data = Data(
            """
            {
                "schemaVersion": 2,
                "speedAveraging": {
                    "isEnabled": "yes",
                    "sampleLimit": 0,
                    "windowSeconds": 99999
                },
                "completionNotificationsEnabled": "yes",
                "promptsForDownloadOptions": "no",
                "addDefaults": {
                    "startIntent": "later",
                    "priority": 42,
                    "unwantedFiles": "everything",
                    "peerLimit": 1000
                }
            }
            """.utf8
        )

        let preferences = try JSONDecoder().decode(ApplicationBehaviorPreferences.self, from: data)

        XCTAssertEqual(preferences.speedAveraging.isEnabled, SpeedAveragingPolicy.defaults.isEnabled)
        XCTAssertEqual(
            preferences.speedAveraging.sampleLimit,
            SpeedAveragingPolicy.allowedSampleLimit.lowerBound
        )
        XCTAssertEqual(
            preferences.speedAveraging.windowSeconds,
            SpeedAveragingPolicy.allowedWindowSeconds.upperBound
        )
        XCTAssertTrue(preferences.completionNotificationsEnabled)
        XCTAssertTrue(preferences.promptsForDownloadOptions)
        XCTAssertEqual(preferences.addDefaults, .defaults)
    }

    func testSchemaOneMigratesToPromptingEnabled() throws {
        let preferences = try JSONDecoder().decode(
            ApplicationBehaviorPreferences.self,
            from: Data(
                """
                {
                    "schemaVersion": 1,
                    "addDefaults": {
                        "startIntent": "paused",
                        "priority": 1,
                        "unwantedFiles": "daemonDefault",
                        "peerLimit": 40
                    }
                }
                """.utf8
            )
        )

        XCTAssertEqual(preferences.addDefaults.startIntent, .paused)
        XCTAssertEqual(preferences.addDefaults.priority, .high)
        XCTAssertEqual(preferences.addDefaults.peerLimit, 40)
        XCTAssertTrue(preferences.promptsForDownloadOptions)
    }

    func testPromptPolicyDoesNotChangePayloadDefaults() {
        let payloadDefaults = AddTorrentDefaults(
            startIntent: .paused,
            priority: .high,
            unwantedFiles: .allUnwantedWhenFileListKnown,
            peerLimit: 40
        )
        let prompting = ApplicationBehaviorPreferences(
            speedAveraging: .defaults,
            completionNotificationsEnabled: true,
            promptsForDownloadOptions: true,
            addDefaults: payloadDefaults
        )
        let direct = ApplicationBehaviorPreferences(
            speedAveraging: .defaults,
            completionNotificationsEnabled: true,
            promptsForDownloadOptions: false,
            addDefaults: payloadDefaults
        )

        XCTAssertNotEqual(prompting.promptsForDownloadOptions, direct.promptsForDownloadOptions)
        XCTAssertEqual(prompting.addDefaults, direct.addDefaults)
    }

    func testMissingAndFutureSchemasUseSafeDefaults() throws {
        let missing = try JSONDecoder().decode(
            ApplicationBehaviorPreferences.self,
            from: Data("{}".utf8)
        )
        let future = try JSONDecoder().decode(
            ApplicationBehaviorPreferences.self,
            from: Data(
                #"{"schemaVersion": 99, "completionNotificationsEnabled": true}"#.utf8
            )
        )

        XCTAssertEqual(missing, .defaults)
        XCTAssertEqual(future, .defaults)
    }

    func testExplicitIncomingAddChoicesOverrideOnlyTheirSavedDefaults() {
        let savedDefaults = AddTorrentDefaults(
            startIntent: .paused,
            priority: .low,
            unwantedFiles: .allUnwantedWhenFileListKnown,
            peerLimit: 60
        )
        let incoming = AddTorrentInitialOptions(
            startIntent: .start,
            priority: .high,
            peerLimit: .daemonDefault
        )

        XCTAssertEqual(
            incoming.resolving(defaults: savedDefaults),
            ResolvedAddTorrentInitialOptions(
                startIntent: .start,
                priority: .high,
                unwantedFiles: .allUnwantedWhenFileListKnown,
                peerLimit: .daemonDefault
            )
        )
        XCTAssertEqual(
            AddTorrentInitialOptions.unspecified.resolving(defaults: savedDefaults),
            ResolvedAddTorrentInitialOptions(
                startIntent: .paused,
                priority: .low,
                unwantedFiles: .allUnwantedWhenFileListKnown,
                peerLimit: .limited(60)
            )
        )
    }

    func testResolvedFileDefaultsApplyOnlyToAnExplicitFileList() {
        let resolved = ResolvedAddTorrentInitialOptions(
            startIntent: .paused,
            priority: .high,
            unwantedFiles: .allUnwantedWhenFileListKnown,
            peerLimit: .daemonDefault
        )
        let files = [
            TorrentMetainfoFileSelection(
                index: 0,
                path: "one.bin",
                length: 10,
                wanted: true,
                priority: .normal
            ),
            TorrentMetainfoFileSelection(
                index: 1,
                path: "two.bin",
                length: 20,
                wanted: true,
                priority: .low
            )
        ]

        let seeded = resolved.seedingFileSelections(files)

        XCTAssertEqual(seeded.map(\.wanted), [false, false])
        XCTAssertEqual(seeded.map(\.priority), [.high, .high])
        XCTAssertTrue(resolved.seedingFileSelections([]).isEmpty)
    }
}
