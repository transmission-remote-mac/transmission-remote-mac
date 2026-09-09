// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation

enum TorrentOperationCompletionExpectationValidationError: Error, Equatable, Sendable {
    case operationKindMismatch(expected: TorrentOperationKind, actual: TorrentOperationKind)
    case renameRequiresSingleTorrent
}

struct TorrentOperationPostAcknowledgementObservation: Equatable, Sendable {
    let targetHashes: Set<String>
    let acknowledgementRequestSequenceWatermark: UInt64
    private(set) var observedHashes = Set<String>()

    init(
        targetHashes: [String],
        acknowledgementRequestSequenceWatermark: UInt64
    ) {
        self.targetHashes = Set(
            targetHashes.compactMap(CanonicalTransmissionTorrentHash.normalize)
        )
        self.acknowledgementRequestSequenceWatermark = acknowledgementRequestSequenceWatermark
    }

    var hasObservedEveryTarget: Bool {
        !targetHashes.isEmpty && targetHashes.isSubset(of: observedHashes)
    }

    mutating func consume(_ authoritativeRequestSequenceByHash: [String: UInt64]) {
        for targetHash in targetHashes {
            guard
                let requestSequence = authoritativeRequestSequenceByHash[targetHash],
                requestSequence > acknowledgementRequestSequenceWatermark
            else {
                continue
            }
            observedHashes.insert(targetHash)
        }
    }
}

/// Immutable post-submission evidence required to complete an operation.
struct TorrentOperationCompletionExpectation: Equatable, Sendable {
    enum Requirement: Equatable, Sendable {
        case verification
        case destination(String)
        case name(String)
    }

    let ownership: TorrentOperationOwnership
    let requirement: Requirement

    private init(
        ownership: TorrentOperationOwnership,
        requirement: Requirement
    ) {
        self.ownership = ownership
        self.requirement = requirement
    }

    static func verify(
        ownership: TorrentOperationOwnership
    ) throws -> TorrentOperationCompletionExpectation {
        try requireKind(.verify, ownership: ownership)
        return TorrentOperationCompletionExpectation(
            ownership: ownership,
            requirement: .verification
        )
    }

    static func setLocation(
        ownership: TorrentOperationOwnership,
        destination: String
    ) throws -> TorrentOperationCompletionExpectation {
        try requireKind(.setLocation, ownership: ownership)
        return TorrentOperationCompletionExpectation(
            ownership: ownership,
            requirement: .destination(
                try RemotePOSIXDestinationValidator.validated(destination)
            )
        )
    }

    static func moveData(
        ownership: TorrentOperationOwnership,
        destination: String
    ) throws -> TorrentOperationCompletionExpectation {
        try requireKind(.moveData, ownership: ownership)
        return TorrentOperationCompletionExpectation(
            ownership: ownership,
            requirement: .destination(
                try RemotePOSIXDestinationValidator.validated(destination)
            )
        )
    }

    static func rename(
        ownership: TorrentOperationOwnership,
        requestedName: String,
        originalName: String
    ) throws -> TorrentOperationCompletionExpectation {
        try requireKind(.rename, ownership: ownership)
        guard ownership.torrentHashes.count == 1 else {
            throw TorrentOperationCompletionExpectationValidationError
                .renameRequiresSingleTorrent
        }
        return TorrentOperationCompletionExpectation(
            ownership: ownership,
            requirement: .name(
                try TorrentPathRenameValidator.normalizeNewBasename(
                    requestedName,
                    originalBasename: originalName
                )
            )
        )
    }

    private static func requireKind(
        _ expected: TorrentOperationKind,
        ownership: TorrentOperationOwnership
    ) throws {
        guard ownership.kind == expected else {
            throw TorrentOperationCompletionExpectationValidationError.operationKindMismatch(
                expected: expected,
                actual: ownership.kind
            )
        }
    }
}
