// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation
import XCTest
@testable import TransmissionRemoteMac

final class WatchFolderScanPlannerTests: XCTestCase {
    private let sourceBookmark = Data([0x01])
    private let processedBookmark = Data([0x02])

    func testEligibilityAcceptsOnlyCompleteVisibleRegularTorrentFiles() {
        let entries = [
            entry("valid", "Movie.TORRENT"),
            entry("hidden-flag", "hidden.torrent", isHidden: true),
            entry("hidden-name", ".hidden.torrent"),
            entry("partial", "download.part.torrent"),
            entry("temporary", "download.tmp.torrent"),
            entry("symlink", "linked.torrent", kind: .symbolicLink),
            entry("directory", "folder.torrent", kind: .directory),
            entry("other", "notes.txt"),
            entry("empty-id", "missing.torrent", stableFileIdentity: "")
        ]

        XCTAssertEqual(
            WatchFolderScanPlanner.eligibleEntries(entries).map(\.stableFileIdentity),
            ["valid"]
        )
    }

    func testStableIdentityDeduplicationAndOneAtATimeReservation() throws {
        var planner = planner(successPolicy: .keepSource)
        let entries = [
            entry("same", "B.torrent"),
            entry("same", "A.torrent"),
            entry("next", "C.torrent")
        ]

        let first = try XCTUnwrap(planner.planNext(entries: entries, now: 0))
        XCTAssertEqual(first.stableFileIdentity, "same")
        XCTAssertEqual(first.fileName, "A.torrent")
        XCTAssertNil(planner.planNext(entries: entries, now: 0))

        let resolution = try planner.acknowledge(.added, for: first, now: 1)
        XCTAssertEqual(resolution.sourceDisposition, .none)
        XCTAssertEqual(
            planner.planNext(entries: entries, now: 2)?.stableFileIdentity,
            "next"
        )
    }

    func testBatchPlanningIsDeterministicBoundedAndReservesEveryJob() {
        var planner = planner(successPolicy: .keepSource)
        let entries = (0 ..< 25).reversed().map { index in
            entry("id-\(index)", String(format: "%02d.torrent", index))
        }

        let jobs = planner.planBatch(entries: entries, now: 0, limit: Int.max)

        XCTAssertEqual(jobs.count, WatchFolderScanPlanner.maximumBatchSize)
        XCTAssertEqual(
            jobs.map(\.fileName),
            (0 ..< WatchFolderScanPlanner.maximumBatchSize).map {
                String(format: "%02d.torrent", $0)
            }
        )
        XCTAssertEqual(planner.activeJobs, jobs)
        XCTAssertTrue(planner.planBatch(entries: entries, now: 0).isEmpty)
    }

    func testDeleteAndMoveAreProducedOnlyAfterSuccessfulNonDuplicateAcknowledgment() throws {
        var deletePlanner = planner(successPolicy: .deleteSource)
        let deleteJob = try XCTUnwrap(deletePlanner.planNext(
            entries: [entry("delete", "delete.torrent")],
            now: 0
        ))

        XCTAssertNotNil(deletePlanner.activeJob)
        XCTAssertEqual(
            try deletePlanner.acknowledge(.added, for: deleteJob, now: 1).sourceDisposition,
            .delete
        )

        var movePlanner = planner(successPolicy: .moveSource)
        let moveJob = try XCTUnwrap(movePlanner.planNext(
            entries: [entry("move", "move.torrent")],
            now: 0
        ))
        XCTAssertEqual(
            try movePlanner.acknowledge(.added, for: moveJob, now: 1).sourceDisposition,
            .move(destinationBookmarkData: processedBookmark)
        )
    }

    func testDuplicateAcknowledgmentNeverMutatesSourceAndIsDeduplicated() throws {
        var planner = planner(successPolicy: .deleteSource)
        let entries = [entry("duplicate", "duplicate.torrent")]
        let job = try XCTUnwrap(planner.planNext(entries: entries, now: 0))

        let resolution = try planner.acknowledge(.duplicate, for: job, now: 1)

        XCTAssertEqual(resolution.sourceDisposition, .none)
        XCTAssertNil(planner.planNext(entries: entries, now: 2))
        XCTAssertEqual(planner.state.acknowledgedFileIdentities, ["duplicate"])
    }

