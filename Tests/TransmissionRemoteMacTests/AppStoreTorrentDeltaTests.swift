// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Combine
import Foundation
import XCTest
@testable import TransmissionRemoteMac

final class AppStoreTorrentDeltaTests: XCTestCase {
    func testTorrentListRequestOwnerRejectsStaleConnectionAndFieldPlanRevision() {
        let generation = UUID()
        let owner = TorrentListRequestOwner(
            connectionGeneration: generation,
            fieldPlanRevision: 12
        )

        XCTAssertTrue(owner.isCurrent(connectionGeneration: generation, fieldPlanRevision: 12))
        XCTAssertFalse(owner.isCurrent(connectionGeneration: UUID(), fieldPlanRevision: 12))
        XCTAssertFalse(owner.isCurrent(connectionGeneration: generation, fieldPlanRevision: 11))
        XCTAssertFalse(owner.isCurrent(connectionGeneration: generation, fieldPlanRevision: nil))
    }

    func testAccumulatorMergesPartialRowsRemovesIDsAndRejectsStaleGeneration() throws {
        let generation = UUID()
        let staleGeneration = UUID()
        let now = ContinuousClock().now
        var accumulator = TorrentListDeltaAccumulator()
        accumulator.reset(for: generation)

        let fullSnapshot = TorrentListUpdate(
            mode: .fullSnapshot,
            torrents: [
                torrent(id: 2, values: ["name": .string("Two"), "totalSize": .int(200)]),
                torrent(id: 1, values: ["name": .string("One"), "totalSize": .int(100)]),
            ],
            removedIDs: []
        )
        let initial = try XCTUnwrap(accumulator.apply(
            fullSnapshot,
            connectionGeneration: generation,
            rpcVersion: 18,
            repairInterval: .seconds(600),
            now: now
        ))

        XCTAssertEqual(try fullRows(initial).map(\.id), [1, 2])
        XCTAssertEqual(accumulator.fetchMode(at: now), .recentlyActive)
        XCTAssertEqual(accumulator.fetchMode(at: now.advanced(by: .seconds(601))), .fullSnapshot)

        let delta = TorrentListUpdate(
            mode: .recentlyActive,
            torrents: [
                torrent(id: 2, values: ["rateDownload": .int(4_096)]),
                torrent(id: 3, values: ["name": .string("Three")]),
            ],
            removedIDs: [1]
        )
        let merged = try XCTUnwrap(accumulator.apply(
            delta,
            connectionGeneration: generation,
            rpcVersion: 18,
            repairInterval: .seconds(600),
            now: now
        ))

        let mergedChanges = try changes(merged)
        XCTAssertEqual(mergedChanges.upserted.map(\.id), [2, 3])
        XCTAssertEqual(mergedChanges.removedIDs, [1])
        XCTAssertEqual(mergedChanges.upserted.first?.name, "Two")
        XCTAssertEqual(mergedChanges.upserted.first?.totalSize, 200)
        XCTAssertEqual(mergedChanges.upserted.first?.rateDownload, 4_096)

        let targeted = TorrentListUpdate(
            mode: .targeted([2]),
            torrents: [torrent(id: 2, values: ["queuePosition": .int(7)])],
            removedIDs: []
        )
        let targetedMerge = try XCTUnwrap(accumulator.apply(
            targeted,
            connectionGeneration: generation,
            rpcVersion: 18,
            repairInterval: .seconds(600),
            now: now
        ))
        let targetedChanges = try changes(targetedMerge)
        XCTAssertEqual(targetedChanges.upserted.map(\.id), [2])
        XCTAssertTrue(targetedChanges.removedIDs.isEmpty)
        XCTAssertEqual(targetedChanges.upserted.first?.name, "Two")
        XCTAssertEqual(targetedChanges.upserted.first?.queuePosition, 7)

        XCTAssertNil(accumulator.apply(
            delta,
            connectionGeneration: staleGeneration,
            rpcVersion: 18,
            repairInterval: .seconds(600),
            now: now
        ))
    }

