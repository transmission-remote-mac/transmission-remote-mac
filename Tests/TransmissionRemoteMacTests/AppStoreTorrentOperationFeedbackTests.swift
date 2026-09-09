// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation
import XCTest
@testable import TransmissionRemoteMac

@MainActor
final class AppStoreTorrentOperationFeedbackTests: XCTestCase {
    override func tearDown() {
        AppStoreMockURLProtocol.requestHandler = nil
        AppStoreMockURLProtocol.requestDidFinish = nil
        super.tearDown()
    }

    func testStandardMonitoringPolicyKeepsLegacyAndLongVerifyWindowsBounded() {
        XCTAssertEqual(
            TorrentOperationMonitoringPolicy.standard.schedule(for: .setLocation),
            .init(pollInterval: .seconds(1), maximumPollCount: 20)
        )
        XCTAssertEqual(
            TorrentOperationMonitoringPolicy.standard.schedule(for: .verify),
            .init(pollInterval: .seconds(5), maximumPollCount: 360)
        )
    }

    func testPostAcknowledgementObservationIgnoresEmptyUnrelatedAndPartialUpdates() {
        let first = OperationFeedbackTorrent.fixture(id: 1).hash
        let second = OperationFeedbackTorrent.fixture(id: 2).hash
        var observation = TorrentOperationPostAcknowledgementObservation(
            targetHashes: [first, second],
            acknowledgementRequestSequenceWatermark: 10
        )

        observation.consume([:])
        observation.consume([OperationFeedbackTorrent.fixture(id: 99).hash: 11])
        observation.consume([first: 9, second: 10])
        XCTAssertFalse(observation.hasObservedEveryTarget)

        observation.consume([first: 11])
        XCTAssertFalse(observation.hasObservedEveryTarget)

        observation.consume([second: 12])
        XCTAssertTrue(observation.hasObservedEveryTarget)
    }

    func testConnectionMonitorCoalescesDueTargetsAndBacksOffLargeBatches() {
        let policy = TorrentOperationMonitoringPolicy.standard
        let start = Duration.seconds(100)
        XCTAssertEqual(policy.pollUnitScale(targetCount: 1, completedPollCount: 0), 1)
        XCTAssertEqual(policy.pollUnitScale(targetCount: 1_000, completedPollCount: 0), 4)
        XCTAssertEqual(policy.pollUnitScale(targetCount: 1_000, completedPollCount: 12), 16)

        let firstOperation = UUID()
        let secondOperation = UUID()
        var coordinator = TorrentOperationMonitoringCoordinator(policy: policy)
        coordinator.register(
            operationID: firstOperation,
            kind: .setLocation,
            torrentIDs: [1, 2],
            now: start
        )
        coordinator.register(
            operationID: secondOperation,
            kind: .moveData,
            torrentIDs: [2, 3],
            now: start
        )

        let batch = coordinator.advance(at: start + .seconds(1))

        XCTAssertEqual(batch.torrentIDs, [1, 2, 3])
    }

    func testRegisteringAnotherOperationDoesNotPostponeExistingDeadline() {
        let clock = TestPollingClock()
        let policy = TorrentOperationMonitoringPolicy.standard
        let firstOperation = UUID()
        let secondOperation = UUID()
        var coordinator = TorrentOperationMonitoringCoordinator(policy: policy)
        coordinator.register(
            operationID: firstOperation,
            kind: .setLocation,
            torrentIDs: [1],
            now: clock.now()
        )

        clock.advance(by: .milliseconds(900))
        coordinator.register(
            operationID: secondOperation,
            kind: .setLocation,
            torrentIDs: [2],
            now: clock.now()
        )

        XCTAssertEqual(coordinator.nextDeadline, .seconds(1))
        clock.advance(by: .milliseconds(100))
        let batch = coordinator.advance(at: clock.now())
        XCTAssertEqual(batch.torrentIDs, [1])
    }

    func testVerifyRemainsScheduledAtMaximumBackoffAfterInitialWindow() {
        let clock = TestPollingClock()
        let operationID = UUID()
        let policy = TorrentOperationMonitoringPolicy(
            locationAndRename: .init(pollInterval: .seconds(1), maximumPollCount: 1),
            verify: .init(pollInterval: .seconds(5), maximumPollCount: 1)
        )
        var coordinator = TorrentOperationMonitoringCoordinator(policy: policy)
        coordinator.register(
            operationID: operationID,
            kind: .verify,
            torrentIDs: [1],
            now: clock.now()
        )

        clock.advance(by: .seconds(5))
        let initialWindow = coordinator.advance(at: clock.now())

        XCTAssertEqual(initialWindow.torrentIDs, [1])
        XCTAssertTrue(initialWindow.exhaustedOperationIDs.isEmpty)
        XCTAssertEqual(coordinator.nextDeadline, .seconds(25))

        clock.advance(by: .seconds(20))
        let maximumBackoff = coordinator.advance(at: clock.now())
        XCTAssertEqual(maximumBackoff.torrentIDs, [1])
        XCTAssertTrue(maximumBackoff.exhaustedOperationIDs.isEmpty)
    }

