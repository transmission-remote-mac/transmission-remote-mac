// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation

struct ReconnectBackoff: Equatable {
    private(set) var currentDelay = 0

    mutating func nextDelay() -> Int {
        switch currentDelay {
        case 0:
            currentDelay = 5
        case ..<10:
            currentDelay += 5
        default:
            currentDelay = min(currentDelay + 10, 60)
        }
        return currentDelay
    }

    mutating func reset() {
        currentDelay = 0
    }
}

protocol ReconnectSleeping: Sendable {
    func sleep(for duration: Duration) async throws
}

struct TaskReconnectSleeper: ReconnectSleeping {
    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}