    func testTargetedEmptyAndPartialResponsesRemoveEveryMissingRequestedID() throws {
        let generation = UUID()
        let now = ContinuousClock().now
        var accumulator = TorrentListDeltaAccumulator()
        accumulator.reset(for: generation)

        _ = try XCTUnwrap(accumulator.apply(
            TorrentListUpdate(
                mode: .fullSnapshot,
                torrents: [1, 2, 3, 4].map { torrent(id: $0, values: ["name": .string("Torrent \($0)")]) },
                removedIDs: []
            ),
            connectionGeneration: generation,
            rpcVersion: 18,
            repairInterval: .seconds(600),
            now: now
        ))

        let partial = try XCTUnwrap(accumulator.apply(
            TorrentListUpdate(
                mode: .targeted([1, 2, 3]),
                torrents: [torrent(id: 2, values: ["rateDownload": .int(42)])],
                removedIDs: []
            ),
            connectionGeneration: generation,
            rpcVersion: 18,
            repairInterval: .seconds(600),
            now: now
        ))
        let partialChanges = try changes(partial)
        XCTAssertEqual(partialChanges.upserted.map(\.id), [2])
        XCTAssertEqual(partialChanges.removedIDs, [1, 3])

        let empty = try XCTUnwrap(accumulator.apply(
            TorrentListUpdate(mode: .targeted([2, 4]), torrents: [], removedIDs: []),
            connectionGeneration: generation,
            rpcVersion: 18,
            repairInterval: .seconds(600),
            now: now
        ))
        let emptyChanges = try changes(empty)
        XCTAssertTrue(emptyChanges.upserted.isEmpty)
        XCTAssertEqual(emptyChanges.removedIDs, [2, 4])
    }

    func testRecentlyActiveBootstrapIDsContainUnknownOrUnprovenIdentities() throws {
        let generation = UUID()
        var accumulator = TorrentListDeltaAccumulator()
        accumulator.reset(for: generation)
        _ = try XCTUnwrap(accumulator.apply(
            TorrentListUpdate(
                mode: .fullSnapshot,
                torrents: [
                    torrent(id: 1, values: ["name": .string("Known")]),
                    torrent(id: 4, values: ["name": .string("Reused ID")]),
                ],
                removedIDs: []
            ),
            connectionGeneration: generation,
            rpcVersion: 18,
            repairInterval: .seconds(600)
        ))

        let delta = TorrentListUpdate(
            mode: .recentlyActive,
            torrents: [
                torrent(id: 1, values: ["rateDownload": .int(1)]),
                torrent(id: 2, values: ["rateDownload": .int(2)]),
                torrent(id: 2, values: ["rateDownload": .int(3)]),
                torrent(id: 3, values: ["rateDownload": .int(4)]),
                torrent(id: 0, values: ["rateDownload": .int(5)]),
                torrent(id: 4, values: [
                    "hashString": .string(canonicalTestTorrentHash(4, identity: 1)),
                ]),
            ],
            removedIDs: [3, -1]
        )

        XCTAssertEqual(accumulator.bootstrapIDs(for: delta), [2, 4])
        XCTAssertTrue(accumulator.bootstrapIDs(for: TorrentListUpdate(
            mode: .targeted([2]),
            torrents: delta.torrents,
            removedIDs: []
        )).isEmpty)
    }