    func testFailureRemainsVisibleUntilBackoffRetryOrUserClear() throws {
        var planner = planner(
            successPolicy: .deleteSource,
            retryPolicy: WatchFolderRetryPolicy(
                initialDelaySeconds: 10,
                maximumDelaySeconds: 40
            )
        )
        let entries = [entry("failure", "failure.torrent")]
        let job = try XCTUnwrap(planner.planNext(entries: entries, now: 100))

        let resolution = try planner.acknowledge(
            .failed(message: "daemon unavailable"),
            for: job,
            now: 100
        )
        let failure = try XCTUnwrap(planner.state.failureQueue.failures.first)

        XCTAssertEqual(resolution.sourceDisposition, .none)
        XCTAssertTrue(planner.state.failureQueue.isVisible)
        XCTAssertEqual(failure.attemptCount, 1)
        XCTAssertEqual(failure.nextRetryTime, 110)
        XCTAssertNil(planner.planNext(entries: entries, now: 109))

        let retry = try XCTUnwrap(planner.planNext(entries: entries, now: 110))
        XCTAssertTrue(retry.isRetry)
        XCTAssertEqual(retry.attemptNumber, 2)
        _ = try planner.acknowledge(
            .failed(message: "still unavailable"),
            for: retry,
            now: 110
        )
        XCTAssertEqual(planner.state.failureQueue.failures.first?.attemptCount, 2)
        XCTAssertEqual(planner.state.failureQueue.failures.first?.nextRetryTime, 130)
        XCTAssertTrue(planner.clearFailure(stableFileIdentity: "failure"))
        XCTAssertFalse(planner.state.failureQueue.isVisible)
        XCTAssertEqual(
            planner.planNext(entries: entries, now: 111)?.stableFileIdentity,
            "failure"
        )
    }

    func testSuccessfulAddCleanupFailureRetriesCleanupWithoutAddingAgain() throws {
        var planner = planner(
            successPolicy: .deleteSource,
            retryPolicy: WatchFolderRetryPolicy(
                initialDelaySeconds: 10,
                maximumDelaySeconds: 40
            )
        )
        let entries = [entry("cleanup", "cleanup.torrent")]
        let job = try XCTUnwrap(planner.planNext(entries: entries, now: 100))

        XCTAssertEqual(try planner.sourceDisposition(for: job), .delete)
        try planner.deferSourceCleanup(
            for: job,
            message: "locked",
            now: 100
        )

        XCTAssertTrue(planner.state.isAwaitingSourceCleanup("cleanup"))
        XCTAssertNil(planner.planNext(entries: entries, now: 109))
        let retry = try XCTUnwrap(planner.planNext(entries: entries, now: 110))
        XCTAssertEqual(retry.kind, .sourceCleanup)
        _ = try planner.acknowledge(.added, for: retry, now: 110)
        XCTAssertFalse(planner.state.isAwaitingSourceCleanup("cleanup"))
        XCTAssertFalse(planner.state.failureQueue.isVisible)
        XCTAssertTrue(planner.state.acknowledgedFileIdentities.isEmpty)
    }

    func testKeepSourceRetentionCapStopsNewJobsWithoutRotatingAcknowledgments() {
        let retainedIdentities = (0 ..< WatchFolderProcessingState.maximumAcknowledgedIdentities)
            .map { "retained-\($0)" }
        var planner = planner(
            successPolicy: .keepSource,
            state: WatchFolderProcessingState(
                acknowledgedFileIdentities: retainedIdentities
            )
        )
        let entries = [entry("overflow", "overflow.torrent")]

        XCTAssertTrue(planner.planBatch(entries: entries, now: 0).isEmpty)
        XCTAssertTrue(planner.planBatch(entries: entries, now: 1).isEmpty)
        XCTAssertEqual(planner.state.acknowledgedFileIdentities, retainedIdentities)
        XCTAssertEqual(planner.state.failureQueue.overflowedFailureCount, 1)
        XCTAssertTrue(planner.state.failureQueue.isVisible)
    }

    func testFullFailureQueueBlocksUntrackedItemsWithoutCarouselEviction() {
        let retainedFailures = (0 ..< WatchFolderFailureQueueState.maximumRetainedFailures).map {
            failure(identity: "retained-\($0)", nextRetryTime: 1_000)
        }
        let retainedIdentities = retainedFailures.map(\.stableFileIdentity)
        var planner = planner(
            successPolicy: .keepSource,
            state: WatchFolderProcessingState(
                failureQueue: WatchFolderFailureQueueState(failures: retainedFailures)
            )
        )
        let entries = [entry("overflow", "overflow.torrent")]

        XCTAssertTrue(planner.planBatch(entries: entries, now: 0).isEmpty)
        XCTAssertTrue(planner.planBatch(entries: entries, now: 1).isEmpty)
        XCTAssertEqual(
            planner.state.failureQueue.failures.map(\.stableFileIdentity),
            retainedIdentities
        )
        XCTAssertEqual(planner.state.failureQueue.overflowedFailureCount, 1)
    }