    func testVerifyCancellationSendsNoRPC() async throws {
        let server = OperationFeedbackRPCServer(torrents: [.fixture(id: 1)])
        let store = try makeStore(server: server)
        await store.connect()
        store.selectedTorrentIDs = [1]

        store.requestVerifySelected()

        XCTAssertEqual(store.verifyConfirmation?.title, "Verify Torrent 1?")
        XCTAssertTrue(store.verifyConfirmation?.message.contains("long time") == true)
        store.cancelVerifyConfirmation()
        await Task.yield()

        XCTAssertNil(store.verifyConfirmation)
        XCTAssertEqual(server.verifyRequestCount, 0)
        XCTAssertTrue(store.torrentOperationFeedback.isEmpty)
        store.disconnect()
    }

    func testVerifyUsesFrozenHashesAcrossSelectionChangeAndCompletesAfterRunning() async throws {
        let first = OperationFeedbackTorrent.fixture(id: 1)
        let second = OperationFeedbackTorrent.fixture(id: 2)
        let server = OperationFeedbackRPCServer(torrents: [first, second])
        let store = try makeStore(server: server)
        await store.connect()
        store.selectedTorrentIDs = [1, 2]
        store.requestVerifySelected()
        store.selectedTorrentIDs = [2]

        await store.confirmVerify()

        XCTAssertEqual(server.verifyHashes, [first.hash, second.hash])
        XCTAssertEqual(store.torrentOperationFeedback.count, 1)
        XCTAssertEqual(store.torrentOperationFeedback.first?.phase, .running)
        XCTAssertEqual(store.torrentOperationFeedback.first?.ownership.torrentHashes, [first.hash, second.hash])

        let didComplete = await refreshUntil(store: store) {
            store.torrentOperationFeedback.first?.phase == .completed
        }
        XCTAssertTrue(didComplete)
        XCTAssertEqual(store.selectedTorrentIDs, [2])
        store.disconnect()
    }

    func testVerifyRPCFailurePublishesFailedFeedback() async throws {
        let server = OperationFeedbackRPCServer(
            torrents: [.fixture(id: 1)],
            verifyBehavior: .fail
        )
        let store = try makeStore(server: server)
        await store.connect()
        store.selectedTorrentIDs = [1]
        store.requestVerifySelected()

        await store.confirmVerify()

        guard case .failed(let message)? = store.torrentOperationFeedback.first?.phase else {
            return XCTFail("Expected failed verify feedback")
        }
        XCTAssertTrue(message.contains("Verify rejected"))
        XCTAssertEqual(server.verifyRequestCount, 1)
        store.disconnect()
    }

    func testFastVerifyCompletesFromFirstNewAuthoritativeSnapshot() async throws {
        let server = OperationFeedbackRPCServer(
            torrents: [.fixture(id: 1)],
            verifyBehavior: .fast
        )
        let store = try makeStore(server: server)
        await store.connect()
        store.selectedTorrentIDs = [1]
        store.requestVerifySelected()

        await store.confirmVerify()

        let didComplete = await refreshUntil(store: store) {
            store.torrentOperationFeedback.first?.phase == .completed
        }
        XCTAssertTrue(didComplete)
        XCTAssertEqual(server.verifyRequestCount, 1)
        store.disconnect()
    }