    func testHashReplacementBootstrapsCompleteRowWithoutLeakingPriorStaticState() throws {
        let generation = UUID()
        var accumulator = TorrentListDeltaAccumulator()
        accumulator.reset(for: generation)
        _ = try XCTUnwrap(accumulator.apply(
            TorrentListUpdate(
                mode: .fullSnapshot,
                torrents: [torrent(id: 1, values: [
                    "name": .string("Old identity"),
                    "downloadDir": .string("/old/path"),
                    "labels": .array([.string("old-label")]),
                ])],
                removedIDs: []
            ),
            connectionGeneration: generation,
            rpcVersion: 18,
            repairInterval: .seconds(600)
        ))

        let replacementHash = canonicalTestTorrentHash(1, identity: 1)
        let delta = TorrentListUpdate(
            mode: .recentlyActive,
            torrents: [torrent(id: 1, values: [
                "hashString": .string(replacementHash),
                "rateDownload": .int(500),
            ])],
            removedIDs: [],
            fieldPlanRevision: 2
        )
        XCTAssertEqual(accumulator.bootstrapIDs(for: delta), [1])

        let bootstrap = TorrentListUpdate(
            mode: .targeted([1]),
            torrents: [torrent(id: 1, values: [
                "hashString": .string(replacementHash),
                "name": .string("New identity"),
                "downloadDir": .string("/new/path"),
                "labels": .array([]),
                "rateDownload": .int(600),
            ])],
            removedIDs: [],
            fieldPlanRevision: 2
        )
        let completed = try XCTUnwrap(delta.mergingBootstrap(bootstrap, requestedIDs: [1]))
        let applied = try XCTUnwrap(accumulator.apply(
            completed,
            connectionGeneration: generation,
            rpcVersion: 18,
            repairInterval: .seconds(600)
        ))
        let replacement = try XCTUnwrap(try changes(applied).upserted.first)

        XCTAssertEqual(replacement.hashString, replacementHash)
        XCTAssertEqual(replacement.name, "New identity")
        XCTAssertEqual(replacement.downloadDir, "/new/path")
        XCTAssertEqual(replacement.labels, [])
        XCTAssertEqual(replacement.rateDownload, 600)
    }

    func testMissingDeltaHashRejectsPublicationAndForcesFullRepair() throws {
        let generation = UUID()
        let now = ContinuousClock().now
        var accumulator = TorrentListDeltaAccumulator()
        accumulator.reset(for: generation)
        _ = try XCTUnwrap(accumulator.apply(
            TorrentListUpdate(
                mode: .fullSnapshot,
                torrents: [torrent(id: 1, values: ["name": .string("Known")])],
                removedIDs: []
            ),
            connectionGeneration: generation,
            rpcVersion: 18,
            repairInterval: .seconds(600),
            now: now
        ))

        XCTAssertNil(accumulator.apply(
            TorrentListUpdate(
                mode: .recentlyActive,
                torrents: [TorrentGetTorrent(json: [
                    "id": .int(1),
                    "rateDownload": .int(500),
                ])],
                removedIDs: []
            ),
            connectionGeneration: generation,
            rpcVersion: 18,
            repairInterval: .seconds(600),
            now: now
        ))
        XCTAssertEqual(accumulator.fetchMode(at: now), .fullSnapshot)
    }

    func testBootstrapMergeCompletesNewRowsAndPreservesDeltaRemovals() throws {
        let delta = TorrentListUpdate(
            mode: .recentlyActive,
            torrents: [
                torrent(id: 1, values: ["rateDownload": .int(100)]),
                torrent(id: 2, values: ["rateDownload": .int(200)]),
                torrent(id: 3, values: ["rateDownload": .int(300)]),
            ],
            removedIDs: [4],
            fieldPlanRevision: 8
        )
        let bootstrap = TorrentListUpdate(
            mode: .targeted([2, 3]),
            torrents: [
                torrent(id: 2, values: [
                    "name": .string("New Two"),
                    "downloadDir": .string("/complete"),
                    "totalSize": .int(2_000),
                    "rateDownload": .int(250),
                ]),
            ],
            removedIDs: [],
            fieldPlanRevision: 8
        )

        let merged = try XCTUnwrap(delta.mergingBootstrap(bootstrap, requestedIDs: [3, 2, 2, -1]))
        XCTAssertEqual(merged.mode, .recentlyActive)
        XCTAssertEqual(merged.removedIDs, [3, 4])
        XCTAssertEqual(merged.torrents.map(\.id), [1, 2])
        let completed = try XCTUnwrap(merged.torrents.first { $0.id == 2 })
        XCTAssertEqual(completed.name, "New Two")
        XCTAssertEqual(completed.json["downloadDir"], .string("/complete"))
        XCTAssertEqual(completed.json["totalSize"], .int(2_000))
        XCTAssertEqual(completed.json["rateDownload"], .int(250))
        XCTAssertEqual(merged.fieldPlanRevision, 8)
    }

