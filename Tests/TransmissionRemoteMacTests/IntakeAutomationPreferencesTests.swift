// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation
import XCTest
@testable import TransmissionRemoteMac

final class IntakeAutomationPreferencesTests: XCTestCase {
    func testDefaultsDisableAutomationAndRetainNoSecretsOrRuntimeContents() {
        let preferences = IntakeAutomationPreferences.defaults

        XCTAssertFalse(preferences.clipboardIntake.isEnabled)
        XCTAssertEqual(preferences.sourceTorrentDeletion, .never)
        XCTAssertFalse(preferences.updateChecks.automaticChecksEnabled)
        XCTAssertEqual(preferences.updateChecks.automaticCadenceHours, 24)
        XCTAssertFalse(IntakeAutomationPreferences.containsAuthenticationSecrets)
        XCTAssertFalse(IntakeAutomationPreferences.containsClipboardContents)
        XCTAssertFalse(IntakeAutomationPreferences.containsTelemetryIdentifiers)
    }

    func testCurrentSchemaRoundTripsOnlyPolicyFields() throws {
        let preferences = IntakeAutomationPreferences(
            clipboardIntake: ClipboardTorrentIntakePolicy(isEnabled: true),
            sourceTorrentDeletion: .afterSuccessfulNonDuplicateAdd,
            updateChecks: UpdateCheckPolicy(
                automaticChecksEnabled: true,
                automaticCadenceHours: 48
            )
        )

        let data = try JSONEncoder().encode(preferences)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let serialized = try XCTUnwrap(String(data: data, encoding: .utf8)).lowercased()

        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        XCTAssertEqual(
            Set(object.keys),
            ["schemaVersion", "clipboardIntake", "sourceTorrentDeletion", "updateChecks"]
        )
        for forbiddenKey in [
            "password",
            "credential",
            "token",
            "clipboardcontent",
            "sourcepath",
            "installationid",
            "deviceid",
            "telemetry"
        ] {
            XCTAssertFalse(serialized.contains(forbiddenKey))
        }
        XCTAssertEqual(
            try JSONDecoder().decode(IntakeAutomationPreferences.self, from: data),
            preferences
        )
    }

    func testCadenceIsBoundedAtConstructionAndDecode() throws {
        XCTAssertEqual(
            UpdateCheckPolicy(
                automaticChecksEnabled: true,
                automaticCadenceHours: 0
            ).automaticCadenceHours,
            UpdateCheckPolicy.allowedAutomaticCadenceHours.lowerBound
        )
        XCTAssertEqual(
            UpdateCheckPolicy(
                automaticChecksEnabled: true,
                automaticCadenceHours: 100_000
            ).automaticCadenceHours,
            UpdateCheckPolicy.allowedAutomaticCadenceHours.upperBound
        )

        let decoded = try JSONDecoder().decode(
            IntakeAutomationPreferences.self,
            from: Data(
                #"{"schemaVersion":1,"clipboardIntake":{"isEnabled":true},"sourceTorrentDeletion":"afterSuccessfulNonDuplicateAdd","updateChecks":{"automaticChecksEnabled":true,"automaticCadenceHours":99999}}"#.utf8
            )
        )
        XCTAssertEqual(
            decoded.updateChecks.automaticCadenceHours,
            UpdateCheckPolicy.allowedAutomaticCadenceHours.upperBound
        )
    }

    func testMissingMalformedAndFutureSchemasUseSafeDefaults() throws {
        let missing = try JSONDecoder().decode(
            IntakeAutomationPreferences.self,
            from: Data("{}".utf8)
        )
        let malformed = try JSONDecoder().decode(
            IntakeAutomationPreferences.self,
            from: Data(
                #"{"schemaVersion":1,"clipboardIntake":"yes","sourceTorrentDeletion":"always","updateChecks":"hourly"}"#.utf8
            )
        )
        let future = try JSONDecoder().decode(
            IntakeAutomationPreferences.self,
            from: Data(
                #"{"schemaVersion":99,"clipboardIntake":{"isEnabled":true},"sourceTorrentDeletion":"afterSuccessfulNonDuplicateAdd","updateChecks":{"automaticChecksEnabled":true,"automaticCadenceHours":1}}"#.utf8
            )
        )

        XCTAssertEqual(missing, .defaults)
        XCTAssertEqual(malformed, .defaults)
        XCTAssertEqual(future, .defaults)
    }
}