    func testPreAcknowledgementListResponseCannotCompleteFastVerify() async throws {
        let server = OperationFeedbackRPCServer(
            torrents: [.fixture(id: 1)],
            verifyBehavior: .fast
        )
        let store = try makeStore(server: server)
        await store.connect()
        store.selectedTorrentIDs = [1]
        server.prepareListRequestRace()

        let preAcknowledgementRefresh = Task { @MainActor in
            await store.refresh()
        }
        guard await waitUntil(condition: { server.preAcknowledgementListRequestDidStart }) else {
            server.releasePreAcknowledgementListResponse()
            server.releasePostAcknowledgementListResponses()
            return XCTFail("Expected the pre-acknowledgement list request to start")
        }

        store.requestVerifySelected()
        await store.confirmVerify()

        XCTAssertEqual(server.verifyRequestCount, 1)
        XCTAssertEqual(store.torrentOperationFeedback.first?.phase, .running)
        server.releasePreAcknowledgementListResponse()
        guard await waitUntil(condition: { server.postAcknowledgementListRequestDidStart }) else {
            server.releasePostAcknowledgementListResponses()
            await preAcknowledgementRefresh.value
            return XCTFail("Expected a genuinely post-acknowledgement list request")
        }

        XCTAssertEqual(store.torrentOperationFeedback.first?.phase, .running)
        server.releasePostAcknowledgementListResponses()
        await preAcknowledgementRefresh.value
        let didComplete = await refreshUntil(store: store) {
            store.torrentOperationFeedback.first?.phase == .completed
        }

        XCTAssertTrue(didComplete)
        store.disconnect()
    }

    func testVerifyMonitoringExhaustionRetainsRunningWhileDaemonIsChecking() async throws {
        let clock = TestPollingClock()
        let server = OperationFeedbackRPCServer(
            torrents: [.fixture(id: 1)],
            verifyBehavior: .neverCompletes
        )
        let fastPolicy = TorrentOperationMonitoringPolicy(
            locationAndRename: .init(pollInterval: .seconds(1), maximumPollCount: 1),
            verify: .init(pollInterval: .seconds(1), maximumPollCount: 1)
        )
        let store = try makeStore(
            server: server,
            monitoringPolicy: fastPolicy,
            monitoringClock: clock
        )
        await store.connect()
        store.selectedTorrentIDs = [1]
        store.requestVerifySelected()

        await store.confirmVerify()
        let requestCountBeforeFallback = server.torrentGetRequestCount
        let didScheduleFallback = await waitUntil {
            clock.pendingSleepCount == 1
        }
        XCTAssertTrue(didScheduleFallback)
        clock.advance(by: .seconds(1))
        let didObserveFallback = await waitUntil {
            server.torrentGetRequestCount > requestCountBeforeFallback
        }

        XCTAssertTrue(didObserveFallback)
        XCTAssertEqual(store.torrentOperationFeedback.first?.phase, .running)
        XCTAssertNil(store.errorMessage)
        store.disconnect()
    }

    func testVerifyBeyondInitialFallbackWindowCompletesWithoutManualRefresh() async throws {
        let clock = TestPollingClock()
        let server = OperationFeedbackRPCServer(
            torrents: [.fixture(id: 1)],
            verifyBehavior: .completesAfterFallbackExhaustion
        )
        let fastPolicy = TorrentOperationMonitoringPolicy(
            locationAndRename: .init(pollInterval: .seconds(1), maximumPollCount: 1),
            verify: .init(pollInterval: .seconds(1), maximumPollCount: 1)
        )
        let store = try makeStore(
            server: server,
            monitoringPolicy: fastPolicy,
            monitoringClock: clock
        )
        await store.connect()
        store.selectedTorrentIDs = [1]
        store.requestVerifySelected()

        await store.confirmVerify()
        let didScheduleInitialFallback = await waitUntil {
            clock.pendingSleepCount == 1
        }
        XCTAssertTrue(didScheduleInitialFallback)
        let requestCountBeforeInitialFallback = server.postAcknowledgementTorrentGetRequestCount
        clock.advance(by: .seconds(1))
        let didReachMaximumBackoff = await waitUntil {
            server.postAcknowledgementTorrentGetRequestCount > requestCountBeforeInitialFallback
                && clock.pendingSleepCount == 1
        }
        XCTAssertTrue(didReachMaximumBackoff)
        XCTAssertEqual(store.torrentOperationFeedback.first?.phase, .running)
        server.completeVerifyNow()
        clock.advance(by: .seconds(4))
        let didComplete = await waitUntil(timeout: .seconds(2)) {
            store.torrentOperationFeedback.first?.phase == .completed
        }

        XCTAssertTrue(didComplete)
        store.disconnect()
    }

    func testDisconnectInvalidatesPendingConfirmationBeforeDispatch() async throws {
        let server = OperationFeedbackRPCServer(torrents: [.fixture(id: 1)])
        let store = try makeStore(server: server)
        await store.connect()
        store.selectedTorrentIDs = [1]
        store.requestVerifySelected()

        store.disconnect()
        await store.confirmVerify()

        XCTAssertNil(store.verifyConfirmation)
        XCTAssertEqual(server.verifyRequestCount, 0)
        XCTAssertTrue(store.torrentOperationFeedback.isEmpty)
    }