    func testSourceCleanupCanDrainWhenAcknowledgmentRetentionIsFull() throws {
        let retainedIdentities = (0 ..< WatchFolderProcessingState.maximumAcknowledgedIdentities)
            .map { "retained-\($0)" }
        let cleanupFailure = failure(identity: "cleanup", nextRetryTime: 0)
        var planner = planner(
            successPolicy: .deleteSource,
            state: WatchFolderProcessingState(
                acknowledgedFileIdentities: retainedIdentities,
                failureQueue: WatchFolderFailureQueueState(failures: [cleanupFailure]),
                pendingSourceCleanupIdentities: ["cleanup"]
            )
        )

        let cleanupJob = try XCTUnwrap(planner.planNext(
            entries: [entry("cleanup", "cleanup.torrent")],
            now: 0
        ))
        XCTAssertEqual(cleanupJob.kind, .sourceCleanup)

        _ = try planner.acknowledge(.added, for: cleanupJob, now: 1)

        XCTAssertEqual(planner.state.acknowledgedFileIdentities, retainedIdentities)
        XCTAssertFalse(planner.state.isAwaitingSourceCleanup("cleanup"))
        XCTAssertFalse(planner.state.failureQueue.isVisible)
    }

    func testAuthoritativeEqualRevisionStateReplacesDivergentPlannerBranch() {
        let plannerFailure = failure(identity: "planner", nextRetryTime: 10)
        let authoritativeFailure = failure(identity: "authoritative", nextRetryTime: 10)
        var planner = planner(
            successPolicy: .keepSource,
            state: WatchFolderProcessingState(
                failureQueue: WatchFolderFailureQueueState(failures: [plannerFailure]),
                revision: 4
            )
        )
        let authoritativeState = WatchFolderProcessingState(
            failureQueue: WatchFolderFailureQueueState(failures: [authoritativeFailure]),
            revision: 4
        )

        planner.replaceState(authoritativeState)

        XCTAssertEqual(planner.state, authoritativeState)
    }

    func testDisabledOrIncompleteConfigurationNeverProducesAJob() {
        var disabled = WatchFolderScanPlanner(configuration: .defaults)
        var missingMoveBookmark = WatchFolderScanPlanner(
            configuration: WatchFolderConfiguration(
                isEnabled: true,
                sourceBookmarkData: sourceBookmark,
                remoteDestination: "/downloads",
                scanIntervalSeconds: 60,
                successPolicy: .moveSource,
                processedFolderBookmarkData: nil
            )
        )
        let entries = [entry("one", "one.torrent")]

        XCTAssertNil(disabled.planNext(entries: entries, now: 0))
        XCTAssertNil(missingMoveBookmark.planNext(entries: entries, now: 0))
    }

    func testAcknowledgmentMustMatchTheActiveJob() throws {
        var planner = planner(successPolicy: .keepSource)
        let job = try XCTUnwrap(planner.planNext(
            entries: [entry("one", "one.torrent")],
            now: 0
        ))
        let wrongJob = WatchFolderScanJob(
            stableFileIdentity: "two",
            fileName: "two.torrent",
            attemptNumber: 1,
            isRetry: false
        )

        XCTAssertThrowsError(try planner.acknowledge(.added, for: wrongJob, now: 1)) { error in
            XCTAssertEqual(error as? WatchFolderScanPlannerError, .activeJobMismatch)
        }
        XCTAssertEqual(planner.activeJob, job)
    }

    private func planner(
        successPolicy: WatchFolderSuccessPolicy,
        state: WatchFolderProcessingState = .defaults,
        retryPolicy: WatchFolderRetryPolicy = .defaults
    ) -> WatchFolderScanPlanner {
        WatchFolderScanPlanner(
            configuration: WatchFolderConfiguration(
                isEnabled: true,
                sourceBookmarkData: sourceBookmark,
                remoteDestination: "/downloads",
                scanIntervalSeconds: 30,
                successPolicy: successPolicy,
                processedFolderBookmarkData: successPolicy == .moveSource
                    ? processedBookmark
                    : nil
            ),
            state: state,
            retryPolicy: retryPolicy
        )
    }

    private func failure(
        identity: String,
        nextRetryTime: TimeInterval
    ) -> WatchFolderFailureRecord {
        WatchFolderFailureRecord(
            stableFileIdentity: identity,
            fileName: "\(identity).torrent",
            attemptCount: 1,
            firstFailureTime: 0,
            lastFailureTime: 0,
            nextRetryTime: nextRetryTime,
            errorMessage: "offline"
        )
    }

    private func entry(
        _ identity: String,
        _ name: String,
        kind: WatchFolderDirectoryEntryKind = .regularFile,
        isHidden: Bool = false,
        stableFileIdentity: String? = nil
    ) -> WatchFolderDirectoryEntry {
        WatchFolderDirectoryEntry(
            stableFileIdentity: stableFileIdentity ?? identity,
            fileName: name,
            kind: kind,
            isHidden: isHidden
        )
    }
}
