// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Darwin
import Foundation
import XCTest
@testable import TransmissionRemoteMac

final class RPCPerformanceContractTests: XCTestCase {
    override func tearDown() {
        PerformanceContractURLProtocol.install(nil)
        super.tearDown()
    }

    func testSemanticRequestCountsOneApplicationCallAcrossSessionChallengeRetry() async throws {
        let diagnostics = RPCDiagnostics(capacity: 8)
        let recorder = PerformanceRequestRecorder()
        PerformanceContractURLProtocol.install { request in
            let requestNumber = recorder.record(request)
            if requestNumber == 1 {
                return performanceResponse(
                    statusCode: 409,
                    headers: ["X-Transmission-Session-Id": "performance-session"]
                )
            }
            return performanceResponse(
                body: #"{"result":"success","arguments":{"rpc-version":18,"version":"4.0"}}"#
            )
        }
        let client = TransmissionRPCClient(
            profile: .localDefault,
            urlSession: makePerformanceSession(),
            diagnostics: diagnostics
        )

        let session = try await client.getSession()
        let snapshot = diagnostics.snapshot()
        let event = try XCTUnwrap(snapshot.events.only)

        XCTAssertEqual(session.rpcVersion, 18)
        XCTAssertEqual(recorder.requestCount, 2)
        XCTAssertEqual(snapshot.applicationRequestCount, 1)
        XCTAssertEqual(snapshot.httpAttemptCount, 2)
        XCTAssertEqual(snapshot.sessionChallengeRetryCount, 1)
        XCTAssertEqual(event.applicationRequestCount, 1)
        XCTAssertEqual(event.httpAttemptCount, 2)
        XCTAssertEqual(event.sessionChallengeRetryCount, 1)
        XCTAssertEqual(event.method, .sessionGet)
        XCTAssertGreaterThan(event.requestBytes, 0)
        XCTAssertGreaterThan(event.responseBytes, 0)
    }

    func testScaleResponsesReportExactPayloadFieldAndRowMetrics() async throws {
        let diagnostics = RPCDiagnostics(capacity: 8)
        let router = PerformanceScaleResponseRouter(rowCounts: [0, 100, 1_000])
        PerformanceContractURLProtocol.install { request in
            try router.response(for: request)
        }
        let client = TransmissionRPCClient(
            profile: .localDefault,
            urlSession: makePerformanceSession(),
            diagnostics: diagnostics
        )

        _ = try await client.getSession()
        for expectedCount in [0, 100, 1_000] {
            let response = try await client.getTorrents()
            XCTAssertEqual(response.torrents.count, expectedCount)
        }

        let snapshot = diagnostics.snapshot()
        let events = snapshot.events.filter { $0.method == .torrentGet }
        let requests = router.torrentRequests

        XCTAssertEqual(snapshot.applicationRequestCount, 4)
        XCTAssertEqual(snapshot.httpAttemptCount, 4)
        XCTAssertEqual(events.map(\.returnedTorrentRows), [0, 100, 1_000].map { Optional($0) })
        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(events.map(\.requestedFieldCount), requests.map(\.fieldCount))
        let requestedFieldCount = try XCTUnwrap(requests.first?.fieldCount)
        XCTAssertGreaterThan(requestedFieldCount, 0)
        XCTAssertLessThanOrEqual(requestedFieldCount, 40)
        XCTAssertTrue(events.allSatisfy { $0.requestedFieldCount == requestedFieldCount })
        XCTAssertTrue(requests.allSatisfy { $0.fields == Array(Set($0.fields)).sorted() })
        let requestBodyBytes = try XCTUnwrap(requests.first?.bodyBytes)
        XCTAssertEqual(events.map(\.requestBytes), Array(repeating: requestBodyBytes, count: 3))
        XCTAssertTrue(events.allSatisfy { $0.requestBytes < 4_096 })
        XCTAssertEqual(events.map(\.responseBytes), router.responseByteCounts)
        XCTAssertTrue(router.responseRowsCoverEveryRequestedField)
        XCTAssertLessThan(events[0].responseBytes, events[1].responseBytes)
        XCTAssertLessThan(events[1].responseBytes, events[2].responseBytes)
        XCTAssertGreaterThan(events[2].responseBytes, 256 * 1_024)
        XCTAssertLessThan(events[2].responseBytes, 4 * 1_024 * 1_024)
        XCTAssertTrue(events.allSatisfy {
            $0.durationMilliseconds >= 0 && $0.durationMilliseconds <= 5_000
        })
    }

    func testWireRowCountingCoversObjectAndBothTableShapesWithoutMaterializingDTOs() {
        XCTAssertEqual(TorrentGetResponse.wireRowCount(in: [
            "torrents": .array([.object(["id": .int(1)]), .object(["id": .int(2)])]),
        ]), 2)
        XCTAssertEqual(TorrentGetResponse.wireRowCount(in: [
            "fields": .array([.string("id")]),
            "torrents": .array([.object(["id": .int(1)])]),
        ]), 1)
        XCTAssertEqual(TorrentGetResponse.wireRowCount(in: [
            "fields": .array([.string("id"), .string("name")]),
            "data": .array([
                .array([.int(1), .string("one")]),
                .array([.int(2), .string("two")]),
            ]),
        ]), 2)
        XCTAssertEqual(TorrentGetResponse.wireRowCount(in: [
            "torrents": .array([
                .array([.string("id"), .string("name")]),
                .array([.int(1), .string("one")]),
            ]),
        ]), 1)
        XCTAssertEqual(TorrentGetResponse.wireRowCount(in: [
            "fields": .array([.string("id"), .string("name")]),
            "data": .array([.array([.int(1)])]),
        ]), 0)
    }
}

@MainActor
final class PollingPerformanceContractTests: XCTestCase {
    override func tearDown() {
        PerformanceContractURLProtocol.install(nil)
        super.tearDown()
    }

    func testConcurrentRefreshPressureCoalescesWithoutOverlappingListRequests() async throws {
        let gate = PerformanceListRequestGate()
        PerformanceContractURLProtocol.install { request in
            let action = try request.performanceRPCBody()
            if action.method == "torrent-get" {
                gate.waitIfBlocked()
            }
            return performanceAppStoreResponse(for: action.method)
        }
        let store = try makePerformanceStore()

        await store.start()
        let initialListCount = gate.acceptedRequestCount
        XCTAssertEqual(initialListCount, 1)
        gate.block()

        let firstRefresh = Task { @MainActor in await store.refresh() }
        let firstRequestStarted = await waitForPerformanceCondition {
            gate.acceptedRequestCount == initialListCount + 1 && gate.inFlightRequestCount == 1
        }
        XCTAssertTrue(firstRequestStarted)

        let queuedRefreshCompletions = PerformanceCompletionCounter()
        let queuedRefreshes = (0..<12).map { _ in
            Task { @MainActor in
                await store.refresh()
                queuedRefreshCompletions.record()
            }
        }
        let queuedRefreshesSettled = await waitForPerformanceCondition {
            queuedRefreshCompletions.count == queuedRefreshes.count
        }

        XCTAssertTrue(queuedRefreshesSettled)
        XCTAssertEqual(gate.inFlightRequestCount, 1)
        XCTAssertEqual(gate.maximumInFlightRequestCount, 1)
        XCTAssertEqual(gate.acceptedRequestCount, initialListCount + 1)

        gate.release()
        await firstRefresh.value
        for refresh in queuedRefreshes {
            await refresh.value
        }

        XCTAssertEqual(gate.acceptedRequestCount, initialListCount + 2)
        XCTAssertEqual(gate.inFlightRequestCount, 0)
        XCTAssertEqual(gate.maximumInFlightRequestCount, 1)
        store.disconnect()
    }

    func testSelectedDetailAndRefreshPressureStayInsideOneAcceptedRPCDrain() async throws {
        let gate = PerformanceListRequestGate()
        let detailProbe = PerformanceDetailRequestProbe()
        let sequenceProbe = PerformanceRPCSequenceProbe()
        PerformanceContractURLProtocol.install { request in
            let action = try request.performanceRPCBody()
            sequenceProbe.record(action)
            let fields = Set(
                action.arguments["fields"]?.arrayValue?.compactMap(\.stringValue) ?? []
            )
            let isOverviewDetail = action.method == "torrent-get" && fields.contains("desiredAvailable")
            if isOverviewDetail {
                let torrentID = performanceDetailSelectorID(action)
                detailProbe.recordOverview(torrentID: torrentID)
            }
            gate.waitIfBlocked(isOverviewDetail)
            if isOverviewDetail {
                return performanceResponse(
                    body: #"{"result":"success","arguments":{"torrents":[{"id":41,"hashString":"4141414141414141414141414141414141414141","comment":"overview"}]}}"#
                )
            }
            if action.method == "torrent-get" {
                return performanceResponse(
                    body: #"{"result":"success","arguments":{"torrents":[{"id":41,"hashString":"4141414141414141414141414141414141414141","name":"Harness torrent","status":4,"totalSize":1048576}]}}"#
                )
            }
            return performanceAppStoreResponse(for: action.method)
        }
        let store = try makePerformanceStore()

        await store.start()
        let initialRequestCount = gate.acceptedRequestCount
        gate.block()
        defer { gate.release() }

        store.selectedTorrentIDs = [41]
        let detailBlocked = await waitForPerformanceCondition {
            detailProbe.overviewTorrentIDs == [41] && gate.inFlightRequestCount == 1
        }
        XCTAssertTrue(detailBlocked)

        let queuedRefreshCompletions = PerformanceCompletionCounter()
        let queuedRefreshes = (0..<12).map { _ in
            Task { @MainActor in
                await store.refresh()
                queuedRefreshCompletions.record()
            }
        }
        let refreshesCoalesced = await waitForPerformanceCondition {
            queuedRefreshCompletions.count == queuedRefreshes.count
        }

        XCTAssertTrue(refreshesCoalesced)
        XCTAssertEqual(gate.acceptedRequestCount, initialRequestCount + 1)
        XCTAssertEqual(gate.maximumInFlightRequestCount, 1)

        gate.release()
        let detailPublished = await waitForPerformanceCondition {
            store.selectedTorrentDetailState.detail?.generalInfo?.comment == "overview"
        }
        for refresh in queuedRefreshes {
            await refresh.value
        }
        // The blocked overview satisfies the coalesced detail demand. The one
        // queued list/session/stats batch has no speculative tracker/peer reads.
        let expectedFinalRequestCount = initialRequestCount + 4
        let serializedBatchFinished = await waitForPerformanceCondition {
            gate.acceptedRequestCount == expectedFinalRequestCount
                && gate.inFlightRequestCount == 0
        }

        XCTAssertTrue(detailPublished)
        XCTAssertTrue(serializedBatchFinished)
        XCTAssertEqual(gate.acceptedRequestCount, expectedFinalRequestCount)
        XCTAssertEqual(gate.inFlightRequestCount, 0)
        XCTAssertEqual(gate.maximumInFlightRequestCount, 1)
        XCTAssertEqual(detailProbe.overviewTorrentIDs, [41])
        XCTAssertEqual(sequenceProbe.sequence, [
            "session-get",
            "torrent-get:list",
            "session-stats",
            "torrent-get:overview:41",
            "torrent-get:list",
            "session-get",
            "session-stats",
        ])
        store.disconnect()
    }

#if DEBUG
    func testIsolatedHarnessSelectsExactTargetOverviewExactlyOnce() async throws {
        let requestGate = PerformanceListRequestGate()
        let detailProbe = PerformanceDetailRequestProbe()
        let sequenceProbe = PerformanceRPCSequenceProbe()
        PerformanceContractURLProtocol.install { request in
            let action = try request.performanceRPCBody()
            sequenceProbe.record(action)
            requestGate.waitIfBlocked(action.method == "session-stats")
            if action.method == "torrent-get" {
                let fields = Set(
                    action.arguments["fields"]?.arrayValue?.compactMap(\.stringValue) ?? []
                )
                if fields.contains("desiredAvailable") {
                    let torrentID = performanceDetailSelectorID(action)
                    detailProbe.recordOverview(torrentID: torrentID)
                    return performanceResponse(
                        body: #"{"result":"success","arguments":{"torrents":[{"id":41,"hashString":"4141414141414141414141414141414141414141","comment":"overview"}]}}"#
                    )
                }
                return performanceResponse(
                    body: #"{"result":"success","arguments":{"torrents":[{"id":17,"hashString":"1717171717171717171717171717171717171717","name":"AAA unrelated torrent","status":4,"totalSize":1048576},{"id":41,"hashString":"4141414141414141414141414141414141414141","name":"ZZZ exact fixture","status":4,"totalSize":1048576}]}}"#
                )
            }
            return performanceAppStoreResponse(for: action.method)
        }
        let proofURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PerformanceDetailSelection-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: proofURL) }
        let store = try makePerformanceStore(
            performanceHarnessDetailSelection: .enabledForTesting(
                proofURL: proofURL,
                targetTorrentID: 41
            )
        )
        requestGate.block()
        let startTask = Task { @MainActor in
            await store.start()
        }

        let initialStatsSerialized = await waitForPerformanceCondition {
            Array(sequenceProbe.sequence.prefix(4)) == [
                "session-get",
                "torrent-get:list",
                "torrent-get:overview:41",
                "session-stats",
            ] && requestGate.inFlightRequestCount == 1
        }
        XCTAssertTrue(initialStatsSerialized)
        XCTAssertEqual(requestGate.maximumInFlightRequestCount, 1)
        requestGate.release()
        await startTask.value

        XCTAssertEqual(store.connectionState, .connected(rpcVersion: 18))
        XCTAssertEqual(Set(store.visibleTorrents.map(\.id)), Set([17, 41]))
        XCTAssertEqual(store.selectedTorrentIDs, [41])
        XCTAssertEqual(store.selectedTorrentDetailPane, .overview)
        XCTAssertTrue(store.isTorrentDetailVisible)
        XCTAssertEqual(detailProbe.overviewTorrentIDs, [41])
        XCTAssertEqual(requestGate.maximumInFlightRequestCount, 1)
        XCTAssertNotNil(store.sessionStats)
        XCTAssertEqual(
            try String(contentsOf: proofURL, encoding: .utf8),
            "41 overview\n"
        )

        store.disconnect()
        await store.connect()

        XCTAssertEqual(Set(store.visibleTorrents.map(\.id)), Set([17, 41]))
        XCTAssertEqual(store.selectedTorrentIDs, [])
        store.disconnect()
    }