    func testBootstrapMergeRejectsWrongRequestOrFieldPlanOwnership() {
        let delta = TorrentListUpdate(
            mode: .recentlyActive,
            torrents: [torrent(id: 2, values: ["rateDownload": .int(1)])],
            removedIDs: [],
            fieldPlanRevision: 4
        )
        let staleBootstrap = TorrentListUpdate(
            mode: .targeted([2]),
            torrents: [torrent(id: 2, values: ["name": .string("Two")])],
            removedIDs: [],
            fieldPlanRevision: 3
        )
        let wrongRequest = TorrentListUpdate(
            mode: .targeted([3]),
            torrents: [torrent(id: 3, values: ["name": .string("Three")])],
            removedIDs: [],
            fieldPlanRevision: 4
        )

        XCTAssertNil(delta.mergingBootstrap(staleBootstrap, requestedIDs: [2]))
        XCTAssertNil(delta.mergingBootstrap(wrongRequest, requestedIDs: [2]))

        let mismatchedIdentity = TorrentListUpdate(
            mode: .targeted([2]),
            torrents: [torrent(id: 2, values: [
                "hashString": .string(canonicalTestTorrentHash(2, identity: 1)),
            ])],
            removedIDs: [],
            fieldPlanRevision: 4
        )
        XCTAssertNil(delta.mergingBootstrap(mismatchedIdentity, requestedIDs: [2]))
    }

    private func fullRows(_ result: TorrentListApplyResult) throws -> [TorrentSummary] {
        guard case .full(let rows) = result else {
            throw UnexpectedTorrentListApplyResult()
        }
        return rows
    }

    private func changes(
        _ result: TorrentListApplyResult
    ) throws -> (upserted: [TorrentSummary], removedIDs: [Int]) {
        guard case .changes(let upserted, let removedIDs) = result else {
            throw UnexpectedTorrentListApplyResult()
        }
        return (upserted, removedIDs)
    }

    private func torrent(id: Int, values: RPCArguments) -> TorrentGetTorrent {
        var json = values
        json["id"] = .int(id)
        if json["hashString"] == nil {
            json["hashString"] = .string(canonicalTestTorrentHash(id))
        }
        return TorrentGetTorrent(json: json)
    }
}

private struct UnexpectedTorrentListApplyResult: Error {}

