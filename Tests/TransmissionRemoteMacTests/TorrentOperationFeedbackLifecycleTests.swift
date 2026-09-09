// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import XCTest
@testable import TransmissionRemoteMac

final class TorrentOperationFeedbackLifecycleTests: XCTestCase {
    func testOwnershipNormalizesAndFreezesOrderedHashes() throws {
        let ownership = try makeOwnership(
            kind: .verify,
            hashes: [uppercaseHash(1), canonicalHash(2)]
        )

        XCTAssertEqual(ownership.torrentHashes, [canonicalHash(1), canonicalHash(2)])
        XCTAssertThrowsError(
            try makeOwnership(kind: .verify, hashes: [canonicalHash(1), uppercaseHash(1)])
        ) { error in
            XCTAssertEqual(
                error as? TorrentOperationOwnershipValidationError,
                .duplicateTorrentHash(canonicalHash(1))
            )
        }
    }

    func testSubmittedRunningCompletedLifecycleIsDeterministic() throws {
        let ownership = try makeOwnership(kind: .moveData)
        let context = matchingContext(for: ownership)
        var lifecycle = TorrentOperationFeedbackLifecycle()

        XCTAssertEqual(
            lifecycle.submit(ownership),
            .applied(TorrentOperationFeedback(ownership: ownership, phase: .submitted))
        )
        XCTAssertEqual(
            lifecycle.markRunning(ownership, context: context),
            .applied(TorrentOperationFeedback(ownership: ownership, phase: .running))
        )
        XCTAssertEqual(
            lifecycle.markCompleted(ownership, context: context),
            .applied(TorrentOperationFeedback(ownership: ownership, phase: .completed))
        )
        XCTAssertEqual(lifecycle.feedback(operationID: ownership.operationID)?.phase, .completed)
        XCTAssertEqual(
            lifecycle.markCompleted(ownership, context: context),
            .rejected(.invalidTransition(from: .completed, to: .completed))
        )
    }

    func testReconnectAndTorrentIdentityChangesRejectPublication() throws {
        let ownership = try makeOwnership(kind: .setLocation)
        var lifecycle = TorrentOperationFeedbackLifecycle()
        _ = lifecycle.submit(ownership)

        let reconnected = TorrentOperationFeedbackPublicationContext(
            profileID: ownership.profileID,
            connectionToken: UUID(),
            torrentHashes: ownership.torrentHashes
        )
        XCTAssertEqual(
            lifecycle.markRunning(ownership, context: reconnected),
            .rejected(.stalePublicationContext)
        )

        let replacedTorrent = TorrentOperationFeedbackPublicationContext(
            profileID: ownership.profileID,
            connectionToken: ownership.connectionToken,
            torrentHashes: [canonicalHash(9)]
        )
        XCTAssertEqual(
            lifecycle.markRunning(ownership, context: replacedTorrent),
            .rejected(.stalePublicationContext)
        )
        XCTAssertEqual(lifecycle.feedback(operationID: ownership.operationID)?.phase, .submitted)
    }

    func testInvalidateStaleRemovesSubmittedAndTerminalFeedbackOnlyForReplacedHashes() throws {
        let submitted = try makeOwnership(kind: .verify, hashes: [canonicalHash(1)])
        let completed = try makeOwnership(kind: .rename, hashes: [canonicalHash(2)])
        let retained = try makeOwnership(kind: .moveData, hashes: [canonicalHash(3)])
        var lifecycle = TorrentOperationFeedbackLifecycle()
        _ = lifecycle.submit(submitted)
        _ = lifecycle.submit(completed)
        _ = lifecycle.markRunning(completed, context: matchingContext(for: completed))
        _ = lifecycle.markCompleted(completed, context: matchingContext(for: completed))
        _ = lifecycle.submit(retained)

        let invalidated = lifecycle.invalidateStale(
            in: TorrentOperationFeedbackPublicationContext(
                profileID: retained.profileID,
                connectionToken: retained.connectionToken,
                torrentHashes: retained.torrentHashes
            )
        )

        XCTAssertEqual(invalidated, [submitted.operationID, completed.operationID])
        XCTAssertEqual(lifecycle.feedback.map(\.ownership.operationID), [retained.operationID])
    }

