// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation
import XCTest
@testable import TransmissionRemoteMac

final class PollingPreferencesTests: XCTestCase {
    func testDefaultsArePersistedWithLegacyCompatibleIntervals() {
        withTemporaryDefaults { defaults in
            let preferences = PollingPreferences.load(from: defaults)

            XCTAssertEqual(preferences, .defaults)
            XCTAssertEqual(preferences.foregroundIntervalSeconds, 5)
            XCTAssertEqual(preferences.backgroundIntervalSeconds, 20)
            XCTAssertEqual(preferences.backgroundPolicy, .pollSlowly)
            XCTAssertFalse(preferences.adaptiveIdleEnabled)
            XCTAssertEqual(PollingPreferences.load(from: defaults), preferences)
        }
    }

    func testValidPreferencesRoundTrip() {
        withTemporaryDefaults { defaults in
            let preferences = PollingPreferences(
                foregroundIntervalSeconds: 3,
                backgroundIntervalSeconds: 60,
                backgroundPolicy: .suspend,
                adaptiveIdleEnabled: true
            )

            preferences.save(to: defaults)

            XCTAssertEqual(PollingPreferences.load(from: defaults), preferences)
            XCTAssertEqual(preferences.intervalSeconds(for: .foreground), 3)
            XCTAssertNil(preferences.intervalSeconds(for: .background))
        }
    }

    func testInvalidIntervalsAreRejectedAndInvalidPersistenceFallsBack() {
        withTemporaryDefaults { defaults in
            defaults.set(0, forKey: "application.polling.foregroundIntervalSeconds.v1")
            defaults.set(1_000, forKey: "application.polling.backgroundIntervalSeconds.v1")
            defaults.set("unknown", forKey: "application.polling.backgroundPolicy.v1")
            defaults.set("yes please", forKey: "application.polling.adaptiveIdleEnabled.v1")

            XCTAssertEqual(PollingPreferences.load(from: defaults), .defaults)

            let invalid = PollingPreferences(
                foregroundIntervalSeconds: 0,
                backgroundIntervalSeconds: 1_000,
                backgroundPolicy: .pollSlowly
            )
            XCTAssertEqual(invalid.validationIssues.count, 2)
        }
    }

    private func withTemporaryDefaults(_ body: (UserDefaults) -> Void) {
        let suiteName = "PollingPreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        body(defaults)
    }
}
