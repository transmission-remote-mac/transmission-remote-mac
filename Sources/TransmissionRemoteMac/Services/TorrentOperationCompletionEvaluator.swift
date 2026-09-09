// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation

enum TorrentOperationCompletionEvaluation: Equatable, Sendable {
    case running
    case completed
    case stale
}

/// Evaluates an accepted mutation against one authoritative torrent-list snapshot.
/// Callers remain responsible for profile and connection ownership checks.
enum TorrentOperationCompletionEvaluator {
    static func evaluateAcceptedSubmission(
        _ expectation: TorrentOperationCompletionExpectation,
        torrents: [TorrentSummary]
    ) -> TorrentOperationCompletionEvaluation {
        let targetHashes = Set(expectation.ownership.torrentHashes)
        var observations: [String: Observation] = [:]
        observations.reserveCapacity(targetHashes.count)

        for torrent in torrents {
            guard let hash = CanonicalTransmissionTorrentHash.normalize(torrent.hashString),
                  targetHashes.contains(hash) else {
                continue
            }
            guard observations[hash] == nil else {
                return .stale
            }
            observations[hash] = Observation(
                status: torrent.status,
                destination: torrent.downloadDir,
                name: torrent.name
            )
        }

        guard observations.count == targetHashes.count else {
            return .stale
        }

        switch expectation.requirement {
        case .verification:
            let isVerifying = observations.values.contains {
                $0.status == .checkWait || $0.status == .checking
            }
            return isVerifying ? .running : .completed

        case .destination(let expectedDestination):
            let allMatch = observations.values.allSatisfy {
                $0.destination == expectedDestination
            }
            return allMatch ? .completed : .running

        case .name(let expectedName):
            guard let observation = observations.values.first else {
                return .stale
            }
            return observation.name == expectedName ? .completed : .running
        }
    }

    private struct Observation {
        let status: TorrentStatus
        let destination: String
        let name: String
    }
}
