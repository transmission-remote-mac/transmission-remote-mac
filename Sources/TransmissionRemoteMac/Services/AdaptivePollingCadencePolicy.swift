// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation

struct AdaptivePollingMutationActivity: Equatable, Sendable {
    let connectionToken: UUID
    let observedAt: Duration
}

struct AdaptivePollingCadencePolicy: Equatable, Sendable {
    static let standard = AdaptivePollingCadencePolicy(
        recentMutationWindow: .seconds(30)
    )

    let recentMutationWindow: Duration

    func intervalSeconds(
        preferences: PollingPreferences,
        visibility: PollingVisibilityState,
        hasTorrentActivity: Bool,
        recentMutation: AdaptivePollingMutationActivity?,
        connectionToken: UUID,
        now: Duration
    ) -> Int? {
        guard let regularInterval = preferences.intervalSeconds(for: visibility) else {
            return nil
        }
        guard visibility == .foreground else { return regularInterval }
        guard preferences.adaptiveIdleEnabled else { return regularInterval }
        guard
            !hasTorrentActivity,
            !isRecentMutation(
                recentMutation,
                connectionToken: connectionToken,
                now: now
            )
        else {
            return regularInterval
        }

        return max(regularInterval, preferences.backgroundIntervalSeconds)
    }

    static func requiresActiveCadence(_ status: TorrentStatus) -> Bool {
        status.isActive || status.isWaiting || status == .unknown
    }

    private func isRecentMutation(
        _ mutation: AdaptivePollingMutationActivity?,
        connectionToken: UUID,
        now: Duration
    ) -> Bool {
        guard
            let mutation,
            mutation.connectionToken == connectionToken,
            now >= mutation.observedAt
        else {
            return false
        }
        return now - mutation.observedAt < recentMutationWindow
    }
}
