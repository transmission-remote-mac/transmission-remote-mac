// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import XCTest
@testable import TransmissionRemoteMac

final class AdaptivePollingCadencePolicyTests: XCTestCase {
    private let preferences = PollingPreferences(
        foregroundIntervalSeconds: 5,
        backgroundIntervalSeconds: 20,
        backgroundPolicy: .pollSlowly,
        adaptiveIdleEnabled: true
    )

    func testForegroundUsesSlowerIntervalOnlyForKnownIdleTorrents() {
        let policy = AdaptivePollingCadencePolicy.standard
        let token = UUID()

        XCTAssertEqual(interval(policy, token: token, hasTorrentActivity: false), 20)
        XCTAssertEqual(interval(policy, token: token, hasTorrentActivity: true), 5)
    }

    func testDisabledAdaptiveIdlePreservesConfiguredForegroundInterval() {
        let preferences = PollingPreferences(
            foregroundIntervalSeconds: 5,
            backgroundIntervalSeconds: 999,
            backgroundPolicy: .suspend,
            adaptiveIdleEnabled: false
        )

        XCTAssertEqual(AdaptivePollingCadencePolicy.standard.intervalSeconds(
            preferences: preferences,
            visibility: .foreground,
            hasTorrentActivity: false,
            recentMutation: nil,
            connectionToken: UUID(),
            now: .zero
        ), 5)
    }

    func testQueuedCheckingAndTransferringStatusesRequireActiveCadence() {
        let activeStatuses: [TorrentStatus] = [
            .checkWait, .checking, .downloadWait, .downloading, .seedWait, .seeding, .unknown
        ]

        XCTAssertTrue(activeStatuses.allSatisfy {
            AdaptivePollingCadencePolicy.requiresActiveCadence($0)
        })
        XCTAssertFalse(AdaptivePollingCadencePolicy.requiresActiveCadence(.stopped))
        XCTAssertFalse(AdaptivePollingCadencePolicy.requiresActiveCadence(.finished))
    }

    func testRecentMutationIsConnectionScopedAndExpires() {
        let policy = AdaptivePollingCadencePolicy(recentMutationWindow: .seconds(30))
        let token = UUID()
        let mutation = AdaptivePollingMutationActivity(
            connectionToken: token,
            observedAt: .seconds(10)
        )

        XCTAssertEqual(policy.intervalSeconds(
            preferences: preferences,
            visibility: .foreground,
            hasTorrentActivity: false,
            recentMutation: mutation,
            connectionToken: token,
            now: .seconds(39)
        ), 5)
        XCTAssertEqual(policy.intervalSeconds(
            preferences: preferences,
            visibility: .foreground,
            hasTorrentActivity: false,
            recentMutation: mutation,
            connectionToken: token,
            now: .seconds(40)
        ), 20)
        XCTAssertEqual(policy.intervalSeconds(
            preferences: preferences,
            visibility: .foreground,
            hasTorrentActivity: false,
            recentMutation: mutation,
            connectionToken: UUID(),
            now: .seconds(11)
        ), 20)
    }

    func testBackgroundPolicyRemainsAuthoritativeAndIdleIntervalNeverSpeedsForeground() {
        let token = UUID()
        let fasterBackground = PollingPreferences(
            foregroundIntervalSeconds: 10,
            backgroundIntervalSeconds: 3,
            backgroundPolicy: .pollSlowly,
            adaptiveIdleEnabled: true
        )
        XCTAssertEqual(AdaptivePollingCadencePolicy.standard.intervalSeconds(
            preferences: fasterBackground,
            visibility: .foreground,
            hasTorrentActivity: false,
            recentMutation: nil,
            connectionToken: token,
            now: .zero
        ), 10)

        let suspended = PollingPreferences(
            foregroundIntervalSeconds: 5,
            backgroundIntervalSeconds: 20,
            backgroundPolicy: .suspend,
            adaptiveIdleEnabled: true
        )
        XCTAssertNil(AdaptivePollingCadencePolicy.standard.intervalSeconds(
            preferences: suspended,
            visibility: .background,
            hasTorrentActivity: false,
            recentMutation: nil,
            connectionToken: token,
            now: .zero
        ))
    }

    private func interval(
        _ policy: AdaptivePollingCadencePolicy,
        token: UUID,
        hasTorrentActivity: Bool
    ) -> Int? {
        policy.intervalSeconds(
            preferences: preferences,
            visibility: .foreground,
            hasTorrentActivity: hasTorrentActivity,
            recentMutation: nil,
            connectionToken: token,
            now: .zero
        )
    }
}