@MainActor
final class AppStoreIncrementalTorrentPublicationTests: XCTestCase {
    override func tearDown() {
        AppStoreMockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testOneChangedRowUsesIncrementalAppStorePublicationPath() async throws {
        let clock = TestPollingClock()
        let responses = IncrementalListResponseSequence(
            fullRows: makeListRows(count: 1_000),
            incrementalRows: [[
                "id": 500,
                "hashString": canonicalTestTorrentHash(500),
                "rateDownload": 9_999,
            ]]
        )
        configureIncrementalRPC(responses)
        let store = try makeIncrementalStore(clock: clock)
        await store.connect()
        let initialRevision = store.torrentListMaterializationRevision

        XCTAssertEqual(store.torrents.count, 1_000)
        let initialSnapshotMaterializationCount = store.torrentSnapshotMaterializationCount
        XCTAssertEqual(store.torrentListUpdateMetrics.mappedRowCount, 1_000)
        let firstDeadlineScheduled = await waitForPollingCondition { clock.pendingSleepCount == 1 }
        XCTAssertTrue(firstDeadlineScheduled)
        clock.advance(by: .seconds(5))
        let incrementalPublished = await waitForPollingCondition {
            !store.torrentListUpdateMetrics.isFullSnapshot
                && store.torrentListUpdateMetrics.mappedRowCount == 1
        }
        XCTAssertTrue(incrementalPublished)

        XCTAssertEqual(store.torrentListUpdateMetrics.projectionEvaluatedRowCount, 1)
        XCTAssertEqual(store.torrentListUpdateMetrics.authoritativeRowMutationCount, 1)
        XCTAssertEqual(store.torrentListUpdateMetrics.visibleIndexRebuildCount, 1)
        XCTAssertEqual(store.torrentListUpdateMetrics.sourceIndexRebuildCount, 0)
        XCTAssertEqual(store.torrentListUpdateMetrics.publishedDerivedValueCount, 1)
        XCTAssertEqual(store.torrentSnapshotMaterializationCount, initialSnapshotMaterializationCount)
        XCTAssertEqual(store.torrentListMaterializationRevision, initialRevision + 1)
        XCTAssertEqual(store.torrents.count, 1_000)
        XCTAssertEqual(store.visibleTorrents.count, 1_000)
        XCTAssertEqual(store.torrents.first { $0.id == 500 }?.rateDownload, 9_999)
        XCTAssertEqual(store.filterCounts.statuses[.all], 1_000)
        store.disconnect()
    }

    func testEmptyThousandRowDeltaDoesNotRepublishMaterializedList() async throws {
        let clock = TestPollingClock()
        let responses = IncrementalListResponseSequence(
            fullRows: makeListRows(count: 1_000),
            incrementalRows: []
        )
        configureIncrementalRPC(responses)
        let store = try makeIncrementalStore(clock: clock)
        await store.connect()
        XCTAssertEqual(store.torrentOperationReconciliationSnapshotCount, 0)
        let initialRevision = store.torrentListMaterializationRevision
        let initialSnapshotMaterializationCount = store.torrentSnapshotMaterializationCount
        let initialVisibleIDs = store.visibleTorrents.map(\.id)
        let initialSessionInfo = store.sessionInfo
        let initialSessionStats = store.sessionStats
        let initialConnectionState = store.connectionState
        var idlePublicationCount = 0
        let observation = store.objectWillChange.sink {
            idlePublicationCount += 1
        }

        let firstDeadlineScheduled = await waitForPollingCondition { clock.pendingSleepCount == 1 }
        XCTAssertTrue(firstDeadlineScheduled)
        clock.advance(by: .seconds(5))
        let idleMetricsPublished = await waitForPollingCondition {
            !store.torrentListUpdateMetrics.isFullSnapshot
        }
        XCTAssertTrue(idleMetricsPublished)

        XCTAssertEqual(store.torrentListUpdateMetrics.mappedRowCount, 0)
        XCTAssertEqual(store.torrentListUpdateMetrics.projectionEvaluatedRowCount, 0)
        XCTAssertEqual(store.torrentListUpdateMetrics.authoritativeRowMutationCount, 0)
        XCTAssertEqual(store.torrentListUpdateMetrics.visibleIndexRebuildCount, 0)
        XCTAssertEqual(store.torrentListUpdateMetrics.sourceIndexRebuildCount, 0)
        XCTAssertEqual(store.torrentListUpdateMetrics.publishedDerivedValueCount, 0)
        XCTAssertEqual(store.torrentSnapshotMaterializationCount, initialSnapshotMaterializationCount)
        XCTAssertEqual(store.torrentOperationReconciliationSnapshotCount, 0)
        XCTAssertEqual(store.torrentListMaterializationRevision, initialRevision)
        XCTAssertEqual(store.visibleTorrents.map(\.id), initialVisibleIDs)
        XCTAssertEqual(store.torrents.count, 1_000)
        XCTAssertEqual(idlePublicationCount, 0)

        let nextDeadlineScheduled = await waitForPollingCondition { clock.pendingSleepCount == 1 }
        XCTAssertTrue(nextDeadlineScheduled)
        clock.advance(by: .seconds(20))
        let idleHealthPollCompleted = await waitForPollingCondition {
            responses.incrementalRequestCount >= 2 && responses.sessionRequestCount >= 2
        }
        XCTAssertTrue(idleHealthPollCompleted)
        await Task.yield()
        await Task.yield()
        XCTAssertEqual(idlePublicationCount, 0)
        XCTAssertEqual(store.torrentListMaterializationRevision, initialRevision)
        XCTAssertEqual(store.sessionInfo, initialSessionInfo)
        XCTAssertEqual(store.sessionStats, initialSessionStats)
        XCTAssertEqual(store.connectionState, initialConnectionState)
        withExtendedLifetime(observation) {}
        store.disconnect()
    }

    func testChangedFilteredOutRowMutatesIndexWithoutPublishingDerivedListState() async throws {
        let clock = TestPollingClock()
        let responses = IncrementalListResponseSequence(
            fullRows: makeListRows(count: 1_000),
            incrementalRows: [[
                "id": 500,
                "hashString": canonicalTestTorrentHash(500),
                "rateDownload": 9_999,
            ]]
        )
        configureIncrementalRPC(responses)
        let store = try makeIncrementalStore(clock: clock)
        await store.connect()
        store.filterText = "does-not-match-any-torrent"
        let initialRevision = store.torrentListMaterializationRevision
        let initialSnapshotMaterializationCount = store.torrentSnapshotMaterializationCount

        let firstDeadlineScheduled = await waitForPollingCondition { clock.pendingSleepCount == 1 }
        XCTAssertTrue(firstDeadlineScheduled)
        clock.advance(by: .seconds(5))
        let incrementalApplied = await waitForPollingCondition {
            !store.torrentListUpdateMetrics.isFullSnapshot
                && store.torrentListUpdateMetrics.authoritativeRowMutationCount == 1
        }
        XCTAssertTrue(incrementalApplied)

        XCTAssertTrue(store.visibleTorrents.isEmpty)
        XCTAssertEqual(store.torrentListUpdateMetrics.projectionEvaluatedRowCount, 1)
        XCTAssertEqual(store.torrentListUpdateMetrics.visibleIndexRebuildCount, 0)
        XCTAssertEqual(store.torrentListUpdateMetrics.sourceIndexRebuildCount, 0)
        XCTAssertEqual(store.torrentListUpdateMetrics.publishedDerivedValueCount, 0)
        XCTAssertEqual(store.torrentListMaterializationRevision, initialRevision)
        XCTAssertEqual(store.torrentSnapshotMaterializationCount, initialSnapshotMaterializationCount)
        XCTAssertEqual(store.torrents.first { $0.id == 500 }?.rateDownload, 9_999)
        store.disconnect()
    }

    func testRecentlyActiveUnknownIDsUseOneBatchedTargetedBootstrapWithoutFullRepair() async throws {
        let clock = TestPollingClock()
        let responses = BootstrapListResponseSequence()
        AppStoreMockURLProtocol.requestHandler = { request in
            let action = try request.decodedActionBody()
            switch action.method {
            case "session-get":
                return rpcTestResponse(
                    body: #"{"result":"success","arguments":{"rpc-version":18,"version":"4.0","download-dir":"/downloads"}}"#
                )
            case "torrent-get":
                if action.arguments["ids"]?.stringValue == "recently-active" {
                    return rpcTestResponse(body: responses.deltaResponse())
                }
                if let ids = action.arguments["ids"]?.arrayValue?.compactMap(\.intValue) {
                    return rpcTestResponse(body: responses.bootstrapResponse(ids: ids))
                }
                return rpcTestResponse(body: responses.fullResponse())
            default:
                return rpcTestResponse(body: #"{"result":"success","arguments":{}}"#)
            }
        }
        let store = try makeIncrementalStore(clock: clock)

        await store.connect()
        XCTAssertEqual(store.visibleTorrents.map(\.id), [1])

        let firstDeadlineScheduled = await waitForPollingCondition { clock.pendingSleepCount == 1 }
        XCTAssertTrue(firstDeadlineScheduled)
        clock.advance(by: .seconds(5))
        let bootstrapped = await waitForPollingCondition {
            Set(store.visibleTorrents.map(\.id)) == Set([1, 2, 3])
                && responses.targetedRequestCount == 1
        }
        XCTAssertTrue(bootstrapped)
        XCTAssertEqual(responses.targetedIDs, [[2, 3]])
        XCTAssertEqual(responses.fullRequestCount, 1)
        XCTAssertEqual(store.visibleTorrents.first { $0.id == 2 }?.downloadDir, "/new/two")
        XCTAssertEqual(store.visibleTorrents.first { $0.id == 2 }?.totalSize, 2_000)
        XCTAssertEqual(store.visibleTorrents.first { $0.id == 3 }?.downloadDir, "/new/three")

        let nextDeadlineScheduled = await waitForPollingCondition { clock.pendingSleepCount == 1 }
        XCTAssertTrue(nextDeadlineScheduled)
        clock.advance(by: .seconds(5))
        let secondDeltaCompleted = await waitForPollingCondition { responses.deltaRequestCount >= 2 }
        XCTAssertTrue(secondDeltaCompleted)
        XCTAssertEqual(responses.targetedRequestCount, 1)
        XCTAssertEqual(responses.fullRequestCount, 1)
        store.disconnect()
    }

    private func configureIncrementalRPC(_ responses: IncrementalListResponseSequence) {
        AppStoreMockURLProtocol.requestHandler = { request in
            let action = try request.decodedActionBody()
            switch action.method {
            case "session-get":
                responses.recordSessionRequest()
                return rpcTestResponse(
                    body: #"{"result":"success","arguments":{"rpc-version":18,"version":"4.0","download-dir":"/downloads"}}"#
                )
            case "torrent-get":
                if action.arguments["ids"]?.stringValue == "recently-active" {
                    return rpcTestResponse(body: responses.incrementalResponse())
                }
                return rpcTestResponse(body: responses.fullResponse())
            default:
                return rpcTestResponse(body: #"{"result":"success","arguments":{}}"#)
            }
        }
    }

    private func makeIncrementalStore(clock: TestPollingClock) throws -> AppStore {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directoryURL.appendingPathComponent("profiles.json")
        let defaultsSuiteName = "AppStoreIncrementalTorrentPublicationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuiteName))
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directoryURL)
            defaults.removePersistentDomain(forName: defaultsSuiteName)
        }

        let profile = ConnectionProfile(name: "Incremental", host: "127.0.0.1")
        let profileStore = ConnectionProfileStore(
            fileURL: fileURL,
            passwordStore: IncrementalListPasswordStore()
        )
        try profileStore.save(
            ConnectionProfileCollection(profiles: [profile], selectedProfileID: profile.id)
        )
        let session = makeAppStoreMockSession()
        return AppStore(
            profileStore: profileStore,
            userDefaults: defaults,
            downloadCompletionNotifier: IncrementalListNotifier(),
            pollingCoordinator: PollingCoordinator(clock: clock),
            detailRefreshPolicy: TorrentDetailRefreshPolicy(prefetchPolicy: nil),
            selectionDebounceDuration: .zero,
            clientFactory: { profile in
                TransmissionRPCClient(profile: profile, urlSession: session)
            }
        )
    }

    private func makeListRows(count: Int) -> [[String: Any]] {
        (1...count).map { id in
            [
                "id": id,
                "name": String(format: "Torrent %04d", id),
                "status": TorrentStatus.downloading.rawValue,
                "percentDone": 0.5,
                "totalSize": id * 1_024,
                "sizeWhenDone": id * 1_024,
                "leftUntilDone": id * 512,
                "rateDownload": id,
                "hashString": canonicalTestTorrentHash(id),
                "downloadDir": "/downloads",
            ]
        }
    }
}

private final class IncrementalListResponseSequence {
    private let lock = NSLock()
    private let fullRows: [[String: Any]]
    private let incrementalRows: [[String: Any]]
    private var incrementalRequests = 0
    private var sessionRequests = 0

