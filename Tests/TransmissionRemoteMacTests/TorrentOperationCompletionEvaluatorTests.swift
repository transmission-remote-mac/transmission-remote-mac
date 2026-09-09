// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import XCTest
@testable import TransmissionRemoteMac

final class TorrentOperationCompletionEvaluatorTests: XCTestCase {
    func testStaggeredMultiTargetVerificationRunsUntilNoTargetIsVerifying() throws {
        let hashes = [canonicalHash(1), canonicalHash(2)]
        let ownership = try makeOwnership(kind: .verify, hashes: hashes)
        let expectation = try TorrentOperationCompletionExpectation.verify(ownership: ownership)

        XCTAssertEqual(
            evaluate(expectation, statuses: [.checking, .stopped]),
            .running
        )
        XCTAssertEqual(
            evaluate(expectation, statuses: [.stopped, .checkWait]),
            .running
        )
        XCTAssertEqual(
            evaluate(expectation, statuses: [.stopped, .downloading]),
            .completed
        )
    }

    func testMissingHashIsStaleEvenWhenNumericIDIsReused() throws {
        let expectedHash = canonicalHash(1)
        let ownership = try makeOwnership(kind: .verify, hashes: [expectedHash])
        let expectation = try TorrentOperationCompletionExpectation.verify(ownership: ownership)
        let replacement = torrent(
            id: 1,
            hash: canonicalHash(2),
            status: .stopped
        )

        XCTAssertEqual(
            TorrentOperationCompletionEvaluator.evaluateAcceptedSubmission(
                expectation,
                torrents: [replacement]
            ),
            .stale
        )
    }

    func testLocationAndMoveRequireExactValidatedDestination() throws {
        let destination = "/srv/Media Library "
        let summaries = [
            torrent(id: 1, hash: canonicalHash(1), destination: destination),
            torrent(id: 2, hash: canonicalHash(2), destination: "/srv/Media Library"),
        ]
        let setLocation = try TorrentOperationCompletionExpectation.setLocation(
            ownership: makeOwnership(kind: .setLocation, hashes: [canonicalHash(1)]),
            destination: destination
        )
        let moveData = try TorrentOperationCompletionExpectation.moveData(
            ownership: makeOwnership(
                kind: .moveData,
                hashes: [canonicalHash(1), canonicalHash(2)]
            ),
            destination: destination
        )

        XCTAssertEqual(
            TorrentOperationCompletionEvaluator.evaluateAcceptedSubmission(
                setLocation,
                torrents: summaries
            ),
            .completed
        )
        XCTAssertEqual(
            TorrentOperationCompletionEvaluator.evaluateAcceptedSubmission(
                moveData,
                torrents: summaries
            ),
            .running
        )
    }

    func testRenameRequiresExactNormalizedName() throws {
        let hash = canonicalHash(1)
        let ownership = try makeOwnership(kind: .rename, hashes: [hash])
        let expectation = try TorrentOperationCompletionExpectation.rename(
            ownership: ownership,
            requestedName: "  New Name  ",
            originalName: "Old Name"
        )

        XCTAssertEqual(expectation.requirement, .name("New Name"))
        XCTAssertEqual(
            TorrentOperationCompletionEvaluator.evaluateAcceptedSubmission(
                expectation,
                torrents: [torrent(id: 1, hash: hash, name: "new name")]
            ),
            .running
        )
        XCTAssertEqual(
            TorrentOperationCompletionEvaluator.evaluateAcceptedSubmission(
                expectation,
                torrents: [torrent(id: 99, hash: hash, name: "New Name")]
            ),
            .completed
        )
    }

    func testEvaluationHandlesOneThousandFrozenHashes() throws {
        let hashes = (1...1_000).map(canonicalHash)
        let ownership = try makeOwnership(kind: .verify, hashes: hashes)
        let expectation = try TorrentOperationCompletionExpectation.verify(ownership: ownership)
        let torrents = hashes.enumerated().map { index, hash in
            torrent(id: index + 1, hash: hash, status: .stopped)
        }

        XCTAssertEqual(
            TorrentOperationCompletionEvaluator.evaluateAcceptedSubmission(
                expectation,
                torrents: Array(torrents.reversed())
            ),
            .completed
        )
    }

    private func evaluate(
        _ expectation: TorrentOperationCompletionExpectation,
        statuses: [TorrentStatus]
    ) -> TorrentOperationCompletionEvaluation {
        let torrents = zip(expectation.ownership.torrentHashes, statuses)
            .enumerated()
            .map { offset, pair in
                torrent(id: offset + 1, hash: pair.0, status: pair.1)
            }
        return TorrentOperationCompletionEvaluator.evaluateAcceptedSubmission(
            expectation,
            torrents: torrents
        )
    }

    private func makeOwnership(
        kind: TorrentOperationKind,
        hashes: [String]
    ) throws -> TorrentOperationOwnership {
        try TorrentOperationOwnership(
            kind: kind,
            profileID: try XCTUnwrap(
                UUID(uuidString: "00000000-0000-0000-0000-000000000010")
            ),
            connectionToken: try XCTUnwrap(
                UUID(uuidString: "00000000-0000-0000-0000-000000000020")
            ),
            torrentHashes: hashes
        )
    }

    private func torrent(
        id: Int,
        hash: String,
        name: String = "Torrent",
        status: TorrentStatus = .stopped,
        destination: String = "/downloads"
    ) -> TorrentSummary {
        TorrentSummary(json: [
            "id": .int(id),
            "hashString": .string(hash),
            "name": .string(name),
            "status": .int(status.rawValue),
            "downloadDir": .string(destination),
        ])
    }

    private func canonicalHash(_ value: Int) -> String {
        let suffix = String(value, radix: 16)
        return String(repeating: "0", count: 40 - suffix.count) + suffix
    }
}