    func testOwnershipMismatchAndFailureDoNotAffectOtherOperations() throws {
        let rename = try makeOwnership(kind: .rename, hashes: [canonicalHash(1)])
        let verify = try makeOwnership(kind: .verify, hashes: [canonicalHash(2)])
        let mismatchedRename = try TorrentOperationOwnership(
            operationID: rename.operationID,
            kind: .rename,
            profileID: rename.profileID,
            connectionToken: UUID(),
            torrentHashes: rename.torrentHashes
        )
        let context = TorrentOperationFeedbackPublicationContext(
            profileID: rename.profileID,
            connectionToken: rename.connectionToken,
            torrentHashes: rename.torrentHashes + verify.torrentHashes
        )
        var lifecycle = TorrentOperationFeedbackLifecycle()
        _ = lifecycle.submit(rename)
        _ = lifecycle.submit(verify)

        XCTAssertEqual(
            lifecycle.markRunning(mismatchedRename, context: context),
            .rejected(.ownershipMismatch)
        )
        XCTAssertEqual(
            lifecycle.markFailed(rename, message: "  RPC rejected rename  ", context: context),
            .applied(
                TorrentOperationFeedback(
                    ownership: rename,
                    phase: .failed(message: "RPC rejected rename")
                )
            )
        )
        XCTAssertEqual(lifecycle.feedback(operationID: verify.operationID)?.phase, .submitted)
        XCTAssertEqual(lifecycle.feedback.map(\.ownership.kind), [.rename, .verify])
    }

    func testTerminalHistoryIsBoundedWithoutEvictingActiveOperations() throws {
        let active = try makeOwnership(kind: .verify)
        var lifecycle = TorrentOperationFeedbackLifecycle()
        _ = lifecycle.submit(active)

        var terminalOperationIDs: [UUID] = []
        for _ in 0...TorrentOperationFeedbackLifecycle.maximumRetainedTerminalOperations {
            let ownership = try makeOwnership(kind: .rename)
            let context = matchingContext(for: ownership)
            terminalOperationIDs.append(ownership.operationID)
            _ = lifecycle.submit(ownership)
            _ = lifecycle.markRunning(ownership, context: context)
            _ = lifecycle.markCompleted(ownership, context: context)
        }

        XCTAssertNotNil(lifecycle.feedback(operationID: active.operationID))
        XCTAssertNil(lifecycle.feedback(operationID: terminalOperationIDs[0]))
        XCTAssertEqual(
            lifecycle.feedback.filter(\.phase.isTerminal).count,
            TorrentOperationFeedbackLifecycle.maximumRetainedTerminalOperations
        )
    }

    func testInvalidateRemovesAnyFeedbackPhase() throws {
        let submitted = try makeOwnership(kind: .verify)
        let running = try makeOwnership(kind: .moveData)
        let completed = try makeOwnership(kind: .rename)
        var lifecycle = TorrentOperationFeedbackLifecycle()

        _ = lifecycle.submit(submitted)
        _ = lifecycle.submit(running)
        _ = lifecycle.markRunning(running, context: matchingContext(for: running))
        _ = lifecycle.submit(completed)
        _ = lifecycle.markRunning(completed, context: matchingContext(for: completed))
        _ = lifecycle.markCompleted(completed, context: matchingContext(for: completed))

        for operationID in [
            submitted.operationID,
            running.operationID,
            completed.operationID,
        ] {
            lifecycle.invalidate(operationID: operationID)
            XCTAssertNil(lifecycle.feedback(operationID: operationID))
        }
        XCTAssertTrue(lifecycle.feedback.isEmpty)
    }

    private func makeOwnership(
        kind: TorrentOperationKind,
        hashes: [String]? = nil
    ) throws -> TorrentOperationOwnership {
        try TorrentOperationOwnership(
            kind: kind,
            profileID: try XCTUnwrap(
                UUID(uuidString: "00000000-0000-0000-0000-000000000010")
            ),
            connectionToken: try XCTUnwrap(
                UUID(uuidString: "00000000-0000-0000-0000-000000000020")
            ),
            torrentHashes: hashes ?? [canonicalHash(1)]
        )
    }

    private func matchingContext(
        for ownership: TorrentOperationOwnership
    ) -> TorrentOperationFeedbackPublicationContext {
        TorrentOperationFeedbackPublicationContext(
            profileID: ownership.profileID,
            connectionToken: ownership.connectionToken,
            torrentHashes: ownership.torrentHashes
        )
    }

    private func canonicalHash(_ suffix: Int) -> String {
        String(repeating: "0", count: 39) + String(suffix, radix: 16)
    }

    private func uppercaseHash(_ suffix: Int) -> String {
        canonicalHash(suffix).uppercased()
    }
}