#endif

    private func makePerformanceStore(
        performanceHarnessDetailSelection: PerformanceHarnessDetailSelection? = nil
    ) throws -> AppStore {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PerformanceContract-\(UUID().uuidString)", isDirectory: true)
        let profileURL = directoryURL.appendingPathComponent("ConnectionProfiles.json")
        let defaultsSuite = "PerformanceContractTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directoryURL)
            defaults.removePersistentDomain(forName: defaultsSuite)
        }

        let profile = ConnectionProfile(name: "Performance mock", host: "127.0.0.1")
        let profileStore = ConnectionProfileStore(
            fileURL: profileURL,
            passwordStore: PerformancePasswordStore()
        )
        try profileStore.save(
            ConnectionProfileCollection(profiles: [profile], selectedProfileID: profile.id)
        )
        return AppStore(
            profileStore: profileStore,
            userDefaults: defaults,
            downloadCompletionNotifier: PerformanceDownloadCompletionNotifier(),
            pollingCoordinator: PollingCoordinator(clock: TestPollingClock()),
            performanceHarnessDetailSelection: performanceHarnessDetailSelection,
            selectionDebounceDuration: .zero,
            clientFactory: { profile in
                TransmissionRPCClient(profile: profile, urlSession: makePerformanceSession())
            }
        )
    }
}

final class MaterializedStatePerformanceContractTests: XCTestCase {
    func testZeroHundredAndThousandTorrentProjectionWorkStaysBounded() {
        for torrentCount in [0, 100, 1_000] {
            let torrents = (0..<torrentCount).map(performanceTorrent)
            let startedAt = ContinuousClock().now

            let projection = TorrentListProjection(
                torrents: torrents,
                filters: .empty,
                sortOrder: TorrentSorting.defaultSortOrder
            )
            let elapsed = startedAt.duration(to: ContinuousClock().now)

            XCTAssertEqual(projection.visibleRows.count, torrentCount)
            XCTAssertEqual(projection.visibleIDs.count, torrentCount)
            XCTAssertEqual(projection.makeSummary(
                selectedIDs: Set(torrents.prefix(10).map(\.id)),
                sessionStats: nil,
                sessionInfo: nil
            ).totalCount, torrentCount)
            XCTAssertLessThan(elapsed, .seconds(2), "\(torrentCount)-row projection exceeded gross regression budget")
        }
    }

    func testTenThousandFileTreeAndSelectionWorkStaysBounded() throws {
        let files = (0..<10_000).map { index in
            TorrentFile(
                id: index,
                path: "Large/Batch \(index / 1_000)",
                name: String(format: "File-%05d.bin", index),
                length: 1_024,
                bytesCompleted: Int64(index % 1_024),
                wanted: true,
                priority: 0
            )
        }
        let startedAt = ContinuousClock().now

        let tree = TorrentFileNode.tree(from: files)
        let planner = TorrentFileSelectionPlanner(tree: tree)
        let selectedIndexes = planner.fileIndexes(in: planner.allNodeIDs)
        let elapsed = startedAt.duration(to: ContinuousClock().now)

        XCTAssertEqual(tree.count, 1)
        XCTAssertEqual(planner.allNodeIDs.count, 10_011)
        XCTAssertEqual(selectedIndexes, Array(0..<10_000))
        XCTAssertLessThan(elapsed, .seconds(5), "10,000-file materialization exceeded gross regression budget")
    }

    func testThousandRowDeltaRemovalIsDeterministicAndStaleGenerationCannotMutateState() throws {
        let activeGeneration = UUID()
        let staleGeneration = UUID()
        let now = ContinuousClock().now
        var accumulator = TorrentListDeltaAccumulator()
        accumulator.reset(for: activeGeneration)

        let fullRows = (1...1_000).map { id in
            TorrentGetTorrent(json: [
                "id": .int(id),
                "name": .string("Torrent \(id)"),
                "hashString": .string(String(format: "%040llx", Int64(id))),
                "status": .int(TorrentStatus.downloading.rawValue),
                "totalSize": .int(id * 1_024),
            ])
        }
        let initial = try XCTUnwrap(accumulator.apply(
            TorrentListUpdate(mode: .fullSnapshot, torrents: fullRows, removedIDs: []),
            connectionGeneration: activeGeneration,
            rpcVersion: 18,
            repairInterval: .seconds(600),
            now: now
        ))
        guard case .full(let initialRows) = initial else {
            return XCTFail("Expected a full snapshot result")
        }
        XCTAssertEqual(initialRows.count, 1_000)

        let staleUpdate = TorrentListUpdate(
            mode: .recentlyActive,
            torrents: [TorrentGetTorrent(json: [
                "id": .int(1_001),
                "name": .string("Stale"),
                "hashString": .string(String(format: "%040llx", Int64(1_001))),
            ])],
            removedIDs: Array(1...500)
        )
        XCTAssertNil(accumulator.apply(
            staleUpdate,
            connectionGeneration: staleGeneration,
            rpcVersion: 18,
            repairInterval: .seconds(600),
            now: now
        ))

        let removedIDs = Array(stride(from: 10, through: 1_000, by: 10))
        let merged = try XCTUnwrap(accumulator.apply(
            TorrentListUpdate(
                mode: .recentlyActive,
                torrents: [TorrentGetTorrent(json: [
                    "id": .int(1),
                    "hashString": .string(String(format: "%040llx", Int64(1))),
                    "rateDownload": .int(9_999),
                ])],
                removedIDs: removedIDs
            ),
            connectionGeneration: activeGeneration,
            rpcVersion: 18,
            repairInterval: .seconds(600),
            now: now
        ))

        guard case .changes(let upserted, let actualRemovedIDs) = merged else {
            return XCTFail("Expected an incremental result")
        }
        XCTAssertEqual(upserted.map(\.id), [1])
        XCTAssertEqual(upserted.first?.rateDownload, 9_999)
        XCTAssertEqual(actualRemovedIDs, removedIDs)
    }

    private func performanceTorrent(_ offset: Int) -> TorrentSummary {
        let id = offset + 1
        return TorrentSummary(
            id: id,
            name: String(format: "Torrent %05d", id),
            status: offset.isMultiple(of: 7) ? .stopped : .downloading,
            errorString: "",
            trackerError: "",
            globalError: "",
            trackerStatus: "",
            percentDone: Double(offset % 100) / 100,
            totalSize: Int64(id * 1_024),
            sizeWhenDone: Int64(id * 1_024),
            sizeToDownload: Int64(id * 1_024),
            leftUntilDone: Int64((id * 1_024) / 2),
            rateDownload: Int64(offset * 10),
            rateUpload: Int64(offset),
            eta: -1,
            uploadRatio: 0,
            downloadedEver: 0,
            uploadedEver: 0,
            downloadDir: "/downloads/\(offset % 8)",
            bandwidthPriority: 0,
            queuePosition: offset,
            secondsSeeding: 0,
            isPrivate: false,
            isMetadataComplete: true,
            seedsConnected: 0,
            seedsTotal: 0,
            peersConnected: 0,
            peersTotal: 0,
            labels: ["fixture-\(offset % 4)"],
            trackerHost: "tracker-\(offset % 5).example",
            addedDate: nil,
            completedDate: nil,
            activityDate: nil
        )
    }
}