    func testHashReplacementAtFrozenNumericIDInvalidatesFeedback() async throws {
        let torrent = OperationFeedbackTorrent.fixture(id: 1)
        let server = OperationFeedbackRPCServer(
            torrents: [torrent],
            verifyBehavior: .replaceHashAfterAcknowledgement
        )
        let store = try makeStore(server: server)
        await store.connect()
        store.selectedTorrentIDs = [1]
        store.requestVerifySelected()

        await store.confirmVerify()

        let didInvalidate = await refreshUntil(store: store) {
            store.torrentOperationFeedback.isEmpty
                && store.torrents.first?.hashString != torrent.hash
        }
        XCTAssertEqual(server.verifyRequestCount, 1)
        XCTAssertTrue(didInvalidate)
        store.disconnect()
    }

    func testHashReplacementInvalidatesSubmittedFeedbackBeforeBlockedRPCReturns() async throws {
        let torrent = OperationFeedbackTorrent.fixture(id: 1)
        let server = OperationFeedbackRPCServer(
            torrents: [torrent],
            blockedMethod: "torrent-verify"
        )
        let store = try makeStore(server: server)
        await store.connect()
        store.selectedTorrentIDs = [torrent.id]
        store.requestVerifySelected()
        let confirmationTask = Task { @MainActor in
            await store.confirmVerify()
        }

        let didSubmit = await waitUntil { server.blockedRequestDidStart }
        XCTAssertTrue(didSubmit)
        XCTAssertEqual(store.torrentOperationFeedback.first?.phase, .submitted)

        server.replaceTorrentHash(atID: torrent.id)
        await store.refresh()

        XCTAssertTrue(store.torrentOperationFeedback.isEmpty)
        server.releaseBlockedRequest()
        await confirmationTask.value
        XCTAssertTrue(store.torrentOperationFeedback.isEmpty)
        store.disconnect()
    }

    func testRetainedCompletedFeedbackStillInvalidatesAfterHashReplacement() async throws {
        let server = OperationFeedbackRPCServer(
            torrents: [.fixture(id: 1)],
            verifyBehavior: .fast
        )
        let store = try makeStore(server: server)
        await store.connect()
        store.selectedTorrentIDs = [1]
        store.requestVerifySelected()
        await store.confirmVerify()
        let didComplete = await refreshUntil(store: store) {
            store.torrentOperationFeedback.first?.phase == .completed
        }
        XCTAssertTrue(didComplete)
        let snapshotCount = store.torrentOperationReconciliationSnapshotCount

        server.replaceTorrentHash(atID: 1)
        await store.refresh()

        XCTAssertGreaterThan(store.torrentOperationReconciliationSnapshotCount, snapshotCount)
        XCTAssertTrue(store.torrentOperationFeedback.isEmpty)
        store.disconnect()
    }

    func testOneThousandTargetsUseOneVerifyRequestAndOneFeedbackRow() async throws {
        let torrents = (1...1_000).map { OperationFeedbackTorrent.fixture(id: $0) }
        let server = OperationFeedbackRPCServer(torrents: torrents)
        let store = try makeStore(server: server)
        await store.connect()
        store.selectedTorrentIDs = Set(torrents.map(\.id))
        store.requestVerifySelected()

        await store.confirmVerify()

        XCTAssertEqual(server.verifyRequestCount, 1)
        XCTAssertEqual(server.verifyHashes.count, 1_000)
        XCTAssertEqual(store.torrentOperationFeedback.count, 1)
        XCTAssertEqual(store.torrentOperationFeedback.first?.phase, .running)
        store.disconnect()
    }

    func testSetLocationPreservesExactBytesAndWritesHistoryOnlyAfterCompletion() async throws {
        let destination = "/srv/Media Library "
        let prompter = OperationFeedbackPrompter(locationResponses: [destination])
        let server = OperationFeedbackRPCServer(
            torrents: [.fixture(id: 1)],
            holdsMutationPublication: true
        )
        let store = try makeStore(server: server, prompter: prompter)
        await store.connect()
        store.selectedTorrentIDs = [1]

        store.requestSetSelectedLocation()
        let didStart = await waitUntil {
            store.torrentOperationFeedback.first?.phase.stage == .running
        }

        XCTAssertTrue(didStart)
        XCTAssertEqual(server.recordedLocations, [destination])
        XCTAssertEqual(server.recordedMoveFlags, [false])
        XCTAssertFalse(store.selectedProfile.transferPreferences.moveDestinationHistory.contains(destination))

        server.releaseMutationPublication()
        let didComplete = await refreshUntil(store: store) {
            store.torrentOperationFeedback.first?.phase == .completed
        }
        XCTAssertTrue(didComplete)
        XCTAssertEqual(store.selectedProfile.transferPreferences.moveDestinationHistory.first, destination)
        store.disconnect()
    }

