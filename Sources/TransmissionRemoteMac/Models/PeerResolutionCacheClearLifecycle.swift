// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

enum PeerResolutionCacheClearOutcome: Equatable, Sendable {
    case completed
    case cancelled
    case superseded

    var confirmsCompletion: Bool {
        self == .completed
    }
}

struct PeerResolutionCacheClearLifecycle: Sendable {
    private(set) var currentGeneration: UInt64 = 0

    mutating func begin() -> UInt64 {
        currentGeneration &+= 1
        return currentGeneration
    }

    func completionOutcome(
        for generation: UInt64,
        isCancelled: Bool
    ) -> PeerResolutionCacheClearOutcome {
        guard generation == currentGeneration else { return .superseded }
        return isCancelled ? .cancelled : .completed
    }
}