    var incrementalRequestCount: Int {
        lock.withLock { incrementalRequests }
    }

    var sessionRequestCount: Int {
        lock.withLock { sessionRequests }
    }

    init(fullRows: [[String: Any]], incrementalRows: [[String: Any]]) {
        self.fullRows = fullRows
        self.incrementalRows = incrementalRows
    }

    func fullResponse() -> String {
        response(torrents: fullRows)
    }

    func incrementalResponse() -> String {
        lock.withLock {
            incrementalRequests += 1
            return response(torrents: incrementalRows)
        }
    }

    func recordSessionRequest() {
        lock.withLock {
            sessionRequests += 1
        }
    }

    private func response(torrents: [[String: Any]]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [
            "result": "success",
            "arguments": ["torrents": torrents],
        ])
        return String(decoding: data, as: UTF8.self)
    }
}

private final class BootstrapListResponseSequence {
    private let lock = NSLock()
    private var fullRequests = 0
    private var deltaRequests = 0
    private var targetedRequests: [[Int]] = []

    var fullRequestCount: Int { lock.withLock { fullRequests } }
    var deltaRequestCount: Int { lock.withLock { deltaRequests } }
    var targetedRequestCount: Int { lock.withLock { targetedRequests.count } }
    var targetedIDs: [[Int]] { lock.withLock { targetedRequests } }