    func testMoveDataUsesMoveTrueAndCompletesThroughAuthoritativeRefresh() async throws {
        let prompter = OperationFeedbackPrompter(locationResponses: ["/srv/moved"])
        let server = OperationFeedbackRPCServer(
            torrents: [.fixture(id: 1)],
            holdsMutationPublication: true
        )
        let store = try makeStore(server: server, prompter: prompter)
        await store.connect()
        store.selectedTorrentIDs = [1]

        store.requestMoveSelectedData()
        let didStart = await waitUntil {
            store.torrentOperationFeedback.first?.phase.stage == .running
        }
        XCTAssertTrue(didStart)
        XCTAssertEqual(server.recordedMoveFlags, [true])

        server.releaseMutationPublication()
        let didComplete = await refreshUntil(store: store) {
            store.torrentOperationFeedback.first?.phase == .completed
        }
        XCTAssertTrue(didComplete)
        store.disconnect()
    }

    func testRenameNormalizesPromptIntentAndPublishesRunningThenCompleted() async throws {
        let prompter = OperationFeedbackPrompter(renameResponses: ["  New Name  "])
        let server = OperationFeedbackRPCServer(
            torrents: [.fixture(id: 1)],
            blockedMethod: "torrent-rename-path",
            holdsMutationPublication: true
        )
        let store = try makeStore(server: server, prompter: prompter)
        await store.connect()
        store.selectedTorrentIDs = [1]

        store.requestRenameSelectedTorrent()
        let didSubmit = await waitUntil { server.blockedRequestDidStart }

        XCTAssertTrue(didSubmit)
        XCTAssertEqual(store.torrentOperationFeedback.first?.phase, .submitted)
        server.releaseBlockedRequest()
        let didStart = await waitUntil {
            store.torrentOperationFeedback.first?.phase.stage == .running
        }

        XCTAssertTrue(didStart)
        XCTAssertEqual(server.recordedRenameNames, ["New Name"])
        XCTAssertEqual(store.torrentOperationFeedback.first?.ownership.kind, .rename)

        server.releaseMutationPublication()
        let didComplete = await refreshUntil(store: store) {
            store.torrentOperationFeedback.first?.phase == .completed
        }
        XCTAssertTrue(didComplete)
        store.disconnect()
    }

    func testRenameRPCFailureStaysInOperationFeedback() async throws {
        let prompter = OperationFeedbackPrompter(renameResponses: ["New Name"])
        let server = OperationFeedbackRPCServer(
            torrents: [.fixture(id: 1)],
            failingMethod: "torrent-rename-path"
        )
        let store = try makeStore(server: server, prompter: prompter)
        await store.connect()
        store.selectedTorrentIDs = [1]

        store.requestRenameSelectedTorrent()
        let didFail = await waitUntil {
            store.torrentOperationFeedback.first?.phase.stage == .failed
        }

        XCTAssertTrue(didFail)
        XCTAssertNil(store.errorMessage)
        store.disconnect()
    }

    private func makeStore(
        server: OperationFeedbackRPCServer,
        prompter: (any TorrentOperationPrompting)? = nil,
        monitoringPolicy: TorrentOperationMonitoringPolicy = .standard,
        monitoringClock: any PollingClock = ContinuousPollingClock()
    ) throws -> AppStore {
        AppStoreMockURLProtocol.requestHandler = server.response
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directoryURL)
        }

        var profile = ConnectionProfile.localDefault
        profile.connectOnLaunch = false
        profile.autoReconnect = false
        let profileStore = ConnectionProfileStore(
            fileURL: directoryURL.appendingPathComponent("profiles.json"),
            passwordStore: OperationFeedbackPasswordStore()
        )
        try profileStore.save(
            try ConnectionProfileCollection(
                profiles: [profile],
                selectedProfileID: profile.id
            )
        )
        let suiteName = "AppStoreTorrentOperationFeedbackTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return AppStore(
            profileStore: profileStore,
            userDefaults: defaults,
            downloadCompletionNotifier: OperationFeedbackNotifier(),
            torrentOperationPrompter: prompter,
            torrentOperationMonitoringPolicy: monitoringPolicy,
            torrentOperationMonitoringClock: monitoringClock,
            selectionDebounceDuration: .zero,
            clientFactory: { profile in
                TransmissionRPCClient(profile: profile, urlSession: makeAppStoreMockSession())
            }
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private func refreshUntil(
        store: AppStore,
        timeout: Duration = .seconds(2),
        condition: @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            await store.refresh()
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}

