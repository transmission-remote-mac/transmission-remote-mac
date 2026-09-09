// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation

enum TorrentOperationFeedbackTransitionRejection: Equatable, Sendable {
    case duplicateOperationID
    case unknownOperation
    case ownershipMismatch
    case stalePublicationContext
    case invalidTransition(
        from: TorrentOperationFeedbackStage,
        to: TorrentOperationFeedbackStage
    )
}

enum TorrentOperationFeedbackTransitionResult: Equatable, Sendable {
    case applied(TorrentOperationFeedback)
    case rejected(TorrentOperationFeedbackTransitionRejection)
}

/// Reusable, side-effect-free lifecycle storage. AppStore owns one instance and
/// supplies current connection and torrent identity context at publish points.
struct TorrentOperationFeedbackLifecycle: Sendable {
    static let maximumRetainedTerminalOperations = 50

    private var feedbackByOperationID: [UUID: TorrentOperationFeedback] = [:]
    private var operationOrder: [UUID] = []

    init() {}

    var isEmpty: Bool { feedbackByOperationID.isEmpty }

    var feedback: [TorrentOperationFeedback] {
        operationOrder.compactMap { feedbackByOperationID[$0] }
    }

    func feedback(operationID: UUID) -> TorrentOperationFeedback? {
        feedbackByOperationID[operationID]
    }

    @discardableResult
    mutating func submit(
        _ ownership: TorrentOperationOwnership
    ) -> TorrentOperationFeedbackTransitionResult {
        guard feedbackByOperationID[ownership.operationID] == nil else {
            return .rejected(.duplicateOperationID)
        }
        pruneTerminalFeedbackIfNeeded()
        let submitted = TorrentOperationFeedback(
            ownership: ownership,
            phase: .submitted
        )
        feedbackByOperationID[ownership.operationID] = submitted
        operationOrder.append(ownership.operationID)
        return .applied(submitted)
    }

    @discardableResult
    mutating func markRunning(
        _ ownership: TorrentOperationOwnership,
        context: TorrentOperationFeedbackPublicationContext
    ) -> TorrentOperationFeedbackTransitionResult {
        transition(
            ownership,
            to: .running,
            allowedStages: [.submitted],
            context: context
        )
    }

    @discardableResult
    mutating func markCompleted(
        _ ownership: TorrentOperationOwnership,
        context: TorrentOperationFeedbackPublicationContext
    ) -> TorrentOperationFeedbackTransitionResult {
        transition(
            ownership,
            to: .completed,
            allowedStages: [.running],
            context: context
        )
    }

    @discardableResult
    mutating func markFailed(
        _ ownership: TorrentOperationOwnership,
        message: String,
        context: TorrentOperationFeedbackPublicationContext
    ) -> TorrentOperationFeedbackTransitionResult {
        let normalizedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return transition(
            ownership,
            to: .failed(
                message: normalizedMessage.isEmpty
                    ? "The operation failed."
                    : normalizedMessage
            ),
            allowedStages: [.submitted, .running],
            context: context
        )
    }

    mutating func removeTerminal(operationID: UUID) {
        guard feedbackByOperationID[operationID]?.phase.isTerminal == true else { return }
        feedbackByOperationID[operationID] = nil
        operationOrder.removeAll { $0 == operationID }
    }

    /// Removes feedback regardless of phase when its immutable owner is no longer valid.
    mutating func invalidate(operationID: UUID) {
        guard feedbackByOperationID.removeValue(forKey: operationID) != nil else { return }
        operationOrder.removeAll { $0 == operationID }
    }

    @discardableResult
    mutating func invalidateStale(
        in context: TorrentOperationFeedbackPublicationContext
    ) -> Set<UUID> {
        let staleOperationIDs = Set(operationOrder.filter { operationID in
            guard let feedback = feedbackByOperationID[operationID] else { return true }
            return !TorrentOperationFeedbackPublicationGuard.canPublish(
                ownership: feedback.ownership,
                in: context
            )
        })
        guard !staleOperationIDs.isEmpty else { return [] }

        for operationID in staleOperationIDs {
            feedbackByOperationID[operationID] = nil
        }
        operationOrder.removeAll(where: staleOperationIDs.contains)
        return staleOperationIDs
    }

    private mutating func transition(
        _ ownership: TorrentOperationOwnership,
        to phase: TorrentOperationFeedbackPhase,
        allowedStages: Set<TorrentOperationFeedbackStage>,
        context: TorrentOperationFeedbackPublicationContext
    ) -> TorrentOperationFeedbackTransitionResult {
        guard let current = feedbackByOperationID[ownership.operationID] else {
            return .rejected(.unknownOperation)
        }
        guard current.ownership == ownership else {
            return .rejected(.ownershipMismatch)
        }
        guard TorrentOperationFeedbackPublicationGuard.canPublish(
            ownership: ownership,
            in: context
        ) else {
            return .rejected(.stalePublicationContext)
        }
        guard allowedStages.contains(current.phase.stage) else {
            return .rejected(
                .invalidTransition(from: current.phase.stage, to: phase.stage)
            )
        }

        let next = TorrentOperationFeedback(ownership: ownership, phase: phase)
        feedbackByOperationID[ownership.operationID] = next
        return .applied(next)
    }

    private mutating func pruneTerminalFeedbackIfNeeded() {
        let terminalIDs = operationOrder.filter {
            feedbackByOperationID[$0]?.phase.isTerminal == true
        }
        let excess = terminalIDs.count - Self.maximumRetainedTerminalOperations + 1
        guard excess > 0 else { return }

        let prunedIDs = Set(terminalIDs.prefix(excess))
        for operationID in prunedIDs {
            feedbackByOperationID[operationID] = nil
        }
        operationOrder.removeAll(where: prunedIDs.contains)
    }
}