#if DEBUG
final class PerformancePasswordStoreIsolationTests: XCTestCase {
    func testValidatedTemporaryHomeActivatesInMemorySecretStoresAndWritesRuntimeProof() throws {
        let context = try makeIsolationContext(markerToken: isolationToken)
        defer { try? FileManager.default.removeItem(at: context.root) }

        let stores = try XCTUnwrap(PerformancePasswordStoreIsolation.activateIfRequested(
            environment: context.environment,
            resolvedHomePath: context.home.path
        ))
        let proof = try String(
            contentsOf: context.home.appendingPathComponent(
                PerformancePasswordStoreIsolation.activationProofName
            ),
            encoding: .utf8
        )

        let rpcProfileID = UUID()
        let proxyProfileID = UUID()
        let identityProfileID = UUID()
        let identityReference = Data([0xA1, 0xB2])
        try stores.passwordStore.setPassword("in-memory-rpc", for: rpcProfileID)
        try stores.proxyPasswordStore.setPassword("in-memory-proxy", for: proxyProfileID)
        try stores.clientIdentityStore.restorePersistentReference(
            identityReference,
            for: identityProfileID
        )

        XCTAssertEqual(try stores.passwordStore.password(for: rpcProfileID), "in-memory-rpc")
        XCTAssertEqual(try stores.proxyPasswordStore.password(for: proxyProfileID), "in-memory-proxy")
        XCTAssertEqual(
            try stores.clientIdentityStore.persistentReference(for: identityProfileID),
            identityReference
        )
        XCTAssertNil(try stores.passwordStore.password(for: proxyProfileID))
        XCTAssertNil(try stores.proxyPasswordStore.password(for: rpcProfileID))
        try stores.passwordStore.removePassword(for: rpcProfileID)
        try stores.proxyPasswordStore.removePassword(for: proxyProfileID)
        try stores.clientIdentityStore.removeBinding(for: identityProfileID)
        XCTAssertNil(try stores.passwordStore.password(for: rpcProfileID))
        XCTAssertNil(try stores.proxyPasswordStore.password(for: proxyProfileID))
        XCTAssertNil(try stores.clientIdentityStore.persistentReference(for: identityProfileID))
        XCTAssertThrowsError(
            try stores.clientIdentityStore.importAndBind(
                data: Data([0x01]),
                passphrase: "not-used",
                profileID: identityProfileID,
                scheme: "https",
                now: Date()
            )
        ) { error in
            XCTAssertEqual(error as? ClientIdentityStoreError, .performanceIsolation)
        }
        XCTAssertEqual(
            proof,
            "\(PerformancePasswordStoreIsolation.compiledMarker)\n\(isolationToken)\n"
        )
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: context.home.appendingPathComponent(
                PerformancePasswordStoreIsolation.requestMarkerName
            ).path
        ))

        let reusedStores = try XCTUnwrap(PerformancePasswordStoreIsolation.activateIfRequested(
            environment: context.environment,
            resolvedHomePath: context.home.path
        ))
        XCTAssertThrowsError(try reusedStores.passwordStore.password(for: UUID())) { error in
            XCTAssertEqual(
                error as? PerformancePasswordStoreIsolationError,
                .requestMarkerUnavailable
            )
        }
    }

    func testInvalidIsolationMarkerRejectsWithoutActivatingPasswordAccess() throws {
        let context = try makeIsolationContext(markerToken: "wrong-\(isolationToken)")
        defer { try? FileManager.default.removeItem(at: context.root) }

        let stores = try XCTUnwrap(PerformancePasswordStoreIsolation.activateIfRequested(
            environment: context.environment,
            resolvedHomePath: context.home.path
        ))

        XCTAssertThrowsError(try stores.passwordStore.password(for: UUID())) { error in
            XCTAssertEqual(error as? PerformancePasswordStoreIsolationError, .markerMismatch)
        }
        XCTAssertThrowsError(try stores.proxyPasswordStore.password(for: UUID())) { error in
            XCTAssertEqual(error as? PerformancePasswordStoreIsolationError, .markerMismatch)
        }
        XCTAssertThrowsError(try stores.clientIdentityStore.persistentReference(for: UUID())) { error in
            XCTAssertEqual(error as? PerformancePasswordStoreIsolationError, .markerMismatch)
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: context.home.appendingPathComponent(
                PerformancePasswordStoreIsolation.activationProofName
            ).path
        ))
    }

    func testMalformedRequestedModeRejectsInsteadOfFallingBackToKeychain() throws {
        let context = try makeIsolationContext(markerToken: isolationToken)
        defer { try? FileManager.default.removeItem(at: context.root) }
        var environment = context.environment
        environment[PerformancePasswordStoreIsolation.modeEnvironmentKey] = "0"

        let stores = try XCTUnwrap(PerformancePasswordStoreIsolation.activateIfRequested(
            environment: environment,
            resolvedHomePath: context.home.path
        ))

        XCTAssertThrowsError(try stores.passwordStore.password(for: UUID())) { error in
            XCTAssertEqual(error as? PerformancePasswordStoreIsolationError, .invalidMode)
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: context.home.appendingPathComponent(
                PerformancePasswordStoreIsolation.activationProofName
            ).path
        ))
    }

    func testAbsentIsolationFlagDoesNotOverrideDefaultPasswordStoreSelection() {
        XCTAssertNil(PerformancePasswordStoreIsolation.activateIfRequested(
            environment: [:],
            resolvedHomePath: "/tmp/not-used"
        ))
    }

    private var isolationToken: String {
        "performance-isolation-token-000000000001"
    }

    private func makeIsolationContext(
        markerToken: String
    ) throws -> (root: URL, home: URL, environment: [String: String]) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PasswordIsolation-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let temporaryDirectory = home.appendingPathComponent("tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        try "\(markerToken)\n".write(
            to: home.appendingPathComponent(PerformancePasswordStoreIsolation.requestMarkerName),
            atomically: true,
            encoding: .utf8
        )
        return (
            root,
            home,
            [
                PerformancePasswordStoreIsolation.modeEnvironmentKey: "1",
                PerformancePasswordStoreIsolation.homeEnvironmentKey: home.path,
                PerformancePasswordStoreIsolation.tokenEnvironmentKey: isolationToken,
                "TMPDIR": temporaryDirectory.path,
            ]
        )
    }
}

final class PerformanceHarnessControlTests: XCTestCase {
    func testActivatedIsolationProofEnablesDetailSelectionAndWakeTrace() async throws {
        let context = try makeHarnessContext(includeFeatureFlags: true)
        defer { try? FileManager.default.removeItem(at: context.root) }

        let wakeRecorder = try XCTUnwrap(
            PerformanceHarnessPollingWakeRecorder.requestedFromEnvironment(
                environment: context.environment,
                resolvedHomePath: context.home.path
            )
        )
        XCTAssertNil(PerformanceHarnessDetailSelection.requestedFromEnvironment(
            environment: context.environment,
            resolvedHomePath: context.home.path
        ))

        _ = try XCTUnwrap(PerformancePasswordStoreIsolation.activateIfRequested(
            environment: context.environment,
            resolvedHomePath: context.home.path
        ))
        let detailSelection = try XCTUnwrap(
            PerformanceHarnessDetailSelection.requestedFromEnvironment(
                environment: context.environment,
                resolvedHomePath: context.home.path
            )
        )
        XCTAssertTrue(detailSelection.isAuthorized())
        XCTAssertEqual(detailSelection.targetTorrentID, 17)

        XCTAssertFalse(detailSelection.recordSelection(torrentID: 18))
        XCTAssertTrue(detailSelection.recordSelection(torrentID: 17))
        await wakeRecorder.recordWake(connectionToken: UUID(), work: .torrents)
        await wakeRecorder.recordWake(connectionToken: UUID(), work: [.torrents, .session])

        XCTAssertEqual(
            try String(
                contentsOf: context.temporaryDirectory.appendingPathComponent(
                    PerformanceHarnessContext.detailSelectionProofName
                ),
                encoding: .utf8
            ),
            "17 overview\n"
        )
        let detailProofURL = context.temporaryDirectory.appendingPathComponent(
            PerformanceHarnessContext.detailSelectionProofName
        )
        let detailProofAttributes = try FileManager.default.attributesOfItem(
            atPath: detailProofURL.path
        )
        XCTAssertEqual(
            (detailProofAttributes[.posixPermissions] as? NSNumber)?.intValue,
            0o600
        )
        XCTAssertFalse(detailSelection.recordSelection(torrentID: 18))
        XCTAssertEqual(
            try String(contentsOf: detailProofURL, encoding: .utf8),
            "17 overview\n"
        )
        XCTAssertEqual(
            try String(
                contentsOf: context.temporaryDirectory.appendingPathComponent(
                    PerformanceHarnessContext.wakeTraceName
                ),
                encoding: .utf8
            ),
            "1\n3\n"
        )
    }

    func testDetailSelectionProofRejectsSymlinkWithoutChangingItsTarget() throws {
        let context = try makeHarnessContext(includeFeatureFlags: true)
        defer { try? FileManager.default.removeItem(at: context.root) }
        _ = try XCTUnwrap(PerformancePasswordStoreIsolation.activateIfRequested(
            environment: context.environment,
            resolvedHomePath: context.home.path
        ))
        let detailSelection = try XCTUnwrap(
            PerformanceHarnessDetailSelection.requestedFromEnvironment(
                environment: context.environment,
                resolvedHomePath: context.home.path
            )
        )
        let targetURL = context.temporaryDirectory.appendingPathComponent("symlink-target")
        let proofURL = context.temporaryDirectory.appendingPathComponent(
            PerformanceHarnessContext.detailSelectionProofName
        )
        try "untouched\n".write(to: targetURL, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: proofURL,
            withDestinationURL: targetURL
        )

        XCTAssertFalse(detailSelection.recordSelection(torrentID: 17))
        XCTAssertEqual(
            try String(contentsOf: targetURL, encoding: .utf8),
            "untouched\n"
        )
    }