private struct OperationFeedbackTorrent {
    let id: Int
    let hash: String
    let name: String
    let destination: String

    static func fixture(id: Int) -> OperationFeedbackTorrent {
        let suffix = String(id, radix: 16)
        return OperationFeedbackTorrent(
            id: id,
            hash: String(repeating: "0", count: 40 - suffix.count) + suffix,
            name: "Torrent \(id)",
            destination: "/downloads"
        )
    }
}

private final class OperationFeedbackRPCServer: @unchecked Sendable {
    enum VerifyBehavior: Equatable {
        case normal
        case fast
        case neverCompletes
        case completesAfterFallbackExhaustion
        case fail
        case replaceHashAfterAcknowledgement
    }

    private let lock = NSLock()
    private var torrents: [OperationFeedbackTorrent]
    private let verifyBehavior: VerifyBehavior
    private let failingMethod: String?
    private let blockedMethod: String?
    private let holdsMutationPublication: Bool
    private let blockedRequestGate = DispatchSemaphore(value: 0)
    private let preAcknowledgementListResponseGate = DispatchSemaphore(value: 0)
    private let postAcknowledgementListResponseGate = DispatchSemaphore(value: 0)
    private var storedBlockedRequestDidStart = false
    private var listRequestRaceIsPrepared = false
    private var shouldBlockNextListRequest = false
    private var storedPreAcknowledgementListRequestDidStart = false
    private var blockedPostAcknowledgementListResponseCount = 0
    private var mutationPublicationReleased = false
    private var didAcknowledgeVerify = false
    private var verifyCompletionReleased = false
    private var didServeVerifyingSnapshot = false
    private var pendingMutation: PendingMutation?
    private var postMutationFetchCount = 0
    private var recordedVerifyHashes: [String] = []
    private var recordedVerifyRequestCount = 0
    private var recordedTorrentGetRequestCount = 0
    private var recordedPostAcknowledgementTorrentGetRequestCount = 0
    private var storedLocations: [String] = []
    private var storedMoveFlags: [Bool] = []
    private var storedRenameNames: [String] = []

    private enum PendingMutation {
        case location(String)
        case rename(String)
    }

    init(
        torrents: [OperationFeedbackTorrent],
        verifyBehavior: VerifyBehavior = .normal,
        failingMethod: String? = nil,
        blockedMethod: String? = nil,
        holdsMutationPublication: Bool = false
    ) {
        self.torrents = torrents
        self.verifyBehavior = verifyBehavior
        self.failingMethod = failingMethod
        self.blockedMethod = blockedMethod
        self.holdsMutationPublication = holdsMutationPublication
    }

    var verifyHashes: [String] {
        lock.withLock { recordedVerifyHashes }
    }

    var verifyRequestCount: Int {
        lock.withLock { recordedVerifyRequestCount }
    }

    var torrentGetRequestCount: Int {
        lock.withLock { recordedTorrentGetRequestCount }
    }

    var postAcknowledgementTorrentGetRequestCount: Int {
        lock.withLock { recordedPostAcknowledgementTorrentGetRequestCount }
    }

    var recordedLocations: [String] {
        lock.withLock { storedLocations }
    }

    var recordedMoveFlags: [Bool] {
        lock.withLock { storedMoveFlags }
    }

    var recordedRenameNames: [String] {
        lock.withLock { storedRenameNames }
    }

    var blockedRequestDidStart: Bool {
        lock.withLock { storedBlockedRequestDidStart }
    }

    var preAcknowledgementListRequestDidStart: Bool {
        lock.withLock { storedPreAcknowledgementListRequestDidStart }
    }

    var postAcknowledgementListRequestDidStart: Bool {
        lock.withLock { blockedPostAcknowledgementListResponseCount > 0 }
    }

    func prepareListRequestRace() {
        lock.withLock {
            listRequestRaceIsPrepared = true
            shouldBlockNextListRequest = true
        }
    }

    func releasePreAcknowledgementListResponse() {
        preAcknowledgementListResponseGate.signal()
    }

    func releasePostAcknowledgementListResponses() {
        let responseCount = lock.withLock {
            listRequestRaceIsPrepared = false
            return blockedPostAcknowledgementListResponseCount
        }
        for _ in 0..<responseCount {
            postAcknowledgementListResponseGate.signal()
        }
    }

