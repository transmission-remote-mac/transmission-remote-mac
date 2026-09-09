// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation

enum UpdateCheckTrigger: String, Codable, Sendable {
    case automatic
    case manual
}

struct UpdateCheckRequest: Equatable, Codable, Sendable {
    static let containsTelemetryIdentifiers = false

    let trigger: UpdateCheckTrigger
    let requestedAt: Date
}

enum UpdateCheckSkipReason: Equatable, Sendable {
    case releaseChannelNotConfigured
    case automaticChecksDisabled
    case automaticCadenceNotElapsed(nextEligibleAt: Date)
}

enum UpdateCheckDecision: Equatable, Sendable {
    case perform(UpdateCheckRequest)
    case skip(UpdateCheckSkipReason)
}

enum UpdateCheckPolicyService {
    static let releaseChannelConfigured = false

    static func decision(
        trigger: UpdateCheckTrigger,
        policy: UpdateCheckPolicy,
        now: Date,
        lastAutomaticCheckAt: Date?,
        releaseChannelConfigured: Bool = UpdateCheckPolicyService.releaseChannelConfigured
    ) -> UpdateCheckDecision {
        guard releaseChannelConfigured else {
            return .skip(.releaseChannelNotConfigured)
        }

        if trigger == .manual {
            return .perform(UpdateCheckRequest(trigger: .manual, requestedAt: now))
        }

        guard policy.automaticChecksEnabled else {
            return .skip(.automaticChecksDisabled)
        }

        if let lastAutomaticCheckAt {
            let elapsed = now.timeIntervalSince(lastAutomaticCheckAt)
            if elapsed >= 0, elapsed < policy.automaticCadence {
                return .skip(
                    .automaticCadenceNotElapsed(
                        nextEligibleAt: lastAutomaticCheckAt.addingTimeInterval(
                            policy.automaticCadence
                        )
                    )
                )
            }
        }

        return .perform(UpdateCheckRequest(trigger: .automatic, requestedAt: now))
    }
}
