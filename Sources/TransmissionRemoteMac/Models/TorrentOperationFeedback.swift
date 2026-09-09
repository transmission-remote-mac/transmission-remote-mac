// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation

enum TorrentOperationKind: Equatable, Sendable {
    case verify
    case setLocation
    case moveData
    case rename
}

enum TorrentOperationOwnershipValidationError: LocalizedError, Equatable, Sendable {
    case noTorrentHashes
    case invalidTorrentHash(String)
    case duplicateTorrentHash(String)

    var errorDescription: String? {
        switch self {
        case .noTorrentHashes:
            "The operation has no stable torrent targets."
        case .invalidTorrentHash(let hash):
            "The operation contains an invalid torrent hash: \(hash)"
        case .duplicateTorrentHash(let hash):
            "The operation repeats torrent hash \(hash)."
        }
    }
}

/// Immutable ownership captured before an RPC mutation starts.
struct TorrentOperationOwnership: Equatable, Sendable {
    let operationID: UUID
    let kind: TorrentOperationKind
    let profileID: UUID
    let connectionToken: UUID
    let torrentHashes: [String]

    init(
        operationID: UUID = UUID(),
        kind: TorrentOperationKind,
        profileID: UUID,
        connectionToken: UUID,
        torrentHashes: [String]
    ) throws {
        guard !torrentHashes.isEmpty else {
            throw TorrentOperationOwnershipValidationError.noTorrentHashes
        }

        var normalizedHashes: [String] = []
        normalizedHashes.reserveCapacity(torrentHashes.count)
        var seen = Set<String>()
        for hash in torrentHashes {
            guard let normalizedHash = CanonicalTransmissionTorrentHash.normalize(hash) else {
                throw TorrentOperationOwnershipValidationError.invalidTorrentHash(hash)
            }
            guard seen.insert(normalizedHash).inserted else {
                throw TorrentOperationOwnershipValidationError.duplicateTorrentHash(
                    normalizedHash
                )
            }
            normalizedHashes.append(normalizedHash)
        }

        self.operationID = operationID
        self.kind = kind
        self.profileID = profileID
        self.connectionToken = connectionToken
        self.torrentHashes = normalizedHashes
    }
}

enum TorrentOperationFeedbackStage: Hashable, Sendable {
    case submitted
    case running
    case completed
    case failed
}

enum TorrentOperationFeedbackPhase: Equatable, Sendable {
    case submitted
    case running
    case completed
    case failed(message: String)

    var stage: TorrentOperationFeedbackStage {
        switch self {
        case .submitted: .submitted
        case .running: .running
        case .completed: .completed
        case .failed: .failed
        }
    }

    var isTerminal: Bool {
        stage == .completed || stage == .failed
    }
}

struct TorrentOperationFeedback: Identifiable, Equatable, Sendable {
    let ownership: TorrentOperationOwnership
    let phase: TorrentOperationFeedbackPhase

    var id: UUID { ownership.operationID }
}

/// Current identities used to decide whether an async transition may publish.
/// Invalid current hashes are omitted, so they can never satisfy an owner.
struct TorrentOperationFeedbackPublicationContext: Equatable, Sendable {
    let profileID: UUID
    let connectionToken: UUID
    let torrentHashes: Set<String>

    init(
        profileID: UUID,
        connectionToken: UUID,
        torrentHashes: some Sequence<String>
    ) {
        self.profileID = profileID
        self.connectionToken = connectionToken
        self.torrentHashes = Set(
            torrentHashes.compactMap(CanonicalTransmissionTorrentHash.normalize)
        )
    }
}

enum TorrentOperationFeedbackPublicationGuard {
    static func canPublish(
        ownership: TorrentOperationOwnership,
        in context: TorrentOperationFeedbackPublicationContext
    ) -> Bool {
        ownership.profileID == context.profileID
            && ownership.connectionToken == context.connectionToken
            && Set(ownership.torrentHashes).isSubset(of: context.torrentHashes)
    }
}