    func releaseBlockedRequest() {
        blockedRequestGate.signal()
    }

    func releaseMutationPublication() {
        lock.withLock {
            mutationPublicationReleased = true
        }
    }

    func completeVerifyNow() {
        lock.withLock {
            verifyCompletionReleased = true
        }
    }

    func replaceTorrentHash(atID torrentID: Int) {
        lock.withLock {
            guard let index = torrents.firstIndex(where: { $0.id == torrentID }) else { return }
            let current = torrents[index]
            let replacement = OperationFeedbackTorrent.fixture(id: torrentID + 10_000)
            torrents[index] = OperationFeedbackTorrent(
                id: current.id,
                hash: replacement.hash,
                name: current.name,
                destination: current.destination
            )
        }
    }

    func response(for request: URLRequest) throws -> (HTTPURLResponse, Data) {
        let body = try request.operationFeedbackRPCBody()
        if body.isTorrentListRequest {
            let responseGate: DispatchSemaphore? = lock.withLock {
                if shouldBlockNextListRequest {
                    shouldBlockNextListRequest = false
                    storedPreAcknowledgementListRequestDidStart = true
                    return preAcknowledgementListResponseGate
                }
                if listRequestRaceIsPrepared,
                   didAcknowledgeVerify {
                    blockedPostAcknowledgementListResponseCount += 1
                    return postAcknowledgementListResponseGate
                }
                return nil
            }
            _ = responseGate?.wait(timeout: .now() + 2)
        }
        if let blockedMethod, body.method == blockedMethod {
            lock.withLock {
                storedBlockedRequestDidStart = true
            }
            _ = blockedRequestGate.wait(timeout: .now() + 2)
        }
        switch body.method {
        case "torrent-verify":
            return lock.withLock {
                recordedVerifyRequestCount += 1
                recordedVerifyHashes = body.stringIDs
                if verifyBehavior == .fail {
                    return rpcTestResponse(
                        body: #"{"result":"Verify rejected","arguments":{}}"#
                    )
                }
                didAcknowledgeVerify = true
                return rpcTestResponse(body: #"{"result":"success","arguments":{}}"#)
            }

        case "torrent-set-location":
            return lock.withLock {
                guard failingMethod != Optional(body.method) else {
                    return rpcTestResponse(
                        body: #"{"result":"Location rejected","arguments":{}}"#
                    )
                }
                let location = body.location ?? ""
                storedLocations.append(location)
                storedMoveFlags.append(body.moveData ?? false)
                pendingMutation = .location(location)
                postMutationFetchCount = 0
                mutationPublicationReleased = !holdsMutationPublication
                return rpcTestResponse(body: #"{"result":"success","arguments":{}}"#)
            }

        case "torrent-rename-path":
            return lock.withLock {
                guard failingMethod != Optional(body.method) else {
                    return rpcTestResponse(
                        body: #"{"result":"Rename rejected","arguments":{}}"#
                    )
                }
                let name = body.name ?? ""
                storedRenameNames.append(name)
                pendingMutation = .rename(name)
                postMutationFetchCount = 0
                mutationPublicationReleased = !holdsMutationPublication
                return rpcTestResponse(body: #"{"result":"success","arguments":{}}"#)
            }

        case "torrent-get":
            return try lock.withLock {
                // Selected details observe daemon state; they must not consume
                // the fixture's next authoritative list-monitor transition.
                guard body.isTorrentListRequest else {
                    let currentStatus: TorrentStatus = didAcknowledgeVerify && !didServeVerifyingSnapshot
                        ? .checking
                        : .stopped
                    return try Self.torrentResponse(
                        torrents.filter { body.stringIDs.contains($0.hash) },
                        status: currentStatus
                    )
                }
                recordedTorrentGetRequestCount += 1
                if didAcknowledgeVerify {
                    recordedPostAcknowledgementTorrentGetRequestCount += 1
                }
                let status: TorrentStatus
                if didAcknowledgeVerify,
                   verifyBehavior == .completesAfterFallbackExhaustion,
                   !verifyCompletionReleased {
                    status = .checking
                } else if didAcknowledgeVerify,
                   (verifyBehavior == .normal || verifyBehavior == .neverCompletes),
                   (!didServeVerifyingSnapshot || verifyBehavior == .neverCompletes) {
                    status = .checking
                    didServeVerifyingSnapshot = true
                } else {
                    status = .stopped
                }
                var responseTorrents = torrents
                if didAcknowledgeVerify,
                   verifyBehavior == .replaceHashAfterAcknowledgement,
                   !responseTorrents.isEmpty {
                    let replacement = OperationFeedbackTorrent.fixture(
                        id: responseTorrents[0].id + 10_000
                    )
                    responseTorrents[0] = OperationFeedbackTorrent(
                        id: responseTorrents[0].id,
                        hash: replacement.hash,
                        name: replacement.name,
                        destination: replacement.destination
                    )
                }
                if let pendingMutation {
                    postMutationFetchCount += 1
                    let mayPublishMutation = holdsMutationPublication
                        ? mutationPublicationReleased
                        : postMutationFetchCount >= 2
                    if mayPublishMutation {
                        responseTorrents = responseTorrents.map { torrent in
                            switch pendingMutation {
                            case .location(let destination):
                                OperationFeedbackTorrent(
                                    id: torrent.id,
                                    hash: torrent.hash,
                                    name: torrent.name,
                                    destination: destination
                                )
                            case .rename(let name):
                                OperationFeedbackTorrent(
                                    id: torrent.id,
                                    hash: torrent.hash,
                                    name: name,
                                    destination: torrent.destination
                                )
                            }
                        }
                        self.torrents = responseTorrents
                        self.pendingMutation = nil
                    }
                }
                return try Self.torrentResponse(responseTorrents, status: status)
            }

        default:
            return appStoreRPCResponse(for: body.method)
        }
    }

    private static func torrentResponse(
        _ torrents: [OperationFeedbackTorrent],
        status: TorrentStatus
    ) throws -> (HTTPURLResponse, Data) {
        let rows: [[String: Any]] = torrents.map { torrent in
            [
                "id": torrent.id,
                "hashString": torrent.hash,
                "name": torrent.name,
                "status": status.rawValue,
                "downloadDir": torrent.destination,
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "result": "success",
            "arguments": ["torrents": rows],
        ])
        guard
            let url = URL(string: "http://127.0.0.1:9091/transmission/rpc"),
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )
        else {
            throw TransmissionRPCError.invalidResponse
        }
        return (response, data)
    }
}

private struct OperationFeedbackRPCBody {
    let method: String
    let fields: Set<String>
    let stringIDs: [String]
    let location: String?
    let moveData: Bool?
    let name: String?

    var isTorrentListRequest: Bool {
        method == "torrent-get" && fields.contains("name")
    }
}

private extension URLRequest {
    func operationFeedbackRPCBody() throws -> OperationFeedbackRPCBody {
        let data: Data
        if let httpBody {
            data = httpBody
        } else if let httpBodyStream {
            httpBodyStream.open()
            defer { httpBodyStream.close() }
            var body = Data()
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while httpBodyStream.hasBytesAvailable {
                let count = httpBodyStream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                body.append(buffer, count: count)
            }
            data = body
        } else {
            throw TransmissionRPCError.invalidResponse
        }
        guard
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let method = object["method"] as? String
        else {
            throw TransmissionRPCError.invalidResponse
        }
        let arguments = object["arguments"] as? [String: Any]
        return OperationFeedbackRPCBody(
            method: method,
            fields: Set(arguments?["fields"] as? [String] ?? []),
            stringIDs: arguments?["ids"] as? [String] ?? [],
            location: arguments?["location"] as? String,
            moveData: arguments?["move"] as? Bool,
            name: arguments?["name"] as? String
        )
    }
}

private final class OperationFeedbackPasswordStore: ConnectionPasswordStoring {
    func password(for profileID: ConnectionProfile.ID) throws -> String? { nil }
    func setPassword(_ password: String, for profileID: ConnectionProfile.ID) throws {}
    func removePassword(for profileID: ConnectionProfile.ID) throws {}
}

private struct OperationFeedbackNotifier: DownloadCompletionNotifying {
    func notifyDownloadCompleted(torrentName: String) {}
}

@MainActor
private final class OperationFeedbackPrompter: TorrentOperationPrompting {
    private var locationResponses: [String?]
    private var renameResponses: [String?]

    init(
        locationResponses: [String?] = [],
        renameResponses: [String?] = []
    ) {
        self.locationResponses = locationResponses
        self.renameResponses = renameResponses
    }

    func requestLocation(
        defaultLocation: String,
        moveData: Bool,
        suggestions: [String]
    ) -> String? {
        guard !locationResponses.isEmpty else { return nil }
        return locationResponses.removeFirst()
    }

    func requestRename(currentName: String) -> String? {
        guard !renameResponses.isEmpty else { return nil }
        return renameResponses.removeFirst()
    }
}
