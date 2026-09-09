// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation
import XCTest
@testable import TransmissionRemoteMac

final class UpdateCheckPolicyServiceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testAutomaticChecksRequireExplicitOptIn() {
        XCTAssertEqual(
            UpdateCheckPolicyService.decision(
                trigger: .automatic,
                policy: .defaults,
                now: now,
                lastAutomaticCheckAt: nil,
                releaseChannelConfigured: true
            ),
            .skip(.automaticChecksDisabled)
        )
    }

    func testNoCheckRunsWithoutAConfiguredReleaseChannel() {
        XCTAssertEqual(
            UpdateCheckPolicyService.decision(
                trigger: .manual,
                policy: .defaults,
                now: now,
                lastAutomaticCheckAt: now
            ),
            .skip(.releaseChannelNotConfigured)
        )
        XCTAssertFalse(UpdateCheckPolicyService.releaseChannelConfigured)
    }

    func testManualCheckIsPermittedOnlyAfterAReleaseChannelExists() {
        XCTAssertEqual(
            UpdateCheckPolicyService.decision(
                trigger: .manual,
                policy: .defaults,
                now: now,
                lastAutomaticCheckAt: now,
                releaseChannelConfigured: true
            ),
            .perform(UpdateCheckRequest(trigger: .manual, requestedAt: now))
        )
    }

    func testOptedInAutomaticChecksRespectBoundedCadence() {
        let policy = UpdateCheckPolicy(
            automaticChecksEnabled: true,
            automaticCadenceHours: 24
        )
        let lastCheck = now.addingTimeInterval(-23 * 60 * 60)

        XCTAssertEqual(
            UpdateCheckPolicyService.decision(
                trigger: .automatic,
                policy: policy,
                now: now,
                lastAutomaticCheckAt: lastCheck,
                releaseChannelConfigured: true
            ),
            .skip(
                .automaticCadenceNotElapsed(
                    nextEligibleAt: lastCheck.addingTimeInterval(24 * 60 * 60)
                )
            )
        )
        XCTAssertEqual(
            UpdateCheckPolicyService.decision(
                trigger: .automatic,
                policy: policy,
                now: now,
                lastAutomaticCheckAt: now.addingTimeInterval(-24 * 60 * 60),
                releaseChannelConfigured: true
            ),
            .perform(UpdateCheckRequest(trigger: .automatic, requestedAt: now))
        )
    }

    func testFirstAutomaticCheckAndClockRollbackDoNotCreateAnUnboundedDelay() {
        let policy = UpdateCheckPolicy(
            automaticChecksEnabled: true,
            automaticCadenceHours: 24
        )

        XCTAssertEqual(
            UpdateCheckPolicyService.decision(
                trigger: .automatic,
                policy: policy,
                now: now,
                lastAutomaticCheckAt: nil,
                releaseChannelConfigured: true
            ),
            .perform(UpdateCheckRequest(trigger: .automatic, requestedAt: now))
        )
        XCTAssertEqual(
            UpdateCheckPolicyService.decision(
                trigger: .automatic,
                policy: policy,
                now: now,
                lastAutomaticCheckAt: now.addingTimeInterval(365 * 24 * 60 * 60),
                releaseChannelConfigured: true
            ),
            .perform(UpdateCheckRequest(trigger: .automatic, requestedAt: now))
        )
    }

    func testUpdateCheckRequestContainsNoTelemetryIdentifier() throws {
        let request = UpdateCheckRequest(trigger: .manual, requestedAt: now)
        let data = try JSONEncoder().encode(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(Set(object.keys), ["trigger", "requestedAt"])
        XCTAssertFalse(UpdateCheckRequest.containsTelemetryIdentifiers)
    }
}