    func testHarnessControlsRejectAbsentFlagsAndMismatchedActivationProof() async throws {
        let ordinaryContext = try makeHarnessContext(includeFeatureFlags: false)
        defer { try? FileManager.default.removeItem(at: ordinaryContext.root) }
        _ = try XCTUnwrap(PerformancePasswordStoreIsolation.activateIfRequested(
            environment: ordinaryContext.environment,
            resolvedHomePath: ordinaryContext.home.path
        ))

        XCTAssertNil(PerformanceHarnessDetailSelection.requestedFromEnvironment(
            environment: ordinaryContext.environment,
            resolvedHomePath: ordinaryContext.home.path
        ))
        XCTAssertNil(PerformanceHarnessPollingWakeRecorder.requestedFromEnvironment(
            environment: ordinaryContext.environment,
            resolvedHomePath: ordinaryContext.home.path
        ))

        let rejectedContext = try makeHarnessContext(includeFeatureFlags: true)
        defer { try? FileManager.default.removeItem(at: rejectedContext.root) }
        _ = try XCTUnwrap(PerformancePasswordStoreIsolation.activateIfRequested(
            environment: rejectedContext.environment,
            resolvedHomePath: rejectedContext.home.path
        ))
        let invalidatedDetailSelection = try XCTUnwrap(
            PerformanceHarnessDetailSelection.requestedFromEnvironment(
                environment: rejectedContext.environment,
                resolvedHomePath: rejectedContext.home.path
            )
        )
        try "forged-proof\n".write(
            to: rejectedContext.home.appendingPathComponent(
                PerformancePasswordStoreIsolation.activationProofName
            ),
            atomically: true,
            encoding: .utf8
        )
        let rejectedWakeRecorder = try XCTUnwrap(
            PerformanceHarnessPollingWakeRecorder.requestedFromEnvironment(
                environment: rejectedContext.environment,
                resolvedHomePath: rejectedContext.home.path
            )
        )

        XCTAssertFalse(invalidatedDetailSelection.isAuthorized())
        XCTAssertNil(PerformanceHarnessDetailSelection.requestedFromEnvironment(
            environment: rejectedContext.environment,
            resolvedHomePath: rejectedContext.home.path
        ))
        await rejectedWakeRecorder.recordWake(connectionToken: UUID(), work: .torrents)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: rejectedContext.temporaryDirectory.appendingPathComponent(
                PerformanceHarnessContext.wakeTraceName
            ).path
        ))
    }

    private var token: String {
        "performance-harness-token-000000000000000001"
    }

    private func makeHarnessContext(
        includeFeatureFlags: Bool
    ) throws -> (root: URL, home: URL, temporaryDirectory: URL, environment: [String: String]) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PerformanceHarness-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let temporaryDirectory = home.appendingPathComponent("tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        try "\(token)\n".write(
            to: home.appendingPathComponent(PerformancePasswordStoreIsolation.requestMarkerName),
            atomically: true,
            encoding: .utf8
        )
        var environment = [
            PerformancePasswordStoreIsolation.modeEnvironmentKey: "1",
            PerformancePasswordStoreIsolation.homeEnvironmentKey: home.path,
            PerformancePasswordStoreIsolation.tokenEnvironmentKey: token,
            PerformancePreferencesIsolation.suiteEnvironmentKey:
                "\(PerformancePreferencesIsolation.suitePrefix).\(token)",
            "TMPDIR": temporaryDirectory.path,
        ]
        if includeFeatureFlags {
            environment[PerformanceHarnessContext.detailSelectionEnvironmentKey] = "1"
            environment[PerformanceHarnessDetailSelection.targetTorrentIDEnvironmentKey] = "17"
            environment[PerformanceHarnessContext.wakeRecordingEnvironmentKey] = "1"
        }
        return (root, home, temporaryDirectory, environment)
    }
}

final class PerformanceHarnessPollingVisibilityProofTests: XCTestCase {
    func testRecorderWritesExactForegroundAndBackgroundStateForValidatedContext() throws {
        let context = try makeContext(includeVisibilityProof: true)
        defer { try? FileManager.default.removeItem(at: context.root) }
        _ = try XCTUnwrap(PerformancePasswordStoreIsolation.activateIfRequested(
            environment: context.environment,
            resolvedHomePath: context.home.path
        ))
        let recorder = try XCTUnwrap(
            PerformanceHarnessPollingVisibilityProofRecorder.requestedFromEnvironment(
                environment: context.environment,
                resolvedHomePath: context.home.path
            )
        )
        let proofURL = context.temporaryDirectory.appendingPathComponent(
            PerformanceHarnessPollingVisibilityProofRecorder.proofName
        )

        XCTAssertTrue(recorder.record(.foreground))
        XCTAssertEqual(
            try String(contentsOf: proofURL, encoding: .utf8),
            "\(PerformanceHarnessPollingVisibilityProofRecorder.compiledMarker)\n\(token)\nforeground\n"
        )
        XCTAssertTrue(recorder.record(.background))
        XCTAssertEqual(
            try String(contentsOf: proofURL, encoding: .utf8),
            "\(PerformanceHarnessPollingVisibilityProofRecorder.compiledMarker)\n\(token)\nbackground\n"
        )
        let attributes = try FileManager.default.attributesOfItem(atPath: proofURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testRecorderDoesNotActivateForOrdinaryDebugOrInvalidatedIsolation() throws {
        let ordinary = try makeContext(includeVisibilityProof: false)
        defer { try? FileManager.default.removeItem(at: ordinary.root) }
        _ = try XCTUnwrap(PerformancePasswordStoreIsolation.activateIfRequested(
            environment: ordinary.environment,
            resolvedHomePath: ordinary.home.path
        ))
        XCTAssertNil(PerformanceHarnessPollingVisibilityProofRecorder.requestedFromEnvironment(
            environment: ordinary.environment,
            resolvedHomePath: ordinary.home.path
        ))

        let invalidated = try makeContext(includeVisibilityProof: true)
        defer { try? FileManager.default.removeItem(at: invalidated.root) }
        _ = try XCTUnwrap(PerformancePasswordStoreIsolation.activateIfRequested(
            environment: invalidated.environment,
            resolvedHomePath: invalidated.home.path
        ))
        try "forged\n".write(
            to: invalidated.home.appendingPathComponent(
                PerformancePasswordStoreIsolation.activationProofName
            ),
            atomically: true,
            encoding: .utf8
        )
        XCTAssertNil(PerformanceHarnessPollingVisibilityProofRecorder.requestedFromEnvironment(
            environment: invalidated.environment,
            resolvedHomePath: invalidated.home.path
        ))
    }

    private var token: String {
        "performance-visibility-token-000000000000000001"
    }

    private func makeContext(
        includeVisibilityProof: Bool
    ) throws -> (root: URL, home: URL, temporaryDirectory: URL, environment: [String: String]) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PerformanceVisibility-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let temporaryDirectory = home.appendingPathComponent("tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        try "\(token)\n".write(
            to: home.appendingPathComponent(PerformancePasswordStoreIsolation.requestMarkerName),
            atomically: true,
            encoding: .utf8
        )
        var environment = [
            PerformancePasswordStoreIsolation.modeEnvironmentKey: "1",
            PerformancePasswordStoreIsolation.homeEnvironmentKey: home.path,
            PerformancePasswordStoreIsolation.tokenEnvironmentKey: token,
            PerformancePreferencesIsolation.suiteEnvironmentKey:
                "\(PerformancePreferencesIsolation.suitePrefix).\(token)",
            "TMPDIR": temporaryDirectory.path,
        ]
        if includeVisibilityProof {
            environment[PerformanceHarnessPollingVisibilityProofRecorder.environmentKey] = "1"
        }
        return (root, home, temporaryDirectory, environment)
    }
}
#endif

final class ReleaseEvidenceShellContractTests: XCTestCase {
    func testAppBundleSHA256IsCanonicalLowercaseBehaviorally() throws {
        let root = try makeTemporaryDirectory(named: "AppBundleSHA256Contract")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = root.appendingPathComponent("leaf-certificate")
        try Data("canonical-leaf-fixture".utf8).write(to: fixture)

        let result = try runAppBundleLibraryShell(
            #"canonical_sha256 "$1""#,
            arguments: [fixture.path]
        )

        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(
            result.stdout,
            "587b5348266557cc3c15d38f9ded51c7279ca333112ab03d44e6ed3d1376f65d\n"
        )
    }

    func testPerformanceP95UsesIntervalCPUTimeAndMonotonicWallTime() throws {
        let script = try repositoryScript(named: "capture_mock_performance.sh")

        XCTAssertTrue(script.contains("Time::HiRes=clock_gettime,CLOCK_MONOTONIC"))
        XCTAssertTrue(script.contains("clock_gettime(CLOCK_MONOTONIC)"))
        XCTAssertTrue(script.contains("current_cpu - previous_cpu"))
        XCTAssertTrue(script.contains("current_wall - previous_wall"))
        XCTAssertTrue(script.contains("values+=\"$interval_cpu\\n\""))
        XCTAssertFalse(script.contains("-o %cpu="))
        XCTAssertFalse(script.contains("time.monotonic()"))
        XCTAssertFalse(script.contains("time.time()"))
    }

