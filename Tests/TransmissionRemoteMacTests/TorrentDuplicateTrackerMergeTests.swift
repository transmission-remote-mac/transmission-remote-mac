// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation
import XCTest
@testable import TransmissionRemoteMac

final class TorrentDuplicateTrackerMergeTests: XCTestCase {
    override func tearDown() {
        DuplicateTrackerMockURLProtocol.requestHandler = nil
        AppStoreMockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testAddedTorrentSkipsDuplicatePlanningWork() async throws {
        let rpc = DuplicateTrackerRPCStub()
        let result = try TorrentAddResult(arguments: [
            "torrent-added": .object(["id": .int(42)])
        ])

        let plan = try await TorrentDuplicateTrackerMerge().planIfNeeded(
            addResult: result,
            localTrackerURLs: ["https://tracker.example/announce"],
            rpcVersion: 18,
            rpc: rpc
        )

        XCTAssertNil(plan)
        let state = await rpc.state
        XCTAssertEqual(state.fetchCallCount, 0)
        XCTAssertEqual(state.addCallCount, 0)
    }

    func testDuplicateWithoutParseableTrackersIsSuccessfulNoOpOnOldRPC() async throws {
        let rpc = DuplicateTrackerRPCStub()
        let result = try duplicateResult(id: 42, hashString: "hash-42")

        let plan = try await TorrentDuplicateTrackerMerge().planIfNeeded(
            addResult: result,
            localTrackerURLs: [" ", "\n"],
            rpcVersion: 9,
            rpc: rpc
        )

        XCTAssertNil(plan)
        let state = await rpc.state
        XCTAssertEqual(state.fetchCallCount, 0)
    }

    func testPlanningNormalizesAndListsOnlyExactMissingTrackersWithoutApplying() async throws {
        let rpc = DuplicateTrackerRPCStub(
            snapshot: TorrentDuplicateTrackerSnapshot(
                target: .hash("hash-42"),
                id: 42,
                hashString: "hash-42",
                announceURLs: [
                    "https://existing.example/announce",
                    "https://case.example/announce"
                ]
            )
        )
        let result = try duplicateResult(
            id: 42,
            hashString: " hash-42 ",
            name: " Existing torrent "
        )

        let plannedMerge = try await TorrentDuplicateTrackerMerge().planIfNeeded(
            addResult: result,
            localTrackerURLs: [
                " https://existing.example/announce ",
                "https://new.example/announce",
                "https://new.example/announce",
                "",
                "https://CASE.example/announce"
            ],
            rpcVersion: 18,
            rpc: rpc
        )
        let plan = try XCTUnwrap(plannedMerge)

        XCTAssertEqual(plan.target, .hash("hash-42"))
        XCTAssertEqual(plan.torrentName, "Existing torrent")
        XCTAssertEqual(plan.missingTrackerURLs, [
            "https://new.example/announce",
            "https://CASE.example/announce"
        ])
        XCTAssertTrue(plan.confirmationMessage.contains("https://new.example/announce"))
        XCTAssertTrue(plan.confirmationMessage.contains("https://CASE.example/announce"))
        let state = await rpc.state
        XCTAssertEqual(state.fetchCallCount, 1)
        XCTAssertEqual(state.addCallCount, 0)
    }

    func testApplyUsesOnlyConfirmedPlanTarget() async throws {
        let rpc = DuplicateTrackerRPCStub()
        let plan = TorrentDuplicateTrackerPlan(
            target: .id(42),
            torrentName: "Existing",
            missingTrackerURLs: [
                "https://new.example/announce",
                "udp://second.example:6969/announce"
            ]
        )

        try await TorrentDuplicateTrackerMerge().apply(plan, rpc: rpc)

        let state = await rpc.state
        XCTAssertEqual(state.addCallCount, 1)
        XCTAssertEqual(state.addedTarget, .id(42))
        XCTAssertEqual(state.addedTrackers, plan.missingTrackerURLs)
    }

    func testCancellingAfterPlanningPerformsNoTrackerRPC() async throws {
        let rpc = DuplicateTrackerRPCStub()
        let result = try duplicateResult(id: 42, hashString: "hash-42")

        let plan = try await TorrentDuplicateTrackerMerge().planIfNeeded(
            addResult: result,
            localTrackerURLs: ["https://new.example/announce"],
            rpcVersion: 18,
            rpc: rpc
        )

        XCTAssertNotNil(plan)
        let state = await rpc.state
        XCTAssertEqual(state.fetchCallCount, 1)
        XCTAssertEqual(state.addCallCount, 0)
    }

    func testDuplicateTrackerPlanningRequiresRPC10WhenTrackersExist() async throws {
        let rpc = DuplicateTrackerRPCStub()
        let result = try duplicateResult(id: 42, hashString: "hash-42")

        do {
            _ = try await TorrentDuplicateTrackerMerge().planIfNeeded(
                addResult: result,
                localTrackerURLs: ["https://tracker.example/announce"],
                rpcVersion: 9,
                rpc: rpc
            )
            XCTFail("tracker planning should be gated below RPC 10")
        } catch TransmissionRPCError.unsupportedRPCVersion(let feature, let required, let actual) {
            XCTAssertEqual(feature, "Updating trackers for a duplicate torrent")
            XCTAssertEqual(required, 10)
            XCTAssertEqual(actual, 9)
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        let state = await rpc.state
        XCTAssertEqual(state.fetchCallCount, 0)
    }

    func testDuplicateTrackerPlanningRejectsMissingIdentityWithoutRPCWork() async throws {
        let rpc = DuplicateTrackerRPCStub()
        let result = try duplicateResult(id: nil, hashString: " ")

        do {
            _ = try await TorrentDuplicateTrackerMerge().planIfNeeded(
                addResult: result,
                localTrackerURLs: ["https://tracker.example/announce"],
                rpcVersion: 18,
                rpc: rpc
            )
            XCTFail("duplicate planning should require a stable identity")
        } catch let error as TorrentDuplicateTrackerMergeError {
            XCTAssertEqual(error, .missingIdentity)
        }

        let state = await rpc.state
        XCTAssertEqual(state.fetchCallCount, 0)
    }

    func testDuplicateTrackerPlanningSurfacesMissingDaemonTorrent() async throws {
        let rpc = DuplicateTrackerRPCStub(snapshot: nil)
        let result = try duplicateResult(id: 42, hashString: "hash-42")

        do {
            _ = try await TorrentDuplicateTrackerMerge().planIfNeeded(
                addResult: result,
                localTrackerURLs: ["https://tracker.example/announce"],
                rpcVersion: 18,
                rpc: rpc
            )
            XCTFail("missing duplicate should surface an error")
        } catch let error as TorrentDuplicateTrackerMergeError {
            XCTAssertEqual(error, .torrentNotFound)
        }
    }

    func testPlanningAndApplyRethrowCancellationWithoutWrapping() async throws {
        let result = try duplicateResult(id: 42, hashString: "hash-42")
        let planningRPC = DuplicateTrackerRPCStub(cancelFetch: true)

        do {
            _ = try await TorrentDuplicateTrackerMerge().planIfNeeded(
                addResult: result,
                localTrackerURLs: ["https://tracker.example/announce"],
                rpcVersion: 18,
                rpc: planningRPC
            )
            XCTFail("planning cancellation should be rethrown")
        } catch is CancellationError {
        } catch {
            XCTFail("unexpected wrapped cancellation: \(error)")
        }

        let applyRPC = DuplicateTrackerRPCStub(cancelAdd: true)
        let plan = TorrentDuplicateTrackerPlan(
            target: .hash("hash-42"),
            torrentName: nil,
            missingTrackerURLs: ["https://tracker.example/announce"]
        )
        do {
            try await TorrentDuplicateTrackerMerge().apply(plan, rpc: applyRPC)
            XCTFail("apply cancellation should be rethrown")
        } catch is CancellationError {
        } catch {
            XCTFail("unexpected wrapped cancellation: \(error)")
        }
    }

    func testPlanningAndApplyWrapNonCancellationFailuresWithContext() async throws {
        let result = try duplicateResult(id: 42, hashString: "hash-42")
        let planningRPC = DuplicateTrackerRPCStub(failFetch: true)

        do {
            _ = try await TorrentDuplicateTrackerMerge().planIfNeeded(
                addResult: result,
                localTrackerURLs: ["https://tracker.example/announce"],
                rpcVersion: 18,
                rpc: planningRPC
            )
            XCTFail("fetch failure should surface context")
        } catch TorrentDuplicateTrackerMergeError.comparisonFailed(let message) {
            XCTAssertTrue(message.contains("RPC arguments"))
        }

        let applyRPC = DuplicateTrackerRPCStub(failAdd: true)
        let plan = TorrentDuplicateTrackerPlan(
            target: .id(42),
            torrentName: nil,
            missingTrackerURLs: ["https://tracker.example/announce"]
        )
        do {
            try await TorrentDuplicateTrackerMerge().apply(plan, rpc: applyRPC)
            XCTFail("update failure should surface context")
        } catch TorrentDuplicateTrackerMergeError.updateFailed(let message) {
            XCTAssertTrue(message.contains("tracker rejected"))
        }
    }

    func testClientHashLookupFallbackReturnsConfirmedIDTarget() async throws {
        let recorder = DuplicateTrackerRequestRecorder()
        DuplicateTrackerMockURLProtocol.requestHandler = { request in
            let body = try request.decodedActionBody()
            recorder.record(body)
            if recorder.requests.count == 1 {
                return Self.response(body: #"{"result":"invalid argument","arguments":{}}"#)
            }
            return Self.response(
                body: #"{"result":"success","arguments":{"torrents":[{"id":42,"hashString":"hash-42","trackers":[{"announce":"https://existing.example/announce"}]}]}}"#
            )
        }
        let client = TransmissionRPCClient(profile: .localDefault, urlSession: mockSession())

        let fetchedSnapshot = try await client.fetchDuplicateTorrentTrackers(
            hashString: "hash-42",
            id: 42
        )
        let snapshot = try XCTUnwrap(fetchedSnapshot)

        XCTAssertEqual(snapshot.target, .id(42))
        XCTAssertEqual(snapshot.id, 42)
        XCTAssertEqual(snapshot.announceURLs, ["https://existing.example/announce"])
        XCTAssertEqual(recorder.requests.map { $0.arguments["ids"] }, [
            .array([.string("hash-42")]),
            .array([.int(42)])
        ])
    }

    func testClientUpdateUsesConfirmedIDWithoutRetryingRejectedHash() async throws {
        let recorder = DuplicateTrackerRequestRecorder()
        DuplicateTrackerMockURLProtocol.requestHandler = { request in
            recorder.record(try request.decodedActionBody())
            return Self.response(body: #"{"result":"success"}"#)
        }
        let client = TransmissionRPCClient(profile: .localDefault, urlSession: mockSession())

        try await client.addDuplicateTorrentTrackers(
            [
                " https://new.example/announce ",
                "https://new.example/announce",
                "udp://second.example:6969/announce"
            ],
            target: .id(42)
        )

        XCTAssertEqual(recorder.requests.count, 1)
        XCTAssertEqual(recorder.requests.first?.arguments["ids"], .array([.int(42)]))
        XCTAssertEqual(
            recorder.requests.first?.arguments["trackerAdd"],
            .array([
                .string("https://new.example/announce"),
                .string("udp://second.example:6969/announce")
            ])
        )
    }

    func testClientLookupRejectsFractionalTorrentIDWithoutTrapping() async throws {
        try await assertClientLookupRejectsIDJSON("42.5")
    }

    func testClientLookupRejectsOutOfRangeTorrentIDWithoutTrapping() async throws {
        try await assertClientLookupRejectsIDJSON("1e100")
    }

    func testLegacyDuplicateResultWithoutArgumentsRemainsNonMutatingRPCFailure() async throws {
        let recorder = DuplicateTrackerRequestRecorder()
        DuplicateTrackerMockURLProtocol.requestHandler = { request in
            recorder.record(try request.decodedActionBody())
            return Self.response(body: #"{"result":"duplicate torrent"}"#)
        }
        let client = TransmissionRPCClient(profile: .localDefault, urlSession: mockSession())

        do {
            _ = try await client.addTorrent(
                metainfo: Data([1, 2, 3]),
                startPaused: false,
                downloadDirectory: nil
            )
            XCTFail("legacy duplicate result has no safe identity and must fail")
        } catch TransmissionRPCError.rpcFailure(let message) {
            XCTAssertEqual(message, "duplicate torrent")
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        XCTAssertEqual(recorder.requests.map(\.method), ["torrent-add"])
    }

    @MainActor
    func testAppStoreCancelConfirmationSendsNoTrackerMutationAndCompletesOwnership() async throws {
        let harness = try await makeAppStoreHarness()
        defer { finish(harness) }
        let result = await harness.store.addTorrentFile(
            requestID: harness.request.id,
            presentationOwnerID: harness.ownerID,
            data: Data([1, 2, 3]),
            startPaused: false,
            downloadDirectory: "/downloads",
            localTrackerURLs: ["https://new.example/announce"]
        )
        guard case .confirmDuplicateTrackers(let plan) = result else {
            return XCTFail("duplicate should require tracker confirmation")
        }
        XCTAssertEqual(plan.target, .id(42))
        XCTAssertEqual(harness.recorder.requests.filter { $0.method == "torrent-set" }.count, 0)
        XCTAssertEqual(harness.store.pendingAddTorrent?.id, harness.request.id)
        XCTAssertFalse(harness.store.isAddingTorrent)

        let cancelResult = harness.store.cancelDuplicateTorrentTrackerPlan(
            requestID: harness.request.id,
            presentationOwnerID: harness.ownerID,
            downloadDirectory: "/downloads"
        )

        XCTAssertEqual(cancelResult, .succeeded)
        XCTAssertEqual(harness.recorder.requests.filter { $0.method == "torrent-set" }.count, 0)
        XCTAssertEqual(harness.store.pendingAddTorrent?.id, harness.request.id)
        XCTAssertFalse(harness.store.isAddingTorrent)
    }

    @MainActor
    func testAppStoreAppliesConfirmedIDTargetBeforeCompletingOwnership() async throws {
        let harness = try await makeAppStoreHarness()
        defer { finish(harness) }
        let result = await harness.store.addTorrentFile(
            requestID: harness.request.id,
            presentationOwnerID: harness.ownerID,
            data: Data([1, 2, 3]),
            startPaused: false,
            downloadDirectory: "/downloads",
            localTrackerURLs: ["https://new.example/announce"]
        )
        guard case .confirmDuplicateTrackers(let plan) = result else {
            return XCTFail("duplicate should require tracker confirmation")
        }

        let applyResult = await harness.store.applyDuplicateTorrentTrackerPlan(
            requestID: harness.request.id,
            presentationOwnerID: harness.ownerID,
            plan: plan,
            downloadDirectory: "/downloads"
        )

        XCTAssertEqual(applyResult, .succeeded)
        let trackerSets = harness.recorder.requests.filter { $0.method == "torrent-set" }
        XCTAssertEqual(trackerSets.count, 1)
        XCTAssertEqual(trackerSets.first?.arguments["ids"], .array([.int(42)]))
        XCTAssertEqual(
            trackerSets.first?.arguments["trackerAdd"],
            .array([.string("https://new.example/announce")])
        )
        XCTAssertEqual(harness.store.pendingAddTorrent?.id, harness.request.id)
        XCTAssertFalse(harness.store.isAddingTorrent)
    }

    private func duplicateResult(
        id: Int?,
        hashString: String?,
        name: String? = nil
    ) throws -> TorrentAddResult {
        var duplicate: RPCArguments = [:]
        if let id {
            duplicate["id"] = .int(id)
        }
        if let hashString {
            duplicate["hashString"] = .string(hashString)
        }
        if let name {
            duplicate["name"] = .string(name)
        }
        return try TorrentAddResult(arguments: [
            "torrent-duplicate": .object(duplicate)
        ])
    }

    private func assertClientLookupRejectsIDJSON(_ idJSON: String) async throws {
        DuplicateTrackerMockURLProtocol.requestHandler = { _ in
            Self.response(
                body: #"{"result":"success","arguments":{"torrents":[{"id":\#(idJSON),"hashString":"hash-42","trackers":[]}]}}"#
            )
        }
        let client = TransmissionRPCClient(profile: .localDefault, urlSession: mockSession())

        do {
            _ = try await client.fetchDuplicateTorrentTrackers(
                hashString: "hash-42",
                id: nil
            )
            XCTFail("malformed torrent id should be rejected")
        } catch TransmissionRPCError.invalidArguments {
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    private func mockSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DuplicateTrackerMockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func response(body: String) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: URL(string: "http://127.0.0.1:9091/transmission/rpc")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        return (response, Data(body.utf8))
    }

    private struct AppStoreHarness {
        let store: AppStore
        let ownerID: UUID
        let request: AppStore.PendingAddTorrent
        let recorder: DuplicateTrackerRequestRecorder
    }

    @MainActor
    private func makeAppStoreHarness() async throws -> AppStoreHarness {
        let recorder = DuplicateTrackerRequestRecorder()
        AppStoreMockURLProtocol.requestHandler = { request in
            let body = try request.decodedActionBody()
            recorder.record(body)
            switch body.method {
            case "torrent-add":
                return rpcTestResponse(
                    body: #"{"result":"success","arguments":{"torrent-duplicate":{"id":42,"hashString":"hash-42","name":"Existing"}}}"#
                )
            case "torrent-get" where body.arguments["ids"] == .array([.string("hash-42")]):
                return rpcTestResponse(body: #"{"result":"success","arguments":{"torrents":[]}}"#)
            case "torrent-get" where body.arguments["ids"] == .array([.int(42)]):
                return rpcTestResponse(
                    body: #"{"result":"success","arguments":{"torrents":[{"id":42,"hashString":"hash-42","trackers":[]}]}}"#
                )
            default:
                return appStoreRPCResponse(for: body.method)
            }
        }

        let profileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("profiles.json")
        let profileStore = makePersistedConnectionProfileStore(
            fileURL: profileURL,
            passwordStore: DuplicateTrackerTestPasswordStore()
        )
        let session = makeAppStoreMockSession()
        let store = AppStore(
            profileStore: profileStore,
            userDefaults: UserDefaults(suiteName: UUID().uuidString)!,
            downloadCompletionNotifier: DuplicateTrackerTestNotifier(),
            clientFactory: { profile in
                TransmissionRPCClient(profile: profile, urlSession: session)
            }
        )
        await store.connect()
        let ownerID = UUID()
        store.registerAddTorrentPresentationOwner(ownerID)
        store.requestAddTorrent(fileURL: URL(fileURLWithPath: "/tmp/existing.torrent"))
        let request = try XCTUnwrap(store.pendingAddTorrent)
        return AppStoreHarness(
            store: store,
            ownerID: ownerID,
            request: request,
            recorder: recorder
        )
    }

    @MainActor
    private func finish(_ harness: AppStoreHarness) {
        harness.store.addTorrentPresentationWillDismiss(
            requestID: harness.request.id,
            ownerID: harness.ownerID
        )
        harness.store.addTorrentSheetDidDismiss(
            requestID: harness.request.id,
            ownerID: harness.ownerID
        )
        harness.store.disconnect()
    }
}

private actor DuplicateTrackerRPCStub: TorrentDuplicateTrackerRPC {
    struct State: Equatable, Sendable {
        var fetchCallCount = 0
        var fetchedHashString: String?
        var fetchedID: Int?
        var addCallCount = 0
        var addedTrackers: [String] = []
        var addedTarget: TorrentDuplicateTrackerTarget?
    }

    private(set) var state = State()

    private let snapshot: TorrentDuplicateTrackerSnapshot?
    private let failFetch: Bool
    private let failAdd: Bool
    private let cancelFetch: Bool
    private let cancelAdd: Bool

    init(
        snapshot: TorrentDuplicateTrackerSnapshot? = TorrentDuplicateTrackerSnapshot(
            target: .hash("hash-42"),
            id: 42,
            hashString: "hash-42",
            announceURLs: []
        ),
        failFetch: Bool = false,
        failAdd: Bool = false,
        cancelFetch: Bool = false,
        cancelAdd: Bool = false
    ) {
        self.snapshot = snapshot
        self.failFetch = failFetch
        self.failAdd = failAdd
        self.cancelFetch = cancelFetch
        self.cancelAdd = cancelAdd
    }

    func fetchDuplicateTorrentTrackers(
        hashString: String?,
        id: Int?
    ) async throws -> TorrentDuplicateTrackerSnapshot? {
        state.fetchCallCount += 1
        state.fetchedHashString = hashString
        state.fetchedID = id
        if cancelFetch {
            throw CancellationError()
        }
        if failFetch {
            throw TransmissionRPCError.invalidArguments
        }
        return snapshot
    }

    func addDuplicateTorrentTrackers(
        _ announceURLs: [String],
        target: TorrentDuplicateTrackerTarget
    ) async throws {
        state.addCallCount += 1
        if cancelAdd {
            throw CancellationError()
        }
        if failAdd {
            throw TransmissionRPCError.rpcFailure("tracker rejected")
        }
        state.addedTrackers = announceURLs
        state.addedTarget = target
    }
}

private final class DuplicateTrackerRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedRequests: [RPCRequest] = []

    var requests: [RPCRequest] {
        lock.withLock { recordedRequests }
    }

    func record(_ request: RPCRequest) {
        lock.withLock {
            recordedRequests.append(request)
        }
    }
}

private final class DuplicateTrackerMockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: TransmissionRPCError.invalidResponse)
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class DuplicateTrackerTestPasswordStore: ConnectionPasswordStoring {
    func password(for profileID: ConnectionProfile.ID) throws -> String? {
        nil
    }

    func setPassword(_ password: String, for profileID: ConnectionProfile.ID) throws {}

    func removePassword(for profileID: ConnectionProfile.ID) throws {}
}

private final class DuplicateTrackerTestNotifier: DownloadCompletionNotifying {
    func notifyDownloadCompleted(torrentName: String) {}
}
