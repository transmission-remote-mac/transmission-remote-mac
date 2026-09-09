// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Combine
import Foundation
import XCTest
@testable import TransmissionRemoteMac

@MainActor
final class AppStoreDetailSchedulingTests: XCTestCase {
    override func tearDown() {
        AppStoreMockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testPeriodicRefreshPollsOverviewButNeverFiles() async throws {
        let clock = TestPollingClock()
        let recorder = DetailSchedulingRequestRecorder()
        configureRPC(recorder: recorder)
        let store = try makeStore(
            pollingCoordinator: PollingCoordinator(clock: clock),
            detailRefreshPolicy: TorrentDetailRefreshPolicy(prefetchPolicy: nil)
        )
        await store.connect()

        store.selectedTorrentDetailPane = .files
        store.selectedTorrentIDs = [1]
        let filesLoaded = await waitForDetail(store, pane: .files)
        XCTAssertTrue(filesLoaded)
        recorder.reset()

        let filesDeadlineScheduled = await waitForPollingCondition { clock.pendingSleepCount == 1 }
        XCTAssertTrue(filesDeadlineScheduled)
        clock.advance(by: .seconds(5))
        let filesPollCompleted = await waitForPollingCondition { recorder.listRequestCount == 1 }
        XCTAssertTrue(filesPollCompleted)
        XCTAssertTrue(recorder.detailPanes.isEmpty)

        store.selectedTorrentDetailPane = .overview
        let overviewLoaded = await waitForDetail(store, pane: .overview)
        XCTAssertTrue(overviewLoaded)
        recorder.reset()

        let overviewDeadlineScheduled = await waitForPollingCondition { clock.pendingSleepCount == 1 }
        XCTAssertTrue(overviewDeadlineScheduled)
        clock.advance(by: .seconds(5))
        let overviewPollCompleted = await waitForPollingCondition {
            recorder.listRequestCount == 1 && recorder.detailPanes == [.overview]
        }
        XCTAssertTrue(overviewPollCompleted)
        XCTAssertEqual(
            Array(recorder.torrentGetSequence.prefix(2)),
            ["detail:overview:1", "list"]
        )
        store.disconnect()
    }

    func testTrackerPollingUsesSlowCadence() async throws {
        let clock = TestPollingClock()
        let recorder = DetailSchedulingRequestRecorder()
        configureRPC(recorder: recorder)
        let store = try makeStore(
            pollingCoordinator: PollingCoordinator(clock: clock),
            detailRefreshPolicy: TorrentDetailRefreshPolicy(
                slowPollingMultiplier: 5,
                prefetchPolicy: nil
            )
        )
        await store.connect()

        store.selectedTorrentDetailPane = .trackers
        store.selectedTorrentIDs = [1]
        let trackersLoaded = await waitForDetail(store, pane: .trackers)
        XCTAssertTrue(trackersLoaded)
        recorder.reset()

        for expectedListCount in 1...4 {
            let deadlineScheduled = await waitForPollingCondition { clock.pendingSleepCount == 1 }
            XCTAssertTrue(deadlineScheduled)
            clock.advance(by: .seconds(5))
            let pollCompleted = await waitForPollingCondition {
                recorder.listRequestCount == expectedListCount
            }
            XCTAssertTrue(pollCompleted)
            XCTAssertTrue(recorder.detailPanes.isEmpty)
        }

        let slowDeadlineScheduled = await waitForPollingCondition { clock.pendingSleepCount == 1 }
        XCTAssertTrue(slowDeadlineScheduled)
        clock.advance(by: .seconds(5))
        let slowPollCompleted = await waitForPollingCondition {
            recorder.listRequestCount == 5 && recorder.detailPanes == [.trackers]
        }
        XCTAssertTrue(slowPollCompleted)
        store.disconnect()
    }

    func testIdenticalPeriodicOverviewSnapshotDoesNotRepublishDetailState() async throws {
        let clock = TestPollingClock()
        let recorder = DetailSchedulingRequestRecorder()
        configureRPC(recorder: recorder)
        let store = try makeStore(
            pollingCoordinator: PollingCoordinator(clock: clock),
            detailRefreshPolicy: TorrentDetailRefreshPolicy(prefetchPolicy: nil)
        )
        await store.connect()

        store.selectedTorrentIDs = [1]
        let overviewLoaded = await waitForDetail(store, pane: .overview)
        XCTAssertTrue(overviewLoaded)
        recorder.reset()
        var detailPublicationCount = 0
        let observation = store.$selectedTorrentDetailState.dropFirst().sink { _ in
            detailPublicationCount += 1
        }

        let deadlineScheduled = await waitForPollingCondition { clock.pendingSleepCount == 1 }
        XCTAssertTrue(deadlineScheduled)
        clock.advance(by: .seconds(5))
        let overviewRefreshed = await waitForPollingCondition { recorder.detailPanes == [.overview] }
        XCTAssertTrue(overviewRefreshed)
        await Task.yield()

        XCTAssertEqual(detailPublicationCount, 0)
        XCTAssertEqual(store.selectedTorrentDetailState.detail?.generalInfo?.comment, "overview")
        withExtendedLifetime(observation) {}
        store.disconnect()
    }

    func testMutationRefreshesTargetedRowsAndExactDetailPane() async throws {
        let recorder = DetailSchedulingRequestRecorder()
        configureRPC(recorder: recorder)
        let store = try makeStore(
            pollingCoordinator: PollingCoordinator(clock: TestPollingClock()),
            detailRefreshPolicy: TorrentDetailRefreshPolicy(prefetchPolicy: nil)
        )
        await store.connect()

        store.selectedTorrentIDs = [1]
        let overviewLoaded = await waitForDetail(store, pane: .overview)
        XCTAssertTrue(overviewLoaded)
        recorder.reset()

        await store.startSelected()
        XCTAssertEqual(recorder.targetedListIDs, [[1]])
        XCTAssertTrue(recorder.detailPanes.isEmpty)

        store.selectedTorrentDetailPane = .trackers
        let trackersLoaded = await waitForDetail(store, pane: .trackers)
        XCTAssertTrue(trackersLoaded)
        recorder.reset()
        await store.reannounceSelected()
        XCTAssertEqual(recorder.targetedListIDs, [[1]])
        XCTAssertEqual(recorder.detailPanes, [.trackers])

        store.selectedTorrentDetailPane = .files
        let filesLoaded = await waitForDetail(store, pane: .files)
        XCTAssertTrue(filesLoaded)
        let filesOwner = try XCTUnwrap(store.selectedTorrentFileMutationOwner)
        recorder.reset()
        await store.setTorrentFilesWanted(false, fileIndexes: [0], owner: filesOwner)
        XCTAssertEqual(recorder.targetedListIDs, [[1]])
        XCTAssertEqual(recorder.detailPanes, [.files])

        store.selectedTorrentDetailPane = .trackers
        let trackersReady = await waitForDetail(store, pane: .trackers)
        XCTAssertTrue(trackersReady)
        let trackersOwner = try XCTUnwrap(store.selectedTorrentTrackerMutationOwner)
        recorder.reset()
        await store.addTorrentTracker("https://tracker.example/new", owner: trackersOwner)
        XCTAssertEqual(recorder.targetedListIDs, [[1]])
        XCTAssertEqual(recorder.detailPanes, [.trackers])
        store.disconnect()
    }

    func testLargeTorrentSkipsOneTimePrefetch() async throws {
        let recorder = DetailSchedulingRequestRecorder()
        configureRPC(recorder: recorder, torrentSize: 1_001)
        let store = try makeStore(
            pollingCoordinator: PollingCoordinator(clock: TestPollingClock()),
            detailRefreshPolicy: TorrentDetailRefreshPolicy(
                prefetchPolicy: TorrentDetailPrefetchPolicy(maximumTorrentSizeBytes: 1_000)
            )
        )
        await store.connect()

        store.selectedTorrentIDs = [1]
        let overviewLoaded = await waitForDetail(store, pane: .overview)
        XCTAssertTrue(overviewLoaded)
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(recorder.detailPanes, [.overview])
        store.disconnect()
    }

    func testBackgroundSelectionLoadsOnlyActivePaneAndNeverStartsPrefetch() async throws {
        let recorder = DetailSchedulingRequestRecorder()
        configureRPC(recorder: recorder)
        let store = try makeStore(
            pollingCoordinator: PollingCoordinator(clock: TestPollingClock()),
            detailRefreshPolicy: TorrentDetailRefreshPolicy(prefetchPolicy: .standard)
        )
        await store.connect()
        store.updatePollingVisibility(.background)
        recorder.reset()

        store.selectedTorrentIDs = [1]
        let overviewLoaded = await waitForDetail(store, pane: .overview)
        XCTAssertTrue(overviewLoaded)
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(recorder.detailPanes, [.overview])
        store.disconnect()
    }

    func testActivePaneRequestPromotesSameKeyPrefetchWithoutCancellingOrReissuing() async throws {
        let recorder = DetailSchedulingRequestRecorder()
        let trackerStarted = expectation(description: "tracker prefetch started")
        let trackerStartedSignal = OneShotExpectationSignal(trackerStarted)
        let releaseTracker = DispatchSemaphore(value: 0)
        AppStoreMockURLProtocol.requestHandler = { request in
            let action = try request.decodedActionBody()
            recorder.record(action)
            switch action.method {
            case "session-get":
                return rpcTestResponse(
                    body: #"{"result":"success","arguments":{"rpc-version":18,"version":"4.0","download-dir":"/downloads"}}"#
                )
            case "torrent-get":
                if let pane = detailPane(action) {
                    let torrentID = detailSelectorID(action) ?? 1
                    if pane == .trackers {
                        trackerStartedSignal.fulfill()
                        _ = releaseTracker.wait(timeout: .now() + 2)
                    }
                    return detailResponse(pane: pane, torrentID: torrentID)
                }
                return listResponse(torrentSize: 100)
            default:
                return rpcTestResponse(body: #"{"result":"success","arguments":{}}"#)
            }
        }
        let store = try makeStore(
            pollingCoordinator: PollingCoordinator(clock: TestPollingClock()),
            detailRefreshPolicy: TorrentDetailRefreshPolicy(prefetchPolicy: .standard)
        )
        await store.connect()

        store.selectedTorrentIDs = [1]
        await fulfillment(of: [trackerStarted], timeout: 1)
        store.selectedTorrentDetailPane = .trackers
        store.updatePollingVisibility(.background)
        await Task.yield()

        XCTAssertEqual(recorder.detailRequestCount(pane: .trackers, torrentID: 1), 1)
        releaseTracker.signal()
        let trackersLoaded = await waitForDetail(store, pane: .trackers)

        XCTAssertTrue(trackersLoaded)
        XCTAssertEqual(recorder.detailRequestCount(pane: .trackers, torrentID: 1), 1)
        XCTAssertEqual(recorder.detailPanes, [.overview, .trackers])
        XCTAssertFalse(recorder.detailPanes.contains(.files))
        store.disconnect()
    }

    func testSelectionChangeCancelsStaleDetailBeforeStartingReplacement() async throws {
        let recorder = DetailSchedulingRequestRecorder()
        let trackerStarted = expectation(description: "tracker prefetch started")
        let replacementStarted = expectation(description: "replacement overview request started")
        let trackerStartedSignal = OneShotExpectationSignal(trackerStarted)
        let replacementStartedSignal = OneShotExpectationSignal(replacementStarted)
        let releaseTracker = DispatchSemaphore(value: 0)
        defer { releaseTracker.signal() }
        AppStoreMockURLProtocol.requestHandler = { request in
            let action = try request.decodedActionBody()
            recorder.record(action)
            switch action.method {
            case "session-get":
                return rpcTestResponse(
                    body: #"{"result":"success","arguments":{"rpc-version":18,"version":"4.0","download-dir":"/downloads"}}"#
                )
            case "torrent-get":
                if let pane = detailPane(action) {
                    let torrentID = detailSelectorID(action) ?? 1
                    if pane == .trackers, torrentID == 1 {
                        trackerStartedSignal.fulfill()
                        _ = releaseTracker.wait(timeout: .now() + 5)
                    } else if pane == .overview, torrentID == 2 {
                        replacementStartedSignal.fulfill()
                    }
                    return detailResponse(pane: pane, torrentID: torrentID)
                }
                return listResponse(torrentSize: 100)
            default:
                return rpcTestResponse(body: #"{"result":"success","arguments":{}}"#)
            }
        }
        let store = try makeStore(
            pollingCoordinator: PollingCoordinator(clock: TestPollingClock()),
            detailRefreshPolicy: TorrentDetailRefreshPolicy(prefetchPolicy: .standard)
        )
        await store.connect()

        store.selectedTorrentIDs = [1]
        await fulfillment(of: [trackerStarted], timeout: 1)
        store.selectedTorrentIDs = [2]
        await fulfillment(of: [replacementStarted], timeout: 1)
        let overviewLoaded = await waitForDetail(store, pane: .overview)

        XCTAssertTrue(overviewLoaded)
        XCTAssertEqual(store.selectedTorrentDetailState.detail?.id, 2)
        XCTAssertEqual(recorder.detailRequestCount(pane: .trackers, torrentID: 1), 1)
        XCTAssertEqual(recorder.detailRequestCount(pane: .overview, torrentID: 2), 1)
        store.disconnect()
    }

    func testListHashReplacementClearsPieceMapAndReloadsSelectedIDWithoutReselection() async throws {
        let clock = TestPollingClock()
        let replacementStarted = expectation(description: "replacement identity overview started")
        let fixture = DetailIdentityReplacementRPCFixture(
            replacementStarted: OneShotExpectationSignal(replacementStarted)
        )
        defer { fixture.releaseReplacementDetail() }
        AppStoreMockURLProtocol.requestHandler = { request in
            try fixture.response(for: request.decodedActionBody())
        }
        let store = try makeStore(
            pollingCoordinator: PollingCoordinator(clock: clock),
            detailRefreshPolicy: TorrentDetailRefreshPolicy(prefetchPolicy: nil)
        )
        await store.connect()

        store.selectedTorrentIDs = [1]
        let originalLoaded = await waitForPollingCondition {
            store.selectedTorrentDetailState.detail?.generalInfo?.hashString
                == DetailIdentityReplacementRPCFixture.originalHash
        }
        XCTAssertTrue(originalLoaded)
        guard
            let originalPieceMapState = store.selectedTorrentDetailState
                .detail?.generalInfo?.pieceMapState,
            case .available(let originalMap) = originalPieceMapState
        else {
            return XCTFail("Expected the original identity piece map")
        }
        XCTAssertEqual(originalMap.completedPieceCount, 1)

        let deadlineScheduled = await waitForPollingCondition { clock.pendingSleepCount == 1 }
        XCTAssertTrue(deadlineScheduled)
        clock.advance(by: .seconds(5))
        await fulfillment(of: [replacementStarted], timeout: 1)

        XCTAssertEqual(store.selectedTorrentIDs, [1])
        XCTAssertNil(store.selectedTorrentDetailState.detail)

        fixture.releaseReplacementDetail()
        let replacementLoaded = await waitForPollingCondition {
            store.selectedTorrentDetailState.detail?.generalInfo?.hashString
                == DetailIdentityReplacementRPCFixture.replacementHash
        }
        XCTAssertTrue(replacementLoaded)
        XCTAssertEqual(store.selectedTorrentIDs, [1])
        XCTAssertEqual(
            store.selectedTorrentDetailState.detail?.generalInfo?.comment,
            "replacement identity"
        )
        guard
            let replacementPieceMapState = store.selectedTorrentDetailState
                .detail?.generalInfo?.pieceMapState,
            case .available(let replacementMap) = replacementPieceMapState
        else {
            return XCTFail("Expected the replacement identity piece map")
        }
        XCTAssertEqual(replacementMap.completedPieceCount, 8)
        XCTAssertEqual(fixture.targetedBootstrapIDs, [[1]])
        store.disconnect()
    }

    func testEveryRPCDetailPaneRejectsMismatchedHash() async throws {
        try await assertEveryRPCDetailPaneRejectsIdentity(
            returnedHash: String(repeating: "2", count: 40)
        )
    }

    func testEveryRPCDetailPaneRejectsMissingHash() async throws {
        try await assertEveryRPCDetailPaneRejectsIdentity(returnedHash: nil)
    }

    func testActiveDetailFromReusedNumericIDIsCancelledBeforeItCanPublish() async throws {
        let recorder = DetailSchedulingRequestRecorder()
        let originalDetailStarted = expectation(description: "original identity detail started")
        let originalDetailStartedSignal = OneShotExpectationSignal(originalDetailStarted)
        let releaseOriginalDetail = DispatchSemaphore(value: 0)
        defer { releaseOriginalDetail.signal() }
        AppStoreMockURLProtocol.requestHandler = { request in
            let action = try request.decodedActionBody()
            recorder.record(action)
            switch action.method {
            case "session-get":
                return rpcTestResponse(
                    body: #"{"result":"success","arguments":{"rpc-version":18,"version":"4.0","download-dir":"/downloads"}}"#
                )
            case "torrent-get":
                if detailPane(action) == .overview {
                    if action.arguments["ids"] == .array([.string(DetailIdentityReplacementRPCFixture.originalHash)]) {
                        originalDetailStartedSignal.fulfill()
                        _ = releaseOriginalDetail.wait(timeout: .now() + 5)
                        return rpcTestResponse(
                            body: DetailIdentityReplacementRPCFixture.originalDetailResponse
                        )
                    }
                    return rpcTestResponse(
                        body: DetailIdentityReplacementRPCFixture.replacementDetailResponse
                    )
                }
                return rpcTestResponse(body: DetailIdentityReplacementRPCFixture.originalListResponse)
            default:
                return rpcTestResponse(body: #"{"result":"success","arguments":{}}"#)
            }
        }
        let store = try makeStore(
            pollingCoordinator: PollingCoordinator(clock: TestPollingClock()),
            detailRefreshPolicy: TorrentDetailRefreshPolicy(prefetchPolicy: nil)
        )
        await store.connect()

        store.selectedTorrentIDs = [1]
        await fulfillment(of: [originalDetailStarted], timeout: 1)
        store.torrents = [TorrentSummary(json: [
            "id": .int(1),
            "name": .string("Replacement identity"),
            "status": .int(TorrentStatus.downloading.rawValue),
            "hashString": .string(DetailIdentityReplacementRPCFixture.replacementHash),
            "downloadDir": .string("/downloads"),
        ])]

        XCTAssertEqual(store.selectedTorrentIDs, [1])
        XCTAssertNil(store.selectedTorrentDetailState.detail)

        releaseOriginalDetail.signal()
        let replacementLoaded = await waitForPollingCondition {
            store.selectedTorrentDetailState.detail?.generalInfo?.hashString
                == DetailIdentityReplacementRPCFixture.replacementHash
        }
        XCTAssertTrue(replacementLoaded)
        XCTAssertEqual(
            store.selectedTorrentDetailState.detail?.generalInfo?.comment,
            "replacement identity"
        )
        XCTAssertEqual(recorder.detailSelectorHashes, [
            DetailIdentityReplacementRPCFixture.originalHash,
            DetailIdentityReplacementRPCFixture.replacementHash,
        ])
        store.disconnect()
    }

    func testPaneChangeCancelsDifferentKeyPrefetchBeforeStartingActivePane() async throws {
        let recorder = DetailSchedulingRequestRecorder()
        let trackerStarted = expectation(description: "tracker prefetch started")
        let peersStarted = expectation(description: "active peers request started")
        let trackerStartedSignal = OneShotExpectationSignal(trackerStarted)
        let peersStartedSignal = OneShotExpectationSignal(peersStarted)
        let releaseTracker = DispatchSemaphore(value: 0)
        defer { releaseTracker.signal() }
        AppStoreMockURLProtocol.requestHandler = { request in
            let action = try request.decodedActionBody()
            recorder.record(action)
            switch action.method {
            case "session-get":
                return rpcTestResponse(
                    body: #"{"result":"success","arguments":{"rpc-version":18,"version":"4.0","download-dir":"/downloads"}}"#
                )
            case "torrent-get":
                if let pane = detailPane(action) {
                    let torrentID = detailSelectorID(action) ?? 1
                    if pane == .trackers, torrentID == 1 {
                        trackerStartedSignal.fulfill()
                        _ = releaseTracker.wait(timeout: .now() + 5)
                    } else if pane == .peers, torrentID == 1 {
                        peersStartedSignal.fulfill()
                    }
                    return detailResponse(pane: pane, torrentID: torrentID)
                }
                return listResponse(torrentSize: 100)
            default:
                return rpcTestResponse(body: #"{"result":"success","arguments":{}}"#)
            }
        }
        let store = try makeStore(
            pollingCoordinator: PollingCoordinator(clock: TestPollingClock()),
            detailRefreshPolicy: TorrentDetailRefreshPolicy(prefetchPolicy: .standard)
        )
        await store.connect()

        store.selectedTorrentIDs = [1]
        await fulfillment(of: [trackerStarted], timeout: 1)
        store.selectedTorrentDetailPane = .peers
        await fulfillment(of: [peersStarted], timeout: 1)
        let peersLoaded = await waitForDetail(store, pane: .peers)

        XCTAssertTrue(peersLoaded)
        XCTAssertEqual(recorder.detailRequestCount(pane: .trackers, torrentID: 1), 1)
        XCTAssertEqual(recorder.detailRequestCount(pane: .peers, torrentID: 1), 1)
        store.disconnect()
    }

    func testHidingDetailCancelsPrefetchSoShowingCanRefreshImmediately() async throws {
        let recorder = DetailSchedulingRequestRecorder()
        let trackerStarted = expectation(description: "tracker prefetch started")
        let replacementStarted = expectation(description: "replacement overview request started")
        let trackerStartedSignal = OneShotExpectationSignal(trackerStarted)
        let replacementStartedSignal = OneShotExpectationSignal(replacementStarted)
        let releaseTracker = DispatchSemaphore(value: 0)
        defer { releaseTracker.signal() }
        AppStoreMockURLProtocol.requestHandler = { request in
            let action = try request.decodedActionBody()
            recorder.record(action)
            switch action.method {
            case "session-get":
                return rpcTestResponse(
                    body: #"{"result":"success","arguments":{"rpc-version":18,"version":"4.0","download-dir":"/downloads"}}"#
                )
            case "torrent-get":
                if let pane = detailPane(action) {
                    let torrentID = detailSelectorID(action) ?? 1
                    if pane == .trackers, torrentID == 1 {
                        trackerStartedSignal.fulfill()
                        _ = releaseTracker.wait(timeout: .now() + 5)
                    } else if
                        pane == .overview,
                        torrentID == 1,
                        recorder.detailRequestCount(pane: .overview, torrentID: 1) == 2
                    {
                        replacementStartedSignal.fulfill()
                    }
                    return detailResponse(pane: pane, torrentID: torrentID)
                }
                return listResponse(torrentSize: 100)
            default:
                return rpcTestResponse(body: #"{"result":"success","arguments":{}}"#)
            }
        }
        let store = try makeStore(
            pollingCoordinator: PollingCoordinator(clock: TestPollingClock()),
            detailRefreshPolicy: TorrentDetailRefreshPolicy(prefetchPolicy: .standard)
        )
        await store.connect()

        store.selectedTorrentIDs = [1]
        await fulfillment(of: [trackerStarted], timeout: 1)
        store.isTorrentDetailVisible = false
        store.isTorrentDetailVisible = true
        await fulfillment(of: [replacementStarted], timeout: 1)

        XCTAssertEqual(recorder.detailRequestCount(pane: .trackers, torrentID: 1), 1)
        XCTAssertEqual(recorder.detailRequestCount(pane: .overview, torrentID: 1), 2)
        store.disconnect()
    }

    func testDaemonMutationRefreshesSessionInfoWithoutSessionStats() async throws {
        let recorder = DetailSchedulingRequestRecorder()
        configureRPC(recorder: recorder)
        let store = try makeStore(
            pollingCoordinator: PollingCoordinator(clock: TestPollingClock()),
            detailRefreshPolicy: TorrentDetailRefreshPolicy(prefetchPolicy: nil)
        )
        await store.connect()
        recorder.reset()

        let result = await store.applyDaemonOptions(
            DaemonOptionsUpdate(downloadDirectory: "/updated")
        )

        XCTAssertEqual(result, .succeeded)
        XCTAssertEqual(recorder.count(method: "session-set"), 1)
        XCTAssertEqual(recorder.count(method: "session-get"), 1)
        XCTAssertEqual(recorder.count(method: "session-stats"), 0)
        store.disconnect()
    }

    func testDaemonMutationAwaitsAuthoritativeSessionRefreshWhileRefreshDrainIsBusy() async throws {
        let sessionRefreshStarted = expectation(description: "session refresh started")
        let daemonRefreshCompleted = expectation(description: "daemon refresh completed")
        let fixture = DaemonApplyRefreshBarrierFixture(
            sessionRefreshStarted: sessionRefreshStarted,
            daemonRefreshCompleted: daemonRefreshCompleted
        )
        AppStoreMockURLProtocol.requestHandler = { request in
            try fixture.response(for: request.decodedActionBody())
        }
        let store = try makeStore(
            pollingCoordinator: PollingCoordinator(clock: TestPollingClock()),
            detailRefreshPolicy: TorrentDetailRefreshPolicy(prefetchPolicy: nil)
        )
        await store.connect()
        fixture.armSessionRefreshBarrier()

        let refreshTask = Task { await store.refresh() }
        await fulfillment(of: [sessionRefreshStarted], timeout: 1)
        let applyTask = Task {
            await store.applyDaemonOptions(
                DaemonOptionsUpdate(downloadDirectory: "/updated")
            )
        }

        await fulfillment(of: [daemonRefreshCompleted], timeout: 1)
        let result = await applyTask.value

        XCTAssertEqual(result, .succeeded)
        XCTAssertEqual(store.sessionInfo?.downloadDir, "/updated")
        fixture.releaseSessionRefresh()
        await refreshTask.value
        XCTAssertEqual(store.sessionInfo?.downloadDir, "/updated")
        store.disconnect()
    }

    func testDaemonMutationReturnsRPCFailureAndPreservesAppStoreError() async throws {
        let recorder = DetailSchedulingRequestRecorder()
        configureRPC(recorder: recorder, daemonOptionsResult: "permission denied")
        let store = try makeStore(
            pollingCoordinator: PollingCoordinator(clock: TestPollingClock()),
            detailRefreshPolicy: TorrentDetailRefreshPolicy(prefetchPolicy: nil)
        )
        await store.connect()
        recorder.reset()

        let result = await store.applyDaemonOptions(
            DaemonOptionsUpdate(downloadDirectory: "/updated")
        )

        guard case .failed(let message) = result else {
            return XCTFail("Expected an RPC failure, got \(result).")
        }
        XCTAssertTrue(message.contains("permission denied"))
        XCTAssertEqual(store.errorMessage, message)
        XCTAssertEqual(recorder.count(method: "session-set"), 1)
        XCTAssertEqual(recorder.count(method: "session-get"), 0)
        store.disconnect()
    }

    func testDelayedFilesCallbackFailsClosedAfterSelectionChanges() async throws {
        let recorder = DetailSchedulingRequestRecorder()
        configureRPC(recorder: recorder)
        let store = try makeStore(
            pollingCoordinator: PollingCoordinator(clock: TestPollingClock()),
            detailRefreshPolicy: TorrentDetailRefreshPolicy(prefetchPolicy: nil)
        )
        await store.connect()

        store.selectedTorrentDetailPane = .files
        store.selectedTorrentIDs = [1]
        let filesLoaded = await waitForDetail(store, pane: .files)
        XCTAssertTrue(filesLoaded)
        let owner = try XCTUnwrap(store.selectedTorrentFileMutationOwner)
        let gate = DelayedDetailMutationGate()
        recorder.reset()
        let mutation = Task {
            await gate.wait()
            await store.setTorrentFilesWanted(false, fileIndexes: [0], owner: owner)
        }

        await Task.yield()
        store.selectedTorrentIDs = [2]
        await gate.release()
        await mutation.value

        XCTAssertEqual(recorder.count(method: "torrent-set"), 0)
        store.disconnect()
    }

    func testDelayedTrackerCallbackFailsClosedAfterProfileChanges() async throws {
        let recorder = DetailSchedulingRequestRecorder()
        configureRPC(recorder: recorder)
        let first = ConnectionProfile(name: "First", host: "127.0.0.1")
        let second = ConnectionProfile(name: "Second", host: "127.0.0.2")
        let store = try makeStore(
            pollingCoordinator: PollingCoordinator(clock: TestPollingClock()),
            detailRefreshPolicy: TorrentDetailRefreshPolicy(prefetchPolicy: nil),
            profiles: [first, second]
        )
        await store.connect()

        store.selectedTorrentDetailPane = .trackers
        store.selectedTorrentIDs = [1]
        let trackersLoaded = await waitForDetail(store, pane: .trackers)
        XCTAssertTrue(trackersLoaded)
        let owner = try XCTUnwrap(store.selectedTorrentTrackerMutationOwner)
        let gate = DelayedDetailMutationGate()
        recorder.reset()
        let mutation = Task {
            await gate.wait()
            await store.addTorrentTracker("https://tracker.example/new", owner: owner)
        }

        await Task.yield()
        await store.switchProfile(to: second.id)
        await gate.release()
        await mutation.value

        XCTAssertEqual(recorder.count(method: "torrent-set"), 0)
        store.disconnect()
    }

    func testFilesOwnerFailsClosedAfterSnapshotRevisionChanges() async throws {
        let recorder = DetailSchedulingRequestRecorder()
        configureRPC(recorder: recorder)
        let store = try makeStore(
            pollingCoordinator: PollingCoordinator(clock: TestPollingClock()),
            detailRefreshPolicy: TorrentDetailRefreshPolicy(prefetchPolicy: nil)
        )
        await store.connect()

        store.selectedTorrentDetailPane = .files
        store.selectedTorrentIDs = [1]
        let filesLoaded = await waitForDetail(store, pane: .files)
        XCTAssertTrue(filesLoaded)
        let staleOwner = try XCTUnwrap(store.selectedTorrentFileMutationOwner)
        recorder.reset()

        configureRPC(recorder: recorder, filePath: "folder/changed.bin")

        await store.refresh()
        let refreshed = await waitForPollingCondition { recorder.detailPanes == [.files] }
        XCTAssertTrue(refreshed)
        await store.setTorrentFilesWanted(false, fileIndexes: [0], owner: staleOwner)

        XCTAssertEqual(recorder.count(method: "torrent-set"), 0)
        store.disconnect()
    }

    func testPathRenameUsesStableHashThenRefreshesRowsAndFilesAuthoritatively() async throws {
        let recorder = DetailSchedulingRequestRecorder()
        configureRPC(
            recorder: recorder,
            renamedFilePathAfterRename: "folder/renamed.bin"
        )
        let store = try makeStore(
            pollingCoordinator: PollingCoordinator(clock: TestPollingClock()),
            detailRefreshPolicy: TorrentDetailRefreshPolicy(prefetchPolicy: nil)
        )
        await store.connect()

        store.selectedTorrentDetailPane = .files
        store.selectedTorrentIDs = [1]
        let filesLoaded = await waitForDetail(store, pane: .files)
        XCTAssertTrue(filesLoaded)
        let owner = try XCTUnwrap(store.selectedTorrentPathRenameOwner)
        let fileNode = try XCTUnwrap(store.selectedTorrentDetailState.detail?.fileTree.first?.children?.first)
        recorder.reset()

        await store.renameTorrentPath(
            node: fileNode,
            newBasename: "renamed.bin",
            owner: owner
        )

        let request = try XCTUnwrap(recorder.firstRequest(method: "torrent-rename-path"))
        XCTAssertEqual(
            request.arguments["ids"],
            .array([.string("1111111111111111111111111111111111111111")])
        )
        XCTAssertEqual(request.arguments["path"], .string("folder/file.bin"))
        XCTAssertEqual(request.arguments["name"], .string("renamed.bin"))
        XCTAssertEqual(recorder.targetedListIDs, [[1]])
        XCTAssertEqual(recorder.detailPanes, [.files])
        XCTAssertEqual(
            store.selectedTorrentDetailState.detail?.files.first?.relativePath,
            "folder/renamed.bin"
        )
        store.disconnect()
    }

    func testPathRenameFailureKeepsFilesCacheAndSurfacesDaemonError() async throws {
        let recorder = DetailSchedulingRequestRecorder()
        configureRPC(
            recorder: recorder,
            renameResult: "torrent-rename-path destination already exists"
        )
        let store = try makeStore(
            pollingCoordinator: PollingCoordinator(clock: TestPollingClock()),
            detailRefreshPolicy: TorrentDetailRefreshPolicy(prefetchPolicy: nil)
        )
        await store.connect()

        store.selectedTorrentDetailPane = .files
        store.selectedTorrentIDs = [1]
        let filesLoaded = await waitForDetail(store, pane: .files)
        XCTAssertTrue(filesLoaded)
        let owner = try XCTUnwrap(store.selectedTorrentPathRenameOwner)
        let fileNode = try XCTUnwrap(store.selectedTorrentDetailState.detail?.fileTree.first?.children?.first)
        let cachedDetail = store.selectedTorrentDetailState.detail
        recorder.reset()

        await store.renameTorrentPath(
            node: fileNode,
            newBasename: "renamed.bin",
            owner: owner
        )

        XCTAssertEqual(recorder.count(method: "torrent-rename-path"), 1)
        XCTAssertTrue(recorder.targetedListIDs.isEmpty)
        XCTAssertTrue(recorder.detailPanes.isEmpty)
        XCTAssertEqual(store.selectedTorrentDetailState.detail, cachedDetail)
        XCTAssertEqual(
            store.errorMessage,
            "Transmission RPC failed: torrent-rename-path destination already exists"
        )
        store.disconnect()
    }

    func testRootFolderRenameRefreshesTorrentNameAndDescendantPaths() async throws {
        let recorder = DetailSchedulingRequestRecorder()
        configureRPC(
            recorder: recorder,
            renamedFilePathAfterRename: "renamed-folder/file.bin",
            renamedTorrentNameAfterRename: "renamed-folder"
        )
        let store = try makeStore(
            pollingCoordinator: PollingCoordinator(clock: TestPollingClock()),
            detailRefreshPolicy: TorrentDetailRefreshPolicy(prefetchPolicy: nil)
        )
        await store.connect()

        store.selectedTorrentDetailPane = .files
        store.selectedTorrentIDs = [1]
        let filesLoaded = await waitForDetail(store, pane: .files)
        XCTAssertTrue(filesLoaded)
        let owner = try XCTUnwrap(store.selectedTorrentPathRenameOwner)
        let rootFolder = try XCTUnwrap(store.selectedTorrentDetailState.detail?.fileTree.first)
        recorder.reset()

        await store.renameTorrentPath(
            node: rootFolder,
            newBasename: "renamed-folder",
            owner: owner
        )

        let request = try XCTUnwrap(recorder.firstRequest(method: "torrent-rename-path"))
        XCTAssertEqual(request.arguments["path"], .string("folder"))
        XCTAssertEqual(request.arguments["name"], .string("renamed-folder"))
        XCTAssertEqual(store.selectedTorrent?.name, "renamed-folder")
        XCTAssertEqual(
            store.selectedTorrentDetailState.detail?.files.first?.relativePath,
            "renamed-folder/file.bin"
        )
        store.disconnect()
    }

    func testPathRenameCompletionIsDiscardedAfterSelectionOwnerChanges() async throws {
        let recorder = DetailSchedulingRequestRecorder()
        let renameStarted = expectation(description: "rename request started")
        let renameStartedSignal = OneShotExpectationSignal(renameStarted)
        let releaseRename = DispatchSemaphore(value: 0)
        configureRPC(
            recorder: recorder,
            renameRequestHandler: {
                renameStartedSignal.fulfill()
                _ = releaseRename.wait(timeout: .now() + 2)
            }
        )
        let store = try makeStore(
            pollingCoordinator: PollingCoordinator(clock: TestPollingClock()),
            detailRefreshPolicy: TorrentDetailRefreshPolicy(prefetchPolicy: nil)
        )
        await store.connect()

        store.selectedTorrentDetailPane = .files
        store.selectedTorrentIDs = [1]
        let filesLoaded = await waitForDetail(store, pane: .files)
        XCTAssertTrue(filesLoaded)
        let owner = try XCTUnwrap(store.selectedTorrentPathRenameOwner)
        let fileNode = try XCTUnwrap(store.selectedTorrentDetailState.detail?.fileTree.first?.children?.first)
        recorder.reset()
        let renameTask = Task {
            await store.renameTorrentPath(
                node: fileNode,
                newBasename: "renamed.bin",
                owner: owner
            )
        }

        await fulfillment(of: [renameStarted], timeout: 1)
        store.selectedTorrentIDs = [2]
        releaseRename.signal()
        await renameTask.value

        XCTAssertEqual(recorder.count(method: "torrent-rename-path"), 1)
        XCTAssertFalse(recorder.targetedListIDs.contains([1]))
        store.disconnect()
    }

    func testPathRenameOwnerFailsClosedAfterFilesRevisionChanges() async throws {
        let recorder = DetailSchedulingRequestRecorder()
        configureRPC(recorder: recorder)
        let store = try makeStore(
            pollingCoordinator: PollingCoordinator(clock: TestPollingClock()),
            detailRefreshPolicy: TorrentDetailRefreshPolicy(prefetchPolicy: nil)
        )
        await store.connect()

        store.selectedTorrentDetailPane = .files
        store.selectedTorrentIDs = [1]
        let filesLoaded = await waitForDetail(store, pane: .files)
        XCTAssertTrue(filesLoaded)
        let staleOwner = try XCTUnwrap(store.selectedTorrentPathRenameOwner)
        let staleNode = try XCTUnwrap(store.selectedTorrentDetailState.detail?.fileTree.first?.children?.first)
        recorder.reset()

        configureRPC(recorder: recorder, filePath: "folder/changed.bin")

        await store.refresh()
        let refreshed = await waitForPollingCondition { recorder.detailPanes == [.files] }
        XCTAssertTrue(refreshed)
        recorder.reset()
        await store.renameTorrentPath(
            node: staleNode,
            newBasename: "renamed.bin",
            owner: staleOwner
        )

        XCTAssertEqual(recorder.count(method: "torrent-rename-path"), 0)
        store.disconnect()
    }

    func testPeerRefreshReusesSlowLookupAndPublishesToLatestSnapshot() async throws {
        let recorder = DetailSchedulingRequestRecorder()
        let probe = DetailPeerResolutionProbe()
        let resolver = PeerEndpointResolver(reverseDNSLookup: { await probe.lookup($0) })
        configureRPC(recorder: recorder)
        let store = try makeStore(
            pollingCoordinator: PollingCoordinator(clock: TestPollingClock()),
            detailRefreshPolicy: TorrentDetailRefreshPolicy(prefetchPolicy: nil),
            peerEndpointResolver: resolver,
            peerResolutionPreferences: PeerResolutionPreferences(
                resolveHostNames: true,
                resolveCountries: false,
                showCountryFlags: false
            )
        )
        await Task.yield()
        await store.connect()
        store.selectedTorrentDetailPane = .peers
        store.selectedTorrentIDs = [1]
        let lookupStarted = await waitForPeerResolverCondition { await probe.totalCallCount == 1 }
        XCTAssertTrue(lookupStarted)
        let firstRevision = store.selectedTorrentDetailState.detail?.peersSnapshotRevision

        for rate in 1...3 {
            configureRPC(recorder: recorder, peerRate: rate)
            await store.refresh()
        }
        XCTAssertNotEqual(store.selectedTorrentDetailState.detail?.peersSnapshotRevision, firstRevision)
        XCTAssertEqual(store.selectedTorrentDetailState.detail?.peers.first?.rateToClient, 3)
        let callCount = await probe.totalCallCount
        XCTAssertEqual(callCount, 1, "Unchanged addresses must retain their in-flight lookup")

        await probe.completeLookups()
        let didPublish = await waitForPollingCondition {
            store.selectedTorrentDetailState.detail?.peers.first?.resolvedHostName != nil
        }
        XCTAssertTrue(didPublish, "DNS must enrich the latest stats snapshot, not the first one")
        let finalCallCount = await probe.totalCallCount
        XCTAssertEqual(finalCallCount, 1)
        store.disconnect()
    }

    func testChangedPeerEndpointsRestartLookupAndRejectReplacedAddressMetadata() async throws {
        let recorder = DetailSchedulingRequestRecorder()
        let probe = DetailPeerResolutionProbe()
        let resolver = PeerEndpointResolver(reverseDNSLookup: { await probe.lookup($0) })
        configureRPC(recorder: recorder)
        let store = try makeStore(
            pollingCoordinator: PollingCoordinator(clock: TestPollingClock()),
            detailRefreshPolicy: TorrentDetailRefreshPolicy(prefetchPolicy: nil),
            peerEndpointResolver: resolver,
            peerResolutionPreferences: PeerResolutionPreferences(
                resolveHostNames: true,
                resolveCountries: false,
                showCountryFlags: false
            )
        )
        await Task.yield()
        await store.connect()
        store.selectedTorrentDetailPane = .peers
        store.selectedTorrentIDs = [1]
        let lookupStarted = await waitForPeerResolverCondition { await probe.totalCallCount == 1 }
        XCTAssertTrue(lookupStarted)

        configureRPC(recorder: recorder, peerHost: "127.0.0.3")
        await store.refresh()
        let replacementStarted = await waitForPeerResolverCondition {
            let totalCount = await probe.totalCallCount
            let activeCount = await probe.activeLookupCount
            return totalCount == 2 && activeCount == 1
        }
        XCTAssertTrue(replacementStarted)
        XCTAssertNil(store.selectedTorrentDetailState.detail?.peers.first?.resolvedHostName)
        await probe.completeLookups()
        let didPublish = await waitForPollingCondition {
            store.selectedTorrentDetailState.detail?.peers.first?.resolvedHostName
                == "host-127.0.0.3.test"
        }
        XCTAssertTrue(didPublish)
        store.disconnect()
    }

    func testPeerResolutionWorkIsCancelledOnSelectionChangeAndDisconnect() async throws {
        let recorder = DetailSchedulingRequestRecorder()
        let probe = DetailPeerResolutionProbe()
        let resolver = PeerEndpointResolver(
            configuration: PeerEndpointResolverConfiguration(
                cacheCapacity: 8,
                maximumConcurrentReverseDNSLookups: 1,
                positiveTTL: 60,
                negativeTTL: 10,
                maximumTrackedReverseDNSLookups: 2
            ),
            reverseDNSLookup: { await probe.lookup($0) },
            dateProvider: { Date(timeIntervalSince1970: 1_000) }
        )
        configureRPC(recorder: recorder)
        let store = try makeStore(
            pollingCoordinator: PollingCoordinator(clock: TestPollingClock()),
            detailRefreshPolicy: TorrentDetailRefreshPolicy(prefetchPolicy: nil),
            peerEndpointResolver: resolver,
            peerResolutionPreferences: PeerResolutionPreferences(
                resolveHostNames: true,
                resolveCountries: false,
                showCountryFlags: false
            )
        )
        await Task.yield()
        await store.connect()

        store.selectedTorrentDetailPane = .peers
        store.selectedTorrentIDs = [1]
        let firstLookupStarted = await waitForPeerResolverCondition {
            await probe.totalCallCount == 1
        }
        XCTAssertTrue(firstLookupStarted)

        store.selectedTorrentIDs = [2]
        let replacementLookupStarted = await waitForPeerResolverCondition {
            await probe.totalCallCount == 2
        }
        XCTAssertTrue(replacementLookupStarted)
        XCTAssertNil(store.selectedTorrentDetailState.detail?.peers.first?.resolvedHostName)

        store.disconnect()
        let lookupsStopped = await waitForPeerResolverCondition {
            await probe.activeLookupCount == 0
        }
        let workload = await resolver.workload()
        let cacheEntryCount = await resolver.cacheEntryCount()
        XCTAssertTrue(lookupsStopped)
        XCTAssertEqual(workload.totalAddressCount, 0)
        XCTAssertEqual(cacheEntryCount, 0)
    }

    func testPeerResolutionCacheClearCompletesBeforeFeedbackAndReschedulesCurrentSnapshot() async throws {
        let recorder = DetailSchedulingRequestRecorder()
        let probe = DetailPeerResolutionProbe()
        let resolver = PeerEndpointResolver(
            configuration: PeerEndpointResolverConfiguration(
                cacheCapacity: 8,
                maximumConcurrentReverseDNSLookups: 1,
                positiveTTL: 60,
                negativeTTL: 10,
                maximumTrackedReverseDNSLookups: 2
            ),
            reverseDNSLookup: { await probe.lookup($0) },
            dateProvider: { Date(timeIntervalSince1970: 1_000) }
        )
        configureRPC(recorder: recorder)
        let store = try makeStore(
            pollingCoordinator: PollingCoordinator(clock: TestPollingClock()),
            detailRefreshPolicy: TorrentDetailRefreshPolicy(prefetchPolicy: nil),
            peerEndpointResolver: resolver,
            peerResolutionPreferences: PeerResolutionPreferences(
                resolveHostNames: true,
                resolveCountries: false,
                showCountryFlags: false
            )
        )
        await Task.yield()
        await store.connect()

        store.selectedTorrentDetailPane = .peers
        store.selectedTorrentIDs = [1]
        let firstLookupStarted = await waitForPeerResolverCondition {
            await probe.totalCallCount == 1
        }
        XCTAssertTrue(firstLookupStarted)

        let outcome = await store.clearPeerResolutionCaches()
        let replacementLookupStarted = await waitForPeerResolverCondition {
            await probe.totalCallCount == 2
        }
        let cacheEntryCount = await resolver.cacheEntryCount()

        XCTAssertEqual(outcome, .completed)
        XCTAssertTrue(outcome.confirmsCompletion)
        XCTAssertTrue(replacementLookupStarted)
        XCTAssertEqual(cacheEntryCount, 0)
        XCTAssertNil(store.selectedTorrentDetailState.detail?.peers.first?.resolvedHostName)

        store.disconnect()
    }

    func testPeerResolutionOptOutCancelsResolverWorkWithoutPublishingLateDNS() async throws {
        let recorder = DetailSchedulingRequestRecorder()
        let probe = DetailPeerResolutionProbe()
        let resolver = PeerEndpointResolver(
            configuration: PeerEndpointResolverConfiguration(
                cacheCapacity: 8,
                maximumConcurrentReverseDNSLookups: 1,
                positiveTTL: 60,
                negativeTTL: 10,
                maximumTrackedReverseDNSLookups: 2
            ),
            reverseDNSLookup: { await probe.lookup($0) },
            dateProvider: { Date(timeIntervalSince1970: 1_000) }
        )
        configureRPC(recorder: recorder)
        let store = try makeStore(
            pollingCoordinator: PollingCoordinator(clock: TestPollingClock()),
            detailRefreshPolicy: TorrentDetailRefreshPolicy(prefetchPolicy: nil),
            peerEndpointResolver: resolver,
            peerResolutionPreferences: PeerResolutionPreferences(
                resolveHostNames: true,
                resolveCountries: false,
                showCountryFlags: false
            )
        )
        await Task.yield()
        await store.connect()

        store.selectedTorrentDetailPane = .peers
        store.selectedTorrentIDs = [1]
        let lookupStarted = await waitForPeerResolverCondition {
            await probe.totalCallCount == 1
        }
        XCTAssertTrue(lookupStarted)

        try store.peerResolutionPreferencesController.save(.defaults)
        let lookupStopped = await waitForPeerResolverCondition {
            await probe.activeLookupCount == 0
        }
        let workload = await resolver.workload()
        let cacheEntryCount = await resolver.cacheEntryCount()
        XCTAssertTrue(lookupStopped)
        XCTAssertEqual(workload.totalAddressCount, 0)
        XCTAssertEqual(cacheEntryCount, 0)
        XCTAssertNil(store.selectedTorrentDetailState.detail?.peers.first?.resolvedHostName)
        store.disconnect()
    }

    func testRolledBackPeerPreferenceDoesNotStartResolutionAfterObserverTasksDrain() async throws {
        let recorder = DetailSchedulingRequestRecorder()
        let probe = DetailPeerResolutionProbe()
        let resolver = PeerEndpointResolver(
            configuration: PeerEndpointResolverConfiguration(
                cacheCapacity: 8,
                maximumConcurrentReverseDNSLookups: 1,
                positiveTTL: 60,
                negativeTTL: 10,
                maximumTrackedReverseDNSLookups: 2
            ),
            reverseDNSLookup: { await probe.lookup($0) },
            dateProvider: { Date(timeIntervalSince1970: 1_000) }
        )
        configureRPC(recorder: recorder)
        let store = try makeStore(
            pollingCoordinator: PollingCoordinator(clock: TestPollingClock()),
            detailRefreshPolicy: TorrentDetailRefreshPolicy(prefetchPolicy: nil),
            peerEndpointResolver: resolver,
            peerResolutionPreferences: .defaults
        )
        await store.connect()
        store.selectedTorrentDetailPane = .peers
        store.selectedTorrentIDs = [1]
        let peersLoaded = await waitForDetail(store, pane: .peers)
        let initialLookupCount = await probe.totalCallCount
        XCTAssertTrue(peersLoaded)
        XCTAssertEqual(initialLookupCount, 0)

        try store.peerResolutionPreferencesController.save(
            PeerResolutionPreferences(
                resolveHostNames: true,
                resolveCountries: false,
                showCountryFlags: false
            )
        )
        try store.peerResolutionPreferencesController.save(.defaults)
        for _ in 0 ..< 5 {
            await Task.yield()
        }
        try? await Task.sleep(for: .milliseconds(20))

        let finalLookupCount = await probe.totalCallCount
        XCTAssertEqual(finalLookupCount, 0)
        XCTAssertEqual(store.peerResolutionPreferences, .defaults)
        store.disconnect()
    }

    private func makeStore(
        pollingCoordinator: PollingCoordinator,
        detailRefreshPolicy: TorrentDetailRefreshPolicy,
        profiles: [ConnectionProfile]? = nil,
        peerEndpointResolver: PeerEndpointResolver = PeerEndpointResolver(),
        peerResolutionPreferences: PeerResolutionPreferences = .defaults
    ) throws -> AppStore {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directoryURL.appendingPathComponent("profiles.json")
        let defaultsSuiteName = "AppStoreDetailSchedulingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuiteName)!
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directoryURL)
            defaults.removePersistentDomain(forName: defaultsSuiteName)
        }

        let profiles = profiles ?? [ConnectionProfile(name: "Detail scheduling", host: "127.0.0.1")]
        let profile = try XCTUnwrap(profiles.first)
        let profileStore = ConnectionProfileStore(
            fileURL: fileURL,
            passwordStore: DetailSchedulingPasswordStore()
        )
        try profileStore.save(
            ConnectionProfileCollection(profiles: profiles, selectedProfileID: profile.id)
        )
        let peerResolutionPreferencesStore = PeerResolutionPreferencesStore(
            userDefaults: defaults
        )
        try peerResolutionPreferencesStore.save(peerResolutionPreferences)
        let session = makeAppStoreMockSession()
        return AppStore(
            profileStore: profileStore,
            userDefaults: defaults,
            downloadCompletionNotifier: DetailSchedulingNotifier(),
            pollingCoordinator: pollingCoordinator,
            peerResolutionPreferencesStore: peerResolutionPreferencesStore,
            peerEndpointResolver: peerEndpointResolver,
            detailRefreshPolicy: detailRefreshPolicy,
            selectionDebounceDuration: .zero,
            clientFactory: { profile in
                TransmissionRPCClient(profile: profile, urlSession: session)
            }
        )
    }

    private func assertEveryRPCDetailPaneRejectsIdentity(returnedHash: String?) async throws {
        for pane in [
            TorrentDetailPane.overview,
            .files,
            .peers,
            .trackers,
        ] {
            let recorder = DetailSchedulingRequestRecorder()
            AppStoreMockURLProtocol.requestHandler = { request in
                let action = try request.decodedActionBody()
                recorder.record(action)
                switch action.method {
                case "session-get":
                    return rpcTestResponse(
                        body: #"{"result":"success","arguments":{"rpc-version":18,"version":"4.0","download-dir":"/downloads"}}"#
                    )
                case "torrent-get":
                    guard detailPane(action) != nil else {
                        return listResponse(torrentSize: 100)
                    }
                    let hashField = returnedHash.map { #", "hashString":"\#($0)""# } ?? ""
                    return rpcTestResponse(
                        body: #"{"result":"success","arguments":{"torrents":[{"id":1\#(hashField)}]}}"#
                    )
                default:
                    return rpcTestResponse(body: #"{"result":"success","arguments":{}}"#)
                }
            }
            let store = try makeStore(
                pollingCoordinator: PollingCoordinator(clock: TestPollingClock()),
                detailRefreshPolicy: TorrentDetailRefreshPolicy(prefetchPolicy: nil)
            )
            await store.connect()

            store.selectedTorrentDetailPane = pane
            store.selectedTorrentIDs = [1]
            let requestCompleted = await waitForPollingCondition {
                recorder.detailRequestCount(pane: pane, torrentID: 1) == 1
            }
            XCTAssertTrue(requestCompleted, "Expected a \(pane) detail request")
            await Task.yield()

            XCTAssertNil(
                store.selectedTorrentDetailState.detail,
                "A \(pane) response with an invalid identity must not publish"
            )
            XCTAssertEqual(store.selectedTorrent?.hashString, String(repeating: "1", count: 40))
            store.disconnect()
        }
    }

    private func waitForDetail(_ store: AppStore, pane: TorrentDetailPane) async -> Bool {
        await waitForPollingCondition {
            guard let detail = store.selectedTorrentDetailState.detail else { return false }
            switch pane {
            case .overview:
                return detail.generalInfo != nil
            case .files:
                return !detail.files.isEmpty
            case .peers:
                return !detail.peers.isEmpty
            case .trackers:
                return !detail.trackers.isEmpty
            case .statistics:
                return false
            }
        }
    }

    private func waitForPeerResolverCondition(
        _ condition: () async -> Bool
    ) async -> Bool {
        for _ in 0 ..< 200 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    private func configureRPC(recorder: DetailSchedulingRequestRecorder, torrentSize: Int64 = 100, renameResult: String = "success", renamedFilePathAfterRename: String? = nil, renamedTorrentNameAfterRename: String? = nil, renameRequestHandler: (() -> Void)? = nil, daemonOptionsResult: String = "success", peerHost: String = "127.0.0.2", filePath: String = "folder/file.bin", peerRate: Int = 0) {
        AppStoreMockURLProtocol.requestHandler = { request in
            let action = try request.decodedActionBody()
            recorder.record(action)
            switch action.method {
            case "session-get":
                return rpcTestResponse(
                    body: #"{"result":"success","arguments":{"rpc-version":18,"version":"4.0","download-dir":"/downloads"}}"#
                )
            case "torrent-get":
                if let pane = detailPane(action) {
                    let torrentID = detailSelectorID(action) ?? 1
                    let renamedFilePath = recorder.count(method: "torrent-rename-path") > 0
                        ? renamedFilePathAfterRename
                        : nil
                    return detailResponse(
                        pane: pane,
                        torrentID: torrentID,
                        filePath: renamedFilePath ?? filePath,
                        peerHost: peerHost,
                        peerRate: peerRate
                    )
                }
                let renamedTorrentName = recorder.count(method: "torrent-rename-path") > 0
                    ? renamedTorrentNameAfterRename
                    : nil
                return listResponse(
                    torrentSize: torrentSize,
                    torrentName: renamedTorrentName ?? "One"
                )
            case "torrent-rename-path":
                renameRequestHandler?()
                return rpcTestResponse(
                    body: #"{"result":"\#(renameResult)","arguments":{}}"#
                )
            case "session-set":
                return rpcTestResponse(
                    body: #"{"result":"\#(daemonOptionsResult)","arguments":{}}"#
                )
            default:
                return rpcTestResponse(body: #"{"result":"success","arguments":{}}"#)
            }
        }
    }
}

private final class OneShotExpectationSignal: @unchecked Sendable {
    private let lock = NSLock()
    private let expectation: XCTestExpectation
    private var hasFulfilled = false

    init(_ expectation: XCTestExpectation) {
        self.expectation = expectation
    }

    func fulfill() {
        let shouldFulfill = lock.withLock {
            guard !hasFulfilled else { return false }
            hasFulfilled = true
            return true
        }
        if shouldFulfill {
            expectation.fulfill()
        }
    }
}

private final class DaemonApplyRefreshBarrierFixture: @unchecked Sendable {
    private let lock = NSLock()
    private let sessionRefreshStarted: OneShotExpectationSignal
    private let daemonRefreshCompleted: OneShotExpectationSignal
    private let sessionRefreshGate = DispatchSemaphore(value: 0)
    private var shouldBlockSessionRefresh = false
    private var daemonOptionsWereSet = false

    init(
        sessionRefreshStarted: XCTestExpectation,
        daemonRefreshCompleted: XCTestExpectation
    ) {
        self.sessionRefreshStarted = OneShotExpectationSignal(sessionRefreshStarted)
        self.daemonRefreshCompleted = OneShotExpectationSignal(daemonRefreshCompleted)
    }

    func armSessionRefreshBarrier() {
        lock.withLock { shouldBlockSessionRefresh = true }
    }

    func releaseSessionRefresh() {
        sessionRefreshGate.signal()
    }

    func response(for action: RPCRequest) throws -> (HTTPURLResponse, Data) {
        switch action.method {
        case "session-get":
            let state = lock.withLock { () -> (shouldBlock: Bool, confirmsDaemonOptions: Bool) in
                let shouldBlock = shouldBlockSessionRefresh && !daemonOptionsWereSet
                if shouldBlock {
                    shouldBlockSessionRefresh = false
                }
                return (shouldBlock, daemonOptionsWereSet)
            }
            if state.shouldBlock {
                sessionRefreshStarted.fulfill()
                _ = sessionRefreshGate.wait(timeout: .now() + 5)
            }
            let confirmsDaemonOptions = state.confirmsDaemonOptions
            if confirmsDaemonOptions {
                daemonRefreshCompleted.fulfill()
            }
            let downloadDirectory = confirmsDaemonOptions ? "/updated" : "/downloads"
            return rpcTestResponse(
                body: #"{"result":"success","arguments":{"rpc-version":18,"version":"4.0","download-dir":"\#(downloadDirectory)"}}"#
            )
        case "session-set":
            lock.withLock { daemonOptionsWereSet = true }
            return rpcTestResponse(body: #"{"result":"success","arguments":{}}"#)
        case "torrent-get":
            return listResponse(torrentSize: 100)
        default:
            return rpcTestResponse(body: #"{"result":"success","arguments":{}}"#)
        }
    }
}

private final class DetailSchedulingRequestRecorder {
    private let lock = NSLock()
    private var requests: [RPCRequest] = []

    var listRequestCount: Int {
        lock.withLock { requests.filter(isListRequest).count }
    }

    var targetedListIDs: [[Int]] {
        lock.withLock {
            requests.filter(isListRequest).compactMap { request in
                request.arguments["ids"]?.arrayValue?.compactMap(\.intValue)
            }
        }
    }

    var detailPanes: [TorrentDetailPane] {
        lock.withLock { requests.compactMap(detailPane) }
    }

    var detailSelectorHashes: [String] {
        lock.withLock {
            requests.filter { detailPane($0) != nil }.compactMap {
                $0.arguments["ids"]?.arrayValue?.first?.stringValue
            }
        }
    }

    var torrentGetSequence: [String] {
        lock.withLock {
            requests.compactMap { request in
                guard request.method == "torrent-get" else { return nil }
                guard let pane = detailPane(request) else { return "list" }
                let torrentID = detailSelectorID(request) ?? -1
                return "detail:\(pane):\(torrentID)"
            }
        }
    }

    func record(_ request: RPCRequest) {
        lock.withLock { requests.append(request) }
    }

    func reset() {
        lock.withLock { requests = [] }
    }

    func count(method: String) -> Int {
        lock.withLock { requests.filter { $0.method == method }.count }
    }

    func detailRequestCount(pane: TorrentDetailPane, torrentID: Int) -> Int {
        lock.withLock {
            requests.filter { request in
                detailPane(request) == pane
                    && detailSelectorID(request) == torrentID
            }.count
        }
    }

    func firstRequest(method: String) -> RPCRequest? {
        lock.withLock { requests.first { $0.method == method } }
    }

    private func isListRequest(_ request: RPCRequest) -> Bool {
        guard request.method == "torrent-get" else { return false }
        let fields = Set(request.arguments["fields"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        return fields.contains("name") && fields.contains("status")
    }
}

private actor DelayedDetailMutationGate {
    private var isReleased = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            if isReleased {
                continuation.resume()
            } else {
                self.continuation = continuation
            }
        }
    }

    func release() {
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}

private actor DetailPeerResolutionProbe {
    private var callCount = 0
    private var activeCount = 0
    private var shouldComplete = false

    var totalCallCount: Int { callCount }
    var activeLookupCount: Int { activeCount }

    func completeLookups() { shouldComplete = true }

    func lookup(_ address: PeerIPAddress) async -> String? {
        callCount += 1
        activeCount += 1
        defer { activeCount -= 1 }
        do {
            while !shouldComplete {
                try await Task.sleep(for: .milliseconds(5))
            }
        } catch {
            return "cancelled-\(address.canonicalString).test"
        }
        return "host-\(address.canonicalString).test"
    }
}

private func detailPane(_ request: RPCRequest) -> TorrentDetailPane? {
    guard request.method == "torrent-get" else { return nil }
    let fields = Set(request.arguments["fields"]?.arrayValue?.compactMap(\.stringValue) ?? [])
    guard !fields.contains("name") else { return nil }
    if fields.contains("files") { return .files }
    if fields.contains("peers") { return .peers }
    if fields.contains("comment") || fields.contains("pieceCount") { return .overview }
    if fields.contains("trackerStats") { return .trackers }
    return nil
}

private func listResponse(
    torrentSize: Int64,
    torrentName: String = "One"
) -> (HTTPURLResponse, Data) {
    rpcTestResponse(
        body: #"{"result":"success","arguments":{"torrents":[{"id":1,"name":"\#(torrentName)","status":0,"percentDone":0,"totalSize":\#(torrentSize),"sizeWhenDone":\#(torrentSize),"leftUntilDone":50,"hashString":"1111111111111111111111111111111111111111","downloadDir":"/downloads"},{"id":2,"name":"Two","status":0,"percentDone":0,"totalSize":200,"sizeWhenDone":200,"leftUntilDone":100,"hashString":"2222222222222222222222222222222222222222","downloadDir":"/downloads"}]}}"#
    )
}

private func detailSelectorID(_ request: RPCRequest) -> Int? {
    guard let selector = request.arguments["ids"]?.arrayValue?.first else { return nil }
    if let id = selector.intValue { return id }
    return [1, 2].first { String(repeating: String($0), count: 40) == selector.stringValue }
}

private func detailResponse(pane: TorrentDetailPane, torrentID: Int, filePath: String = "folder/file.bin", peerHost: String = "127.0.0.2", peerRate: Int = 0) -> (HTTPURLResponse, Data) {
    let hash = torrentID == 1
        ? String(repeating: "1", count: 40)
        : String(repeating: "2", count: 40)
    let body: String
    switch pane {
    case .overview:
        body = #"{"result":"success","arguments":{"torrents":[{"id":\#(torrentID),"hashString":"\#(hash)","comment":"overview"}]}}"#
    case .files:
        body = #"{"result":"success","arguments":{"torrents":[{"id":\#(torrentID),"hashString":"\#(hash)","downloadDir":"/downloads","files":[{"name":"\#(filePath)","length":100,"bytesCompleted":50}],"fileStats":[{"bytesCompleted":50,"wanted":true,"priority":0}]}]}}"#
    case .peers:
        body = #"{"result":"success","arguments":{"torrents":[{"id":\#(torrentID),"hashString":"\#(hash)","peers":[{"address":"\#(peerHost)","port":51413,"clientName":"Peer","rateToClient":\#(peerRate)}]}]}}"#
    case .trackers:
        body = #"{"result":"success","arguments":{"torrents":[{"id":\#(torrentID),"hashString":"\#(hash)","trackers":[{"id":1,"announce":"https://tracker.example/announce"}],"trackerStats":[{"id":1,"host":"tracker.example","hasAnnounced":true,"lastAnnounceSucceeded":true}]}]}}"#
    case .statistics:
        body = #"{"result":"success","arguments":{"torrents":[]}}"#
    }
    return rpcTestResponse(body: body)
}

private final class DetailIdentityReplacementRPCFixture: @unchecked Sendable {
    static let originalHash = String(repeating: "1", count: 40)
    static let replacementHash = String(repeating: "2", count: 40)

    private let lock = NSLock()
    private let replacementStarted: OneShotExpectationSignal
    private let replacementDetailGate = DispatchSemaphore(value: 0)
    private var overviewRequestCount = 0
    private var bootstrapIDs: [[Int]] = []
    private var didReleaseReplacementDetail = false

    var targetedBootstrapIDs: [[Int]] {
        lock.withLock { bootstrapIDs }
    }

    init(replacementStarted: OneShotExpectationSignal) {
        self.replacementStarted = replacementStarted
    }

    func response(for action: RPCRequest) throws -> (HTTPURLResponse, Data) {
        switch action.method {
        case "session-get":
            return rpcTestResponse(
                body: #"{"result":"success","arguments":{"rpc-version":18,"version":"4.0","download-dir":"/downloads"}}"#
            )
        case "torrent-get":
            if detailPane(action) == .overview {
                return overviewResponse()
            }
            if action.arguments["ids"]?.stringValue == "recently-active" {
                return rpcTestResponse(body: Self.deltaResponse)
            }
            if let ids = action.arguments["ids"]?.arrayValue?.compactMap(\.intValue) {
                lock.withLock { bootstrapIDs.append(ids) }
                return rpcTestResponse(body: Self.replacementListResponse)
            }
            return rpcTestResponse(body: Self.originalListResponse)
        default:
            return rpcTestResponse(body: #"{"result":"success","arguments":{}}"#)
        }
    }

    func releaseReplacementDetail() {
        let shouldSignal = lock.withLock {
            guard !didReleaseReplacementDetail else { return false }
            didReleaseReplacementDetail = true
            return true
        }
        if shouldSignal {
            replacementDetailGate.signal()
        }
    }

    private func overviewResponse() -> (HTTPURLResponse, Data) {
        let requestCount = lock.withLock {
            overviewRequestCount += 1
            return overviewRequestCount
        }
        if requestCount >= 3 {
            replacementStarted.fulfill()
            _ = replacementDetailGate.wait(timeout: .now() + 5)
            return rpcTestResponse(body: Self.replacementDetailResponse)
        }
        return rpcTestResponse(body: Self.originalDetailResponse)
    }

    static let originalListResponse = #"{"result":"success","arguments":{"torrents":[{"id":1,"name":"Original identity","status":4,"percentDone":0.125,"totalSize":800,"sizeWhenDone":800,"leftUntilDone":700,"hashString":"1111111111111111111111111111111111111111","downloadDir":"/downloads"}]}}"#
    private static let deltaResponse = #"{"result":"success","arguments":{"torrents":[{"id":1,"hashString":"2222222222222222222222222222222222222222","rateDownload":10}]}}"#
    private static let replacementListResponse = #"{"result":"success","arguments":{"torrents":[{"id":1,"name":"Replacement identity","status":4,"percentDone":1,"totalSize":800,"sizeWhenDone":800,"leftUntilDone":0,"hashString":"2222222222222222222222222222222222222222","downloadDir":"/downloads"}]}}"#
    static let originalDetailResponse = #"{"result":"success","arguments":{"torrents":[{"id":1,"hashString":"1111111111111111111111111111111111111111","comment":"original identity","pieceCount":8,"pieceSize":100,"pieces":"gA=="}]}}"#
    static let replacementDetailResponse = #"{"result":"success","arguments":{"torrents":[{"id":1,"hashString":"2222222222222222222222222222222222222222","comment":"replacement identity","pieceCount":8,"pieceSize":100,"pieces":"/w=="}]}}"#
}

private final class DetailSchedulingPasswordStore: ConnectionPasswordStoring {
    func password(for profileID: ConnectionProfile.ID) throws -> String? { nil }
    func setPassword(_ password: String, for profileID: ConnectionProfile.ID) throws {}
    func removePassword(for profileID: ConnectionProfile.ID) throws {}
}

private final class DetailSchedulingNotifier: DownloadCompletionNotifying {
    func notifyDownloadCompleted(torrentName: String) {}
}