    func fullResponse() -> String {
        lock.withLock { fullRequests += 1 }
        return response(torrents: [[
            "id": 1,
            "name": "Known",
            "hashString": canonicalTestTorrentHash(1),
            "status": TorrentStatus.downloading.rawValue,
            "downloadDir": "/known",
            "totalSize": 1_000,
        ]])
    }

    func deltaResponse() -> String {
        lock.withLock { deltaRequests += 1 }
        return response(torrents: [
            ["id": 1, "hashString": canonicalTestTorrentHash(1), "rateDownload": 10],
            ["id": 2, "hashString": canonicalTestTorrentHash(2), "rateDownload": 20],
            ["id": 3, "hashString": canonicalTestTorrentHash(3), "rateDownload": 30],
        ])
    }

    func bootstrapResponse(ids: [Int]) -> String {
        lock.withLock { targetedRequests.append(ids) }
        let rows: [[String: Any]] = ids.compactMap { id in
            switch id {
            case 2:
                [
                    "id": 2,
                    "name": "New Two",
                    "hashString": canonicalTestTorrentHash(2),
                    "status": TorrentStatus.downloading.rawValue,
                    "downloadDir": "/new/two",
                    "totalSize": 2_000,
                ]
            case 3:
                [
                    "id": 3,
                    "name": "New Three",
                    "hashString": canonicalTestTorrentHash(3),
                    "status": TorrentStatus.downloading.rawValue,
                    "downloadDir": "/new/three",
                    "totalSize": 3_000,
                ]
            default:
                nil
            }
        }
        return response(torrents: rows)
    }

    private func response(torrents: [[String: Any]]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [
            "result": "success",
            "arguments": ["torrents": torrents],
        ])
        return String(decoding: data, as: UTF8.self)
    }
}

private func canonicalTestTorrentHash(_ id: Int, identity: Int = 0) -> String {
    String(format: "%040llx", Int64(identity) * 1_000_000 + Int64(id))
}

private final class IncrementalListPasswordStore: ConnectionPasswordStoring {
    func password(for profileID: ConnectionProfile.ID) throws -> String? { nil }
    func setPassword(_ password: String, for profileID: ConnectionProfile.ID) throws {}
    func removePassword(for profileID: ConnectionProfile.ID) throws {}
}

private final class IncrementalListNotifier: DownloadCompletionNotifying {
    func notifyDownloadCompleted(torrentName: String) {}
}