    func testMockPerformanceFailsClosedUnlessLocalConsoleRemainsUnlocked() throws {
        let script = try repositoryScript(named: "capture_mock_performance.sh")
        let warmupStart = try XCTUnwrap(script.range(of: "sleep_unlocked_warmup() {"))
        let fingerprintStart = try XCTUnwrap(
            script.range(of: "fingerprint_file() {", range: warmupStart.upperBound..<script.endIndex)
        )
        let stateWindowStart = try XCTUnwrap(script.range(of: "capture_state_window() {"))
        let cpuWindowStart = try XCTUnwrap(
            script.range(of: "capture_cpu() {", range: stateWindowStart.upperBound..<script.endIndex)
        )
        let metricsStart = try XCTUnwrap(
            script.range(of: "mock_metrics() {", range: cpuWindowStart.upperBound..<script.endIndex)
        )
        let stateWindow = String(script[stateWindowStart.lowerBound..<cpuWindowStart.lowerBound])
        let cpuWindow = String(script[cpuWindowStart.lowerBound..<metricsStart.lowerBound])
        let warmup = String(script[warmupStart.lowerBound..<fingerprintStart.lowerBound])

        XCTAssertTrue(script.contains("require_command /usr/sbin/ioreg"))
        XCTAssertTrue(script.contains("/usr/sbin/ioreg -n Root -d 1 -a"))
        XCTAssertTrue(script.contains("payload = sys.stdin.buffer.read()"))
        XCTAssertTrue(script.contains("registry = plistlib.loads(payload)"))
        XCTAssertFalse(script.contains("plistlib.load(sys.stdin.buffer)"))
        XCTAssertTrue(script.contains("if isinstance(registry, dict):"))
        XCTAssertTrue(script.contains("elif isinstance(registry, list):"))
        XCTAssertTrue(script.contains(#"if isinstance(entry, dict) and "IOConsoleLocked" in entry"#))
        XCTAssertTrue(script.contains("if len(roots) != 1:"))
        XCTAssertTrue(script.contains(#"type(locked) is not bool"#))
        XCTAssertTrue(script.contains(#"[[ "$lock_state" == "unlocked" ]]"#))
        XCTAssertTrue(script.contains("assert_console_unlocked \"VAL-005 startup\""))
        XCTAssertGreaterThanOrEqual(
            stateWindow.components(separatedBy: "assert_console_unlocked").count - 1,
            3
        )
        XCTAssertGreaterThanOrEqual(
            cpuWindow.components(separatedBy: "assert_console_unlocked").count - 1,
            4
        )
        XCTAssertTrue(warmup.contains("while (( elapsed < duration_seconds ))"))
        XCTAssertTrue(warmup.contains("warmup_started=\"$(monotonic_seconds)\""))
        XCTAssertTrue(warmup.contains("sleep_until_elapsed \"$warmup_started\" \"$elapsed\""))
        XCTAssertGreaterThanOrEqual(
            warmup.components(separatedBy: "assert_console_unlocked").count - 1,
            4
        )
        XCTAssertFalse(warmup.contains(#"/bin/sleep "$duration_seconds""#))
        XCTAssertTrue(script.contains(
            "sleep_unlocked_warmup \"$SMOKE_WARMUP_SECONDS\""
        ))
        XCTAssertTrue(script.contains(
            "sleep_unlocked_warmup \"$RELEASE_WARMUP_SECONDS\""
        ))
        XCTAssertTrue(script.contains(
            "sleep_unlocked_warmup \"$RELEASE_FILES_WARMUP_SECONDS\""
        ))
        XCTAssertFalse(script.contains(#"/bin/sleep "$SMOKE_WARMUP_SECONDS""#))
        XCTAssertFalse(script.contains(#"/bin/sleep "$RELEASE_WARMUP_SECONDS""#))
        XCTAssertFalse(script.contains(#"/bin/sleep "$RELEASE_FILES_WARMUP_SECONDS""#))
        XCTAssertTrue(script.contains("assert_console_unlocked \"stale-generation measurement\""))
    }

    func testMockPerformanceFixtureMatchesCurrentTransferPreferencesSchema() throws {
        let script = try repositoryScript(named: "capture_mock_performance.sh")

        XCTAssertTrue(script.contains(
            "\"schemaVersion\" : \(ProfileTransferPreferences.currentSchemaVersion)"
        ))
        XCTAssertTrue(script.contains(
            "\"addDestinationRules\" : {\n          \"rules\" : []\n        }"
        ))
        XCTAssertTrue(script.contains(#"[[ -n "$pid" ]] || return 0"#))
    }

    func testBuildVerificationTargetsTheExactInstalledExecutable() throws {
        let script = try repositoryScript(named: "build_and_run.sh")

        XCTAssertTrue(script.contains("process_ids_for_executable"))
        XCTAssertTrue(script.contains("verify_exact_app_process"))
        XCTAssertTrue(script.contains("APPLICATIONS_EXECUTABLE"))
        XCTAssertTrue(script.contains("terminate_executable \"$APPLICATIONS_EXECUTABLE\""))
        XCTAssertFalse(script.contains("pgrep -x \"$APP_EXECUTABLE_NAME\" >/dev/null"))
    }

    func testBuildVerifiesStagedInstallAndRestoresPreviousBundleOnFailure() throws {
        let script = try repositoryScript(named: "build_and_run.sh")
        let stageVerification = try XCTUnwrap(
            script.range(of: "verify_development_signature \"$APPLICATIONS_STAGING_BUNDLE\"")
        )
        let existingMove = try XCTUnwrap(
            script.range(
                of: "/bin/mv \"$APPLICATIONS_BUNDLE\" \"$APPLICATIONS_BACKUP_BUNDLE\"",
                range: stageVerification.upperBound..<script.endIndex
            )
        )
        let installedVerification = try XCTUnwrap(
            script.range(
                of: "verify_development_signature \"$APPLICATIONS_BUNDLE\"",
                range: existingMove.upperBound..<script.endIndex
            )
        )

        XCTAssertLessThan(stageVerification.lowerBound, existingMove.lowerBound)
        XCTAssertLessThan(existingMove.lowerBound, installedVerification.lowerBound)
        XCTAssertTrue(script.contains("trap cleanup_build_state EXIT"))
        XCTAssertTrue(script.contains("INSTALL_SWAP_STARTED"))
        XCTAssertTrue(script.contains("INSTALL_COMMITTED"))
        XCTAssertTrue(script.contains("/bin/mv \"$APPLICATIONS_BACKUP_BUNDLE\" \"$APPLICATIONS_BUNDLE\""))
        XCTAssertFalse(script.contains("/bin/rm -rf \"$APPLICATIONS_BUNDLE\"\n/bin/cp -RX"))
    }

    func testMockPerformanceWindowsContinuouslyAssertExactPIDState() throws {
        let script = try repositoryScript(named: "capture_mock_performance.sh")
        let appDelegate = try repositoryFile(
            at: "Sources/TransmissionRemoteMac/App/AppDelegate.swift"
        )
        let visibilityResolver = try repositoryFile(
            at: "Sources/TransmissionRemoteMac/Services/ApplicationPollingVisibilityResolver.swift"
        )

        XCTAssertTrue(script.contains("assert_isolated_app_state \"$pid\" \"$expected_state\" \"$label\""))
        XCTAssertTrue(script.contains("assert_isolated_app_state \"$pid\" \"$expected_state\" \"$label CPU sample"))
        XCTAssertTrue(script.contains("polling_visibility_proof_state"))
        XCTAssertTrue(script.contains("TRANSMISSION_REMOTE_MAC_PERFORMANCE_VISIBILITY_PROOF=1"))
#if DEBUG
        XCTAssertTrue(script.contains(PerformanceHarnessPollingVisibilityProofRecorder.compiledMarker))
        XCTAssertTrue(script.contains(PerformanceHarnessPollingVisibilityProofRecorder.proofName))
#endif
        XCTAssertTrue(script.contains("expected AppDelegate polling visibility"))
        XCTAssertTrue(script.contains("wait_for_isolated_app_foreground()"))
        XCTAssertTrue(script.contains("for (( attempt = 0; attempt < 300; attempt++ ))"))
        XCTAssertTrue(script.contains("sampled_process_state=\"$(isolated_process_state \"$APP_PID\""))
        XCTAssertTrue(script.contains("&& \"$sampled_polling_visibility\" == \"foreground\""))
        XCTAssertTrue(script.contains("wait_for_isolated_app_foreground \"foreground activation\""))
        XCTAssertTrue(script.contains("connected-visible measurement"))
        XCTAssertTrue(script.contains("disconnected-visible measurement"))
        XCTAssertTrue(script.contains("scale-$torrent_count connected-visible measurement"))
        XCTAssertTrue(script.contains("inactive-visible background measurement"))
        XCTAssertTrue(script.contains("hidden-default measurement"))
        XCTAssertTrue(script.contains("idle-visible measurement"))
        XCTAssertTrue(script.contains(#""allTorrentsState":"stopped""#))
        XCTAssertTrue(script.contains("wait_for_idle_torrent_publication"))
        XCTAssertTrue(script.contains("clear_idle_delta_delivery"))
        XCTAssertTrue(script.contains("state[\"allTorrentsStopped\"]"))
        XCTAssertTrue(script.contains("large-files detail measurement"))
        XCTAssertTrue(script.contains("stale-generation"))
        XCTAssertTrue(script.contains("hidden-suspended measurement"))
        XCTAssertFalse(script.contains("one-detail-overview measurement"))
        XCTAssertFalse(script.contains("RELEASE_ONE_DETAIL"))
        XCTAssertFalse(script.contains(#"/bin/sleep "$RELEASE_VOLUME_WINDOW_SECONDS""#))
        XCTAssertFalse(script.contains(#"/bin/sleep "$RELEASE_ONE_DETAIL_SAMPLE_SECONDS""#))
        XCTAssertTrue(script.contains("PERFORMANCE_DETAIL_TARGET_ID=1"))
        XCTAssertTrue(script.contains(
            #"PERFORMANCE_DETAIL_TARGET_ENVIRONMENT_KEY="TRANSMISSION_REMOTE_MAC_PERFORMANCE_DETAIL_TORRENT_ID""#
        ))
        XCTAssertTrue(script.contains(
            #""$PERFORMANCE_DETAIL_TARGET_ENVIRONMENT_KEY"="$PERFORMANCE_DETAIL_TARGET_ID""#
        ))
        XCTAssertTrue(script.contains(
            #""$proof" == "$expected_torrent_id $expected_pane""#
        ))
        XCTAssertTrue(script.contains("--large-detail-torrent"))
        XCTAssertTrue(script.contains("files_rpc_latency"))
        XCTAssertTrue(script.contains("files_projection"))
        XCTAssertTrue(script.contains("files_select_all"))
        XCTAssertTrue(script.contains("files_mutation_plan"))
        XCTAssertTrue(script.contains("files_pane_proof"))
        XCTAssertTrue(script.contains(#"not positive_integer(record["durationNanoseconds"])"#))
        XCTAssertTrue(script.contains("state-commit"))
        XCTAssertFalse(script.contains("files_fetch_materialization"))
        XCTAssertFalse(script.contains("files_expand"))
        XCTAssertFalse(script.contains(#""files_select""#))
        XCTAssertTrue(script.contains("large-files detail average CPU"))
        XCTAssertTrue(script.contains("large-files detail p95 CPU"))
        XCTAssertTrue(script.contains("RELEASE_CONNECTED_AVERAGE_CPU_MAX=1.0"))
        XCTAssertTrue(script.contains("RELEASE_CONNECTED_P95_CPU_MAX=2.0"))
        XCTAssertTrue(script.contains("RELEASE_BACKGROUND_P95_CPU_MAX=2.0"))
        XCTAssertFalse(script.contains("RELEASE_BACKGROUND_P95_CPU_MAX=\"${"))
        XCTAssertTrue(script.contains("inactive-visible background p95 CPU"))
        XCTAssertTrue(script.contains("hidden p95 CPU"))
        XCTAssertTrue(script.contains("RELEASE_THOUSAND_FOOTPRINT_MAX_BYTES=$((150 * 1024 * 1024))"))
        XCTAssertTrue(script.contains("RELEASE_FILES_FOOTPRINT_MAX_BYTES=$((250 * 1024 * 1024))"))
        XCTAssertTrue(script.contains("process_physical_footprint_bytes"))
        XCTAssertTrue(script.contains("physical_footprint_peak_bytes"))
        XCTAssertTrue(script.contains("connected visible peak physical footprint bytes"))
        XCTAssertTrue(script.contains("large-files detail peak physical footprint bytes"))
        XCTAssertTrue(script.contains("TRANSMISSION_REMOTE_MAC_CONFIRM_LONG_ACCEPTANCE"))
        XCTAssertTrue(script.contains("fail_on_recorded_gate_failures"))
        XCTAssertTrue(script.contains(
            "run_mock_debug_stale_generation\n    fail_on_recorded_gate_failures stale-generation"
        ))
        XCTAssertTrue(script.contains(#"record["reason"] == "stale-owner""#))
        XCTAssertTrue(script.contains("disconnect_isolated_app_through_menu"))
        XCTAssertTrue(script.contains("run_mock_debug_disconnected"))
        XCTAssertTrue(script.contains("run_mock_debug_scale_dataset 0"))
        XCTAssertTrue(script.contains("run_mock_debug_scale_dataset 100"))
        XCTAssertTrue(script.contains("run_mock_debug_connected_and_hidden"))
        XCTAssertTrue(script.contains("run_mock_debug_large_files_detail"))
        XCTAssertTrue(script.contains("run_mock_debug_stale_generation"))
        XCTAssertTrue(script.contains("run_mock_debug_suspended_background"))
        XCTAssertTrue(appDelegate.contains("window.occlusionState.contains(.visible)"))
        XCTAssertTrue(visibilityResolver.contains("!window.isMiniaturized"))
        XCTAssertTrue(visibilityResolver.contains("&& window.isOcclusionVisible"))
        XCTAssertTrue(appDelegate.contains("recordPerformancePollingVisibility(visibility)"))
        XCTAssertTrue(appDelegate.contains("#if DEBUG"))
    }

    func testLongPerformanceAcceptanceRequiresExplicitConfirmationBeforeInspection() throws {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            repositoryScriptURL(named: "capture_mock_performance.sh").path,
            "--mock-debug-acceptance",
        ]
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        process.standardOutput = output
        process.standardError = output

        try process.run()
        process.waitUntilExit()
        let message = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )

        XCTAssertEqual(process.terminationStatus, 2)
        XCTAssertTrue(message.contains("release-candidate-only"))
        XCTAssertTrue(message.contains("45 to 50 minutes"))
        XCTAssertFalse(message.contains("app="))
    }

    func testReleaseRequiresExactArtifactPerformanceAttestationBeforePublication() throws {
        let script = try repositoryScript(named: "release.sh")
        let artifactFreeze = try XCTUnwrap(
            script.range(of: "STAGED_ARTIFACT_SNAPSHOT \\")
        )
        let attesterRun = try XCTUnwrap(
            script.range(of: "run_performance_attester", range: artifactFreeze.upperBound..<script.endIndex)
        )
        let publication = try XCTUnwrap(
            script.range(
                of: "publish_release_output \\",
                range: attesterRun.upperBound..<script.endIndex
            )
        )
        let checksumWrite = try XCTUnwrap(
            script.range(
                of: #">"$STAGED_CHECKSUM_FILE""#,
                range: attesterRun.upperBound..<publication.lowerBound
            )
        )
        let manifestWrite = try XCTUnwrap(
            script.range(
                of: "\nwrite_canonical_manifest\n",
                range: checksumWrite.upperBound..<publication.lowerBound
            )
        )

        XCTAssertLessThan(artifactFreeze.lowerBound, attesterRun.lowerBound)
        XCTAssertLessThan(attesterRun.lowerBound, publication.lowerBound)
        XCTAssertTrue(script.contains("run_isolated_performance_attester"))
        XCTAssertTrue(script.contains("create_executable_snapshot"))
        XCTAssertTrue(script.contains("private performance attester snapshot failed exact-content verification"))
        XCTAssertTrue(script.contains("os.execve("))
        XCTAssertTrue(script.contains("execution_path,"))
        XCTAssertTrue(script.contains("\"/dev/fd/21\" if value == artifact_token"))
        XCTAssertTrue(script.contains("(require-not (literal \"/dev/null\"))"))
        XCTAssertTrue(script.contains("canonical_scratch_path = os.path.realpath(scratch_path)"))
        XCTAssertTrue(script.contains("escaped_scratch = canonical_scratch_path"))
        XCTAssertFalse(script.contains("os.execve(\n                \"/dev/fd/20\""))
        XCTAssertFalse(script.contains(#"if ! "$PERFORMANCE_ATTESTER_CANONICAL""#))
        XCTAssertFalse(script.contains("eval"))
        XCTAssertTrue(script.contains(#""result": "passed""#))
        XCTAssertTrue(script.contains(#""attestationSha256": "$PERFORMANCE_ATTESTATION_SHA256""#))
        XCTAssertTrue(script.contains(#""attesterSha256": "$PERFORMANCE_ATTESTER_SHA256""#))
        XCTAssertTrue(script.contains(#""submissionId": submission_id"#))
        XCTAssertTrue(script.contains(#""leafSha256": leaf_sha256"#))
        XCTAssertTrue(script.contains("performance attestation fields do not exactly match"))
        XCTAssertTrue(script.contains("performance attestation JSON is not canonical"))
        XCTAssertTrue(script.contains("child_environment = {"))
        XCTAssertFalse(script.contains("child_environment = os.environ.copy()"))
        XCTAssertFalse(script.contains("\"path\": \"$SDK_PATH\""))
        XCTAssertGreaterThanOrEqual(
            script.components(separatedBy: "verify_staged_release_evidence_hashes").count - 1,
            4
        )
        XCTAssertNotNil(script.range(
            of: "verify_staged_release_evidence_hashes",
            range: attesterRun.upperBound..<checksumWrite.lowerBound
        ))
        XCTAssertNotNil(script.range(
            of: "verify_staged_release_evidence_hashes",
            range: checksumWrite.upperBound..<manifestWrite.lowerBound
        ))
        XCTAssertNotNil(script.range(
            of: "verify_staged_release_evidence_hashes",
            range: manifestWrite.upperBound..<publication.lowerBound
        ))
    }

    func testReleaseHashesRegularFilesThroughNoFollowDescriptors() throws {
        let releaseScript = try repositoryScript(named: "release.sh")
        let releaseContract = try repositoryScript(named: "lib/release_contract.sh")
        let script = releaseScript + "\n" + releaseContract

        XCTAssertTrue(script.contains("os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK"))
        XCTAssertTrue(script.contains("before = os.fstat(descriptor)"))
        XCTAssertTrue(script.contains("after = os.fstat(descriptor)"))
        XCTAssertTrue(script.contains("os.read(descriptor, 1024 * 1024)"))
        XCTAssertTrue(script.contains("if metadata(before) != metadata(after):"))
        XCTAssertTrue(script.contains("os.stat(path, follow_symlinks=False)"))
        XCTAssertTrue(script.contains("not stat.S_ISREG(before.st_mode)"))
        XCTAssertTrue(script.contains("release evidence is not a regular file"))
        XCTAssertTrue(script.contains("release evidence must have exactly one hard link"))
        XCTAssertTrue(script.contains("attestation_descriptor = os.open(path_text, flags)"))
        XCTAssertTrue(script.contains("performance attestation does not match its frozen release identity"))
        XCTAssertFalse(script.contains("path.read_bytes()"))
        XCTAssertFalse(script.contains("/usr/bin/shasum -a 256"))
    }

    func testReleaseFreezesEveryStagedOutputAndAttesterIdentity() throws {
        let releaseScript = try repositoryScript(named: "release.sh")
        let releaseContract = try repositoryScript(named: "lib/release_contract.sh")
        let script = releaseScript + "\n" + releaseContract
        let requiredSnapshots = [
            "STAGED_ARTIFACT_SNAPSHOT",
            "STAGED_SOURCE_ARTIFACT_SNAPSHOT",
            "STAGED_CHECKSUM_FILE_SNAPSHOT",
            "STAGED_MANIFEST_SNAPSHOT",
            "STAGED_PERFORMANCE_ATTESTATION_SNAPSHOT",
            "PERFORMANCE_ATTESTER_SNAPSHOT",
        ]
        let whitespaceNormalizedScript = script
            .replacingOccurrences(of: "\\\n", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")

        for snapshot in requiredSnapshots {
            XCTAssertTrue(
                whitespaceNormalizedScript.contains("freeze_regular_file \(snapshot) "),
                snapshot
            )
            XCTAssertTrue(script.contains("$\(snapshot)"), snapshot)
        }
        XCTAssertTrue(script.contains("verify_staged_release_evidence_hashes"))
        XCTAssertTrue(script.contains("comparison == \"exact\""))
        XCTAssertTrue(script.contains("comparison == \"moved\""))
        XCTAssertTrue(script.contains("after.st_dev"))
        XCTAssertTrue(script.contains("after.st_ino"))
        XCTAssertTrue(script.contains("after.st_nlink"))
    }

    func testReleaseRejectsHardLinkedFrozenInputBehaviorally() throws {
        let root = try makeTemporaryDirectory(named: "ReleaseSingletonContract")
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("evidence")
        let alias = root.appendingPathComponent("evidence-link")
        try Data("release evidence".utf8).write(to: original)
        try FileManager.default.linkItem(at: original, to: alias)

        let result = try runReleaseLibraryShell(
            #"regular_file_snapshot "$1""#,
            arguments: [original.path]
        )

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("exactly one hard link"), result.stderr)
    }

    func testIsolatedAttesterExecutesPrivateSnapshotCapturesEOFAndContainsDescendants() throws {
        let root = try makeTemporaryDirectory(named: "ReleaseAttesterContract")
        defer { try? FileManager.default.removeItem(at: root) }
        let attester = root.appendingPathComponent("attester.sh")
        let artifact = root.appendingPathComponent("artifact.zip")
        let scratch = root.appendingPathComponent("scratch", isDirectory: true)
        let output = root.appendingPathComponent("attestation.json")
        let escapedWrite = root.appendingPathComponent("escape")
        let canonicalRootPath = root.path.hasPrefix("/var/")
            ? "/private\(root.path)"
            : root.path
        try Data("exact-artifact-bytes".utf8).write(to: artifact)
        try #"""
        #!/bin/sh
        set -eu
        artifact=""
        artifact_name=""
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --artifact) artifact="$2"; shift 2 ;;
            --artifact-file-name) artifact_name="$2"; shift 2 ;;
            *) shift ;;
          esac
        done
        [ "$0" = "${HOME%/*}/.performance-attester-executable/performance-attester" ]
        [ "$artifact" = "/dev/fd/21" ]
        /bin/sleep 60 </dev/null >/dev/null 2>&1 &
        printf '%s\n' "$!" > "$HOME/child.pid"
        if /bin/echo forbidden > "$HOME/../escape"; then
          exit 91
        fi
        if /bin/echo tamper >> "$0"; then
          exit 92
        fi
        printf 'launcher=%s\nartifact=%s\npayload=' "$0" "$artifact_name"
        /bin/cat "$artifact"
        printf '\n'
        """#.write(to: attester, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: attester.path
        )

        let result = try runReleaseLibraryShell(
            #"""
            attester_snapshot="$(regular_file_snapshot "$1")"
            artifact_snapshot="$(regular_file_snapshot "$2")"
            run_isolated_performance_attester \
              "$1" "$attester_snapshot" \
              "$2" "$artifact_snapshot" \
              "$3" "$4" 5 \
              --artifact "$ARTIFACT_DESCRIPTOR_TOKEN" \
              --artifact-file-name artifact.zip
            """#,
            arguments: [attester.path, artifact.path, scratch.path, output.path]
        )

        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(
            try String(contentsOf: output, encoding: .utf8),
            "launcher=\(canonicalRootPath)/" +
                ".performance-attester-executable/performance-attester\n" +
                "artifact=artifact.zip\npayload=exact-artifact-bytes\n"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: escapedWrite.path))
        let childPIDText = try String(
            contentsOf: scratch.appendingPathComponent("child.pid"),
            encoding: .utf8
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let childPID = try XCTUnwrap(Int32(childPIDText))
        XCTAssertEqual(kill(childPID, 0), -1, "attester descendant remained alive")
        XCTAssertEqual(errno, ESRCH)
        let outputAttributes = try FileManager.default.attributesOfItem(atPath: output.path)
        XCTAssertEqual((outputAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testFinalEvidenceSetPairsEveryPublishedPathWithItsSnapshotBehaviorally() throws {
        let root = try makeTemporaryDirectory(named: "ReleaseEvidenceSetContract")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = (0..<6).map { root.appendingPathComponent("evidence-\($0)") }
        for (index, path) in paths.enumerated() {
            try Data("distinct-evidence-\(index)".utf8).write(to: path)
        }

        let result = try runReleaseLibraryShell(
            #"""
            one="$(regular_file_snapshot "$1")"
            two="$(regular_file_snapshot "$2")"
            three="$(regular_file_snapshot "$3")"
            four="$(regular_file_snapshot "$4")"
            five="$(regular_file_snapshot "$5")"
            attester="$(regular_file_snapshot "$6")"
            verify_release_evidence_set \
              "$1" "$one" exact one \
              "$2" "$two" exact two \
              "$3" "$three" exact three \
              "$4" "$four" exact four \
              "$5" "$five" exact five \
              "$6" "$attester" exact attester
            if verify_release_evidence_set "$1" "$two" exact one "$2" "$two" exact two "$3" "$three" exact three "$4" "$four" exact four "$5" "$five" exact five "$6" "$attester" exact attester; then exit 91; fi
            if verify_release_evidence_set "$1" "$one" exact one "$2" "$three" exact two "$3" "$three" exact three "$4" "$four" exact four "$5" "$five" exact five "$6" "$attester" exact attester; then exit 92; fi
            if verify_release_evidence_set "$1" "$one" exact one "$2" "$two" exact two "$3" "$four" exact three "$4" "$four" exact four "$5" "$five" exact five "$6" "$attester" exact attester; then exit 93; fi
            if verify_release_evidence_set "$1" "$one" exact one "$2" "$two" exact two "$3" "$three" exact three "$4" "$five" exact four "$5" "$five" exact five "$6" "$attester" exact attester; then exit 94; fi
            if verify_release_evidence_set "$1" "$one" exact one "$2" "$two" exact two "$3" "$three" exact three "$4" "$four" exact four "$5" "$one" exact five "$6" "$attester" exact attester; then exit 95; fi
            """#,
            arguments: paths.map(\.path)
        )

        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertGreaterThanOrEqual(
            result.stderr.components(separatedBy: "paired frozen snapshot").count - 1,
            5,
            result.stderr
        )
    }

    func testFinalEvidenceSetSweepsEveryOpenDescriptorAfterAllComparisons() throws {
        let script = try repositoryScript(named: "lib/release_contract.sh")
        let functionStart = try XCTUnwrap(script.range(of: "verify_release_evidence_set()"))
        let functionEnd = try XCTUnwrap(
            script.range(of: "snapshot_sha256()", range: functionStart.upperBound..<script.endIndex)
        )
        let body = script[functionStart.lowerBound..<functionEnd.lowerBound]
        let finalComparison = try XCTUnwrap(body.range(of: "does not match its paired frozen snapshot"))
        let finalSweep = try XCTUnwrap(
            body.range(
                of: "Final metadata/path sweep across every still-open descriptor",
                range: finalComparison.upperBound..<body.endIndex
            )
        )
        let descriptorClose = try XCTUnwrap(
            body.range(of: "finally:", range: finalSweep.upperBound..<body.endIndex)
        )

        XCTAssertLessThan(finalComparison.lowerBound, finalSweep.lowerBound)
        XCTAssertLessThan(finalSweep.lowerBound, descriptorClose.lowerBound)
        XCTAssertTrue(body[finalSweep.lowerBound..<descriptorClose.lowerBound]
            .contains("closing_state = os.fstat(entry[\"descriptor\"])"))
        XCTAssertTrue(body[finalSweep.lowerBound..<descriptorClose.lowerBound]
            .contains("closing_path_state = os.stat(entry[\"path\"], follow_symlinks=False)"))
    }

    func testArmedPublicationCleanupRemovesOnlyTheStagedInodeBehaviorally() throws {
        let root = try makeTemporaryDirectory(named: "ReleasePublicationCleanupContract")
        defer { try? FileManager.default.removeItem(at: root) }
        let staged = root.appendingPathComponent("staged")
        let final = root.appendingPathComponent("final")
        try Data("staged".utf8).write(to: staged)
        try Data("pre-existing".utf8).write(to: final)

        var result = try runReleaseLibraryShell(
            "remove_owned_release_output armed \"$2\" \"$1\"",
            arguments: [staged.path, final.path]
        )
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(try String(contentsOf: final, encoding: .utf8), "pre-existing")

        try FileManager.default.removeItem(at: final)
        try FileManager.default.linkItem(at: staged, to: final)
        result = try runReleaseLibraryShell(
            "remove_owned_release_output armed \"$2\" \"$1\"",
            arguments: [staged.path, final.path]
        )
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertFalse(FileManager.default.fileExists(atPath: final.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path))
    }

    func testPublishedCleanupRemovesOnlyTheFrozenPublishedFileBehaviorally() throws {
        let root = try makeTemporaryDirectory(named: "ReleasePublishedCleanupContract")
        defer { try? FileManager.default.removeItem(at: root) }
        let staged = root.appendingPathComponent("staged")
        let final = root.appendingPathComponent("final")
        try Data("owned".utf8).write(to: staged)

        var result = try runReleaseLibraryShell(
            #"snapshot="$(regular_file_snapshot "$1")"; owned=1; /bin/mv "$1" "$2"; remove_owned_release_output "$owned" "$2" "$1" "$snapshot""#,
            arguments: [staged.path, final.path]
        )
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertFalse(FileManager.default.fileExists(atPath: final.path))

        try Data("owned".utf8).write(to: staged)
        result = try runReleaseLibraryShell(
            #"snapshot="$(regular_file_snapshot "$1")"; /bin/mv "$1" "$2"; /bin/rm -f "$2"; printf rogue > "$2"; remove_owned_release_output 1 "$2" "$1" "$snapshot""#,
            arguments: [staged.path, final.path]
        )
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(try String(contentsOf: final, encoding: .utf8), "rogue")
    }

    func testReleaseWorkCleanupRejectsIntermediateSymlinksBehaviorally() throws {
        let root = try makeTemporaryDirectory(named: "ReleaseWorkCleanupContract")
        let outside = try makeTemporaryDirectory(named: "ReleaseWorkCleanupOutside")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let dist = root.appendingPathComponent("dist", isDirectory: true)
        try FileManager.default.createDirectory(at: dist, withIntermediateDirectories: true)
        let sentinel = outside.appendingPathComponent("sentinel")
        try Data("keep".utf8).write(to: sentinel)
        try FileManager.default.createSymbolicLink(
            at: dist.appendingPathComponent("release"),
            withDestinationURL: outside
        )

        let result = try runReleaseLibraryShell(
            #"ROOT_DIR="$1"; WORK_DIR="$ROOT_DIR/dist/release/work"; manage_release_work_dir create"#,
            arguments: [root.path]
        )

        XCTAssertNotEqual(result.status, 0)
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "keep")
    }

    func testPublicationCleanupOwnershipIsArmedBeforeLinkCreation() throws {
        let script = try repositoryScript(named: "lib/release_contract.sh")
        let functionStart = try XCTUnwrap(script.range(of: "publish_release_output()"))
        let body = script[functionStart.lowerBound..<script.endIndex]
        let absentPath = try XCTUnwrap(body.range(of: "[[ ! -e \"$final\" && ! -L \"$final\" ]]"))
        let armed = try XCTUnwrap(body.range(of: "printf -v \"$published_flag\" '%s' armed"))
        let link = try XCTUnwrap(body.range(of: "/bin/ln \"$staged\" \"$final\""))
        let unlink = try XCTUnwrap(body.range(of: "/bin/rm -f \"$staged\""))
        let published = try XCTUnwrap(body.range(of: "printf -v \"$published_flag\" '%s' 1"))

        XCTAssertLessThan(absentPath.lowerBound, armed.lowerBound)
        XCTAssertLessThan(armed.lowerBound, link.lowerBound)
        XCTAssertLessThan(link.lowerBound, unlink.lowerBound)
        XCTAssertLessThan(unlink.lowerBound, published.lowerBound)
        XCTAssertTrue(body.contains("namespace ownership"))
        XCTAssertTrue(script.contains("final_state.st_ino == staged_state.st_ino"))
    }

    func testReleaseVerifiesAllPublishedEvidenceBeforeCompletion() throws {
        let script = try repositoryScript(named: "release.sh")
        let releaseContract = try repositoryScript(named: "lib/release_contract.sh")
        let finalPublication = try XCTUnwrap(
            script.range(of: "PUBLISHED_PERFORMANCE_ATTESTATION\n")
        )
        let finalVerification = try XCTUnwrap(
            script.range(
                of: "verify_published_release_evidence",
                range: finalPublication.upperBound..<script.endIndex
            )
        )
        let releaseComplete = try XCTUnwrap(
            script.range(of: "RELEASE_COMPLETE=1", range: finalVerification.upperBound..<script.endIndex)
        )
        let releaseReady = try XCTUnwrap(
            script.range(of: "Release ready:", range: releaseComplete.upperBound..<script.endIndex)
        )
        let finalVerificationBody = try XCTUnwrap(
            script.range(of: "verify_published_release_evidence()")
        )
        let nextFunction = try XCTUnwrap(
            script.range(
                of: "write_canonical_manifest()",
                range: finalVerificationBody.upperBound..<script.endIndex
            )
        )
        let body = script[finalVerificationBody.lowerBound..<nextFunction.lowerBound]

        for path in [
            "$ARTIFACT",
            "$SOURCE_ARTIFACT",
            "$CHECKSUM_FILE",
            "$MANIFEST",
            "$PERFORMANCE_ATTESTATION",
        ] {
            XCTAssertTrue(body.contains(path), path)
        }
        XCTAssertTrue(body.contains("$PERFORMANCE_ATTESTER_CANONICAL"))
        XCTAssertTrue(body.contains("$PERFORMANCE_ATTESTER_SNAPSHOT"))
        XCTAssertTrue(body.contains("verify_release_evidence_set"))
        XCTAssertFalse(body.contains("verify_regular_file_snapshot"))
        XCTAssertLessThan(finalPublication.lowerBound, finalVerification.lowerBound)
        XCTAssertLessThan(finalVerification.lowerBound, releaseComplete.lowerBound)
        XCTAssertLessThan(releaseComplete.lowerBound, releaseReady.lowerBound)
        XCTAssertTrue(releaseContract.contains("printf -v \"$published_flag\" '%s' 1"))
        XCTAssertTrue(script.contains("if [[ \"$RELEASE_COMPLETE\" != 1 ]]"))
        XCTAssertTrue(releaseContract.contains("/bin/ln \"$staged\" \"$final\""))
        XCTAssertTrue(releaseContract.contains("verify_regular_file_snapshot \"$final\""))
        let unlink = try XCTUnwrap(releaseContract.range(of: "/bin/rm -f \"$staged\""))
        let postPublishIdentity = try XCTUnwrap(
            releaseContract.range(
                of: "verify_regular_file_snapshot \"$final\"",
                range: unlink.upperBound..<releaseContract.endIndex
            )
        )
        XCTAssertLessThan(unlink.lowerBound, postPublishIdentity.lowerBound)
        let completionGap = script[finalVerification.upperBound..<releaseComplete.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(completionGap, "")
    }

    private func makeTemporaryDirectory(named name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func runReleaseLibraryShell(
        _ body: String,
        arguments: [String] = []
    ) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            "-c",
            """
            export BUILD_NUMBER=1
            export TRANSMISSION_REMOTE_MAC_RELEASE_CONTRACT_LIBRARY=1
            source "$1"
            shift
            \(body)
            """,
            "release-contract",
            repositoryScriptURL(named: "release.sh").path,
        ] + arguments
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        return (
            process.terminationStatus,
            String(decoding: stdoutData, as: UTF8.self),
            String(decoding: stderrData, as: UTF8.self)
        )
    }

    private func runAppBundleLibraryShell(
        _ body: String,
        arguments: [String] = []
    ) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            "-c",
            """
            source "$1"
            shift
            \(body)
            """,
            "app-bundle-contract",
            repositoryScriptURL(named: "lib/app_bundle.sh").path,
        ] + arguments
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        return (
            process.terminationStatus,
            String(decoding: stdoutData, as: UTF8.self),
            String(decoding: stderrData, as: UTF8.self)
        )
    }

    private func repositoryScript(named name: String) throws -> String {
        try repositoryFile(at: "script/\(name)")
    }

    private func repositoryScriptURL(named name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("script/\(name)")
    }

    private func repositoryFile(at relativePath: String) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}

private struct PerformanceTorrentRequest {
    var fields: [String]
    var bodyBytes: Int

    var fieldCount: Int { fields.count }
}

private final class PerformanceScaleResponseRouter {
    private let lock = NSLock()
    private var pendingRowCounts: [Int]
    private var recordedTorrentRequests: [PerformanceTorrentRequest] = []
    private var recordedResponseByteCounts: [Int] = []
    private var recordedFieldCoverage: [Bool] = []

    init(rowCounts: [Int]) {
        pendingRowCounts = rowCounts
    }

    var torrentRequests: [PerformanceTorrentRequest] {
        lock.withLock { recordedTorrentRequests }
    }

    var responseByteCounts: [Int] {
        lock.withLock { recordedResponseByteCounts }
    }

    var responseRowsCoverEveryRequestedField: Bool {
        lock.withLock { recordedFieldCoverage.allSatisfy { $0 } }
    }

    func response(for request: URLRequest) throws -> (HTTPURLResponse, Data) {
        let body = try request.performanceBodyData()
        let action = try JSONDecoder().decode(RPCRequest.self, from: body)
        guard action.method == "torrent-get" else {
            return performanceResponse(
                body: #"{"result":"success","arguments":{"rpc-version":18,"version":"4.0"}}"#
            )
        }

        let rowCount = lock.withLock { pendingRowCounts.removeFirst() }
        let fields = action.arguments["fields"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let rows = try (0..<rowCount).map { offset -> [String: Any] in
            let id = offset + 1
            return try Dictionary(uniqueKeysWithValues: fields.map { field in
                (field, try representativeTorrentValue(field: field, id: id))
            })
        }
        let expectedFields = Set(fields)
        let rowsCoverEveryField = rows.allSatisfy { Set($0.keys) == expectedFields }
        let responseData = try JSONSerialization.data(withJSONObject: [
            "result": "success",
            "arguments": ["torrents": rows],
        ])
        lock.withLock {
            recordedTorrentRequests.append(
                PerformanceTorrentRequest(fields: fields, bodyBytes: body.count)
            )
            recordedResponseByteCounts.append(responseData.count)
            recordedFieldCoverage.append(rowCount == 0 || rowsCoverEveryField)
        }
        return performanceResponse(data: responseData)
    }

    private func representativeTorrentValue(field: String, id: Int) throws -> Any {
        switch field {
        case "id": id
        case "hashString": String(repeating: String(format: "%x", id % 16), count: 40)
        case "name": "Representative Torrent \(id) with a realistic display name"
        case "activityDate", "addedDate", "doneDate": 1_735_704_000 + id
        case "downloadedEver", "haveUnchecked", "haveValid", "leftUntilDone",
             "sizeWhenDone", "totalSize", "uploadedEver": id * 1_048_576
        case "errorString": id.isMultiple(of: 97) ? "Representative tracker warning" : ""
        case "eta": 3_600 + id
        case "metadataPercentComplete", "percentDone", "recheckProgress": Double(id % 100) / 100
        case "peersGettingFromUs", "peersSendingToUs": id % 8
        case "pieceCount": id
        case "pieceSize": 1_048_576
        case "queuePosition": id - 1
        case "rateDownload": id * 1_024
        case "rateUpload": id * 128
        case "secondsSeeding": id * 60
        case "status": id.isMultiple(of: 5) ? 6 : 4
        case "uploadRatio": Double(id % 300) / 10
        case "bandwidthPriority": (id % 3) - 1
        case "downloadDir": "/srv/transmission/downloads/category-\(id % 8)"
        case "isPrivate": id.isMultiple(of: 2)
        case "labels": ["fixture", "category-\(id % 4)"]
        case "trackerStats": [[
            "announce": "https://tracker-\(id % 5).example/announce",
            "announceState": 1,
            "downloadCount": id * 3,
            "hasAnnounced": true,
            "host": "tracker-\(id % 5).example",
            "id": id,
            "lastAnnounceResult": "Success",
            "leecherCount": id % 11,
            "nextAnnounceTime": 1_735_704_900 + id,
            "seederCount": id % 29,
            "tier": 0,
        ]]
        case "trackers": [[
            "announce": "https://tracker-\(id % 5).example/announce",
            "id": id,
            "scrape": "https://tracker-\(id % 5).example/scrape",
            "tier": 0,
        ]]
        default:
            throw PerformanceFixtureError.unsupportedTorrentField(field)
        }
    }
}

private enum PerformanceFixtureError: Error {
    case unsupportedTorrentField(String)
}

private final class PerformanceRequestRecorder {
    private let lock = NSLock()
    private var requests: [URLRequest] = []

    var requestCount: Int {
        lock.withLock { requests.count }
    }

    @discardableResult
    func record(_ request: URLRequest) -> Int {
        lock.withLock {
            requests.append(request)
            return requests.count
        }
    }
}

private final class PerformanceListRequestGate {
    private let condition = NSCondition()
    private var isBlocked = false
    private var accepted = 0
    private var inFlight = 0
    private var maximumInFlight = 0

    var acceptedRequestCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return accepted
    }

    var inFlightRequestCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return inFlight
    }

    var maximumInFlightRequestCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return maximumInFlight
    }

    func block() {
        condition.lock()
        isBlocked = true
        condition.unlock()
    }

    func release() {
        condition.lock()
        isBlocked = false
        condition.broadcast()
        condition.unlock()
    }

    func waitIfBlocked(_ shouldBlock: Bool = true) {
        condition.lock()
        accepted += 1
        inFlight += 1
        maximumInFlight = max(maximumInFlight, inFlight)
        while isBlocked && shouldBlock {
            condition.wait()
        }
        inFlight -= 1
        condition.unlock()
    }
}

private final class PerformanceDetailRequestProbe {
    private let lock = NSLock()
    private var overviewIDs: [Int] = []

    var overviewTorrentIDs: [Int] {
        lock.withLock { overviewIDs }
    }

    func recordOverview(torrentID: Int?) {
        guard let torrentID else { return }
        lock.withLock { overviewIDs.append(torrentID) }
    }
}

private func performanceDetailSelectorID(_ request: RPCRequest) -> Int? {
    guard let selector = request.arguments["ids"]?.arrayValue?.first else { return nil }
    return selector.intValue ?? [17, 41].first {
        String(repeating: String($0), count: 20) == selector.stringValue
    }
}

private final class PerformanceRPCSequenceProbe {
    private let lock = NSLock()
    private var values: [String] = []

    var sequence: [String] {
        lock.withLock { values }
    }

    func record(_ request: RPCRequest) {
        lock.withLock {
            guard request.method == "torrent-get" else {
                values.append(request.method)
                return
            }
            let fields = Set(
                request.arguments["fields"]?.arrayValue?.compactMap(\.stringValue) ?? []
            )
            if fields.contains("desiredAvailable") {
                let torrentID = performanceDetailSelectorID(request) ?? -1
                values.append("torrent-get:overview:\(torrentID)")
            } else if fields.contains("peers") {
                values.append("torrent-get:peers")
            } else if fields.contains("fileStats") {
                values.append("torrent-get:files")
            } else if !fields.contains("name"), fields.contains("trackerStats") {
                values.append("torrent-get:trackers")
            } else {
                values.append("torrent-get:list")
            }
        }
    }
}

private final class PerformanceCompletionCounter {
    private let lock = NSLock()
    private var completionCount = 0

    var count: Int {
        lock.withLock { completionCount }
    }

    func record() {
        lock.withLock { completionCount += 1 }
    }
}

private final class PerformanceContractURLProtocol: URLProtocol {
    typealias Handler = (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let lock = NSLock()
    private static var handler: Handler?

    static func install(_ handler: Handler?) {
        lock.withLock { self.handler = handler }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let handler = Self.lock.withLock { Self.handler }
        guard let handler else {
            client?.urlProtocol(self, didFailWithError: TransmissionRPCError.invalidResponse)
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [self] in
            do {
                let (response, data) = try handler(request)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }
    }

    override func stopLoading() {}
}

private func makePerformanceSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [PerformanceContractURLProtocol.self]
    return URLSession(configuration: configuration)
}

private func performanceResponse(
    statusCode: Int = 200,
    headers: [String: String]? = nil,
    body: String = ""
) -> (HTTPURLResponse, Data) {
    performanceResponse(statusCode: statusCode, headers: headers, data: Data(body.utf8))
}

private func performanceResponse(
    statusCode: Int = 200,
    headers: [String: String]? = nil,
    data: Data
) -> (HTTPURLResponse, Data) {
    let response = HTTPURLResponse(
        url: URL(string: "http://127.0.0.1:9091/transmission/rpc")!,
        statusCode: statusCode,
        httpVersion: nil,
        headerFields: headers
    )!
    return (response, data)
}

private func performanceAppStoreResponse(for method: String) -> (HTTPURLResponse, Data) {
    switch method {
    case "session-get":
        performanceResponse(
            body: #"{"result":"success","arguments":{"rpc-version":18,"version":"4.0","download-dir":"/downloads"}}"#
        )
    case "torrent-get":
        performanceResponse(body: #"{"result":"success","arguments":{"torrents":[]}}"#)
    case "session-stats":
        performanceResponse(body: #"{"result":"success","arguments":{}}"#)
    default:
        performanceResponse(body: #"{"result":"success","arguments":{}}"#)
    }
}

private func waitForPerformanceCondition(
    timeout: Duration = .seconds(2),
    _ condition: () -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return condition()
}

private struct PerformancePasswordStore: ConnectionPasswordStoring {
    func password(for profileID: UUID) throws -> String? { nil }
    func setPassword(_ password: String, for profileID: UUID) throws {}
    func removePassword(for profileID: UUID) throws {}
}

private struct PerformanceDownloadCompletionNotifier: DownloadCompletionNotifying {
    func notifyDownloadCompleted(torrentName: String) {}
}

private extension URLRequest {
    func performanceBodyData() throws -> Data {
        if let httpBody { return httpBody }
        let stream = try XCTUnwrap(httpBodyStream)
        stream.open()
        defer { stream.close() }

        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count > 0 {
                body.append(buffer, count: count)
            } else {
                break
            }
        }
        return body
    }

    func performanceRPCBody() throws -> RPCRequest {
        try JSONDecoder().decode(RPCRequest.self, from: performanceBodyData())
    }
}

private extension Array {
    var only: Element? {
        count == 1 ? first : nil
    }
}
