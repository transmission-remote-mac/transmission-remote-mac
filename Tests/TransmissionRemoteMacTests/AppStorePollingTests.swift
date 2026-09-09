// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation
import XCTest
@testable import TransmissionRemoteMac

@MainActor
final class AppStorePollingTests: XCTestCase {
    override func tearDown() {
        AppStoreMockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testVisibilityChangesReplaceScheduleAndBackgroundSuspendLeavesManualRefreshImmediate() async throws {
        let clock = TestPollingClock()
        let coordinator = PollingCoordinator(clock: clock)
        let recorder = PollingRPCRequestRecorder()
        AppStoreMockURLProtocol.requestHandler = { request in
            let action = try request.decodedActionBody()
            recorder.record(action.method)
            return appStoreRPCResponse(for: action.method)
        }
        let store = try makeStore(pollingCoordinator: coordinator)

        await store.start()
        let initialScheduleStarted = await waitForPollingCondition { clock.pendingSleepCount == 1 }
        XCTAssertTrue(initialScheduleStarted)
        XCTAssertEqual(recorder.count(of: "torrent-get"), 1)

        clock.advance(by: .seconds(5))
        let foregroundRefreshCompleted = await waitForPollingCondition {
            recorder.count(of: "torrent-get") == 2
        }
        XCTAssertTrue(foregroundRefreshCompleted)
        let foregroundDeadlineRearmed = await waitForPollingCondition {
            clock.pendingSleepCount == 1
        }
        XCTAssertTrue(foregroundDeadlineRearmed)

        let cancellationCountBeforeBackground = clock.cancellationCount
        store.updatePollingVisibility(.background)
        let backgroundScheduleStarted = await waitForPollingCondition {
            clock.cancellationCount > cancellationCountBeforeBackground
                && clock.pendingSleepCount == 1
        }
        XCTAssertTrue(backgroundScheduleStarted)

        clock.advance(by: .seconds(19))
        await Task.yield()
        XCTAssertEqual(recorder.count(of: "torrent-get"), 2)
        clock.advance(by: .seconds(1))
        let backgroundRefreshCompleted = await waitForPollingCondition {
            recorder.count(of: "torrent-get") == 3
        }
        XCTAssertTrue(backgroundRefreshCompleted)
        let backgroundDeadlineRearmed = await waitForPollingCondition {
            clock.pendingSleepCount == 1
        }
        XCTAssertTrue(backgroundDeadlineRearmed)

        let cancellationCountBeforeSuspend = clock.cancellationCount
        store.applyPollingPreferences(
            PollingPreferences(
                foregroundIntervalSeconds: 5,
                backgroundIntervalSeconds: 20,
                backgroundPolicy: .suspend
            )
        )
        let scheduleSuspended = await waitForPollingCondition {
            clock.cancellationCount > cancellationCountBeforeSuspend
                && clock.pendingSleepCount == 0
        }
        XCTAssertTrue(scheduleSuspended)
        clock.advance(by: .seconds(100))
        await Task.yield()
        XCTAssertEqual(recorder.count(of: "torrent-get"), 3)

        await store.refresh()
        let manualRefreshCompleted = await waitForPollingCondition {
            recorder.count(of: "torrent-get") == 4
        }
        XCTAssertTrue(manualRefreshCompleted)
        store.disconnect()
    }

    func testApplyingForegroundIntervalReplacesDeadlineWithoutDuplicatingOwner() async throws {
        let clock = TestPollingClock()
        let coordinator = PollingCoordinator(clock: clock)
        let recorder = PollingRPCRequestRecorder()
        AppStoreMockURLProtocol.requestHandler = { request in
            let action = try request.decodedActionBody()
            recorder.record(action.method)
            return appStoreRPCResponse(for: action.method)
        }
        let store = try makeStore(pollingCoordinator: coordinator)

        await store.start()
        let initialScheduleStarted = await waitForPollingCondition { clock.pendingSleepCount == 1 }
        XCTAssertTrue(initialScheduleStarted)

        let cancellationCountBeforeReplacement = clock.cancellationCount
        store.applyPollingPreferences(
            PollingPreferences(
                foregroundIntervalSeconds: 2,
                backgroundIntervalSeconds: 30,
                backgroundPolicy: .pollSlowly
            )
        )
        let replacementStarted = await waitForPollingCondition {
            clock.cancellationCount > cancellationCountBeforeReplacement
                && clock.pendingSleepCount == 1
        }
        XCTAssertTrue(replacementStarted)

        clock.advance(by: .seconds(2))
        let refreshCompleted = await waitForPollingCondition {
            recorder.count(of: "torrent-get") == 2
        }
        XCTAssertTrue(refreshCompleted)
        XCTAssertEqual(store.pollingPreferences.foregroundIntervalSeconds, 2)
        XCTAssertEqual(recorder.count(of: "torrent-get"), 2)
        store.disconnect()
    }

    func testNormalPollMergesRecentlyActiveRowsRemovesIDsAndPreservesSelection() async throws {
        let clock = TestPollingClock()
        let coordinator = PollingCoordinator(clock: clock)
        let recorder = PollingRPCActionRecorder()
        AppStoreMockURLProtocol.requestHandler = { request in
            let action = try request.decodedActionBody()
            recorder.record(action)
            guard action.method == "torrent-get" else {
                return appStoreRPCResponse(for: action.method)
            }
            if action.arguments["ids"] == .string("recently-active") {
                return rpcTestResponse(
                    body: #"{"result":"success","arguments":{"torrents":[{"id":2,"hashString":"2222222222222222222222222222222222222222","name":"Two updated","status":4},{"id":3,"hashString":"3333333333333333333333333333333333333333","name":"Three","status":0}],"removed":[1]}}"#
                )
            }
            if action.arguments["ids"] == .array([.int(3)]) {
                return rpcTestResponse(
                    body: #"{"result":"success","arguments":{"torrents":[{"id":3,"hashString":"3333333333333333333333333333333333333333","name":"Three","status":0}]}}"#
                )
            }
            return rpcTestResponse(
                body: #"{"result":"success","arguments":{"torrents":[{"id":2,"hashString":"2222222222222222222222222222222222222222","name":"Two","status":0},{"id":1,"hashString":"1111111111111111111111111111111111111111","name":"One","status":0}]}}"#
            )
        }
        let store = try makeStore(pollingCoordinator: coordinator)

        await store.start()
        store.isTorrentDetailVisible = false
        store.selectedTorrentIDs = [2]
        XCTAssertEqual(store.torrents.map(\.id), [1, 2])
        let initialScheduleStarted = await waitForPollingCondition { clock.pendingSleepCount == 1 }
        XCTAssertTrue(initialScheduleStarted)

        clock.advance(by: .seconds(5))
        let deltaCompleted = await waitForPollingCondition {
            recorder.torrentGetActions.count == 3 && store.torrents.map(\.id) == [2, 3]
        }

        XCTAssertTrue(deltaCompleted)
        XCTAssertEqual(recorder.torrentGetActions.first?.arguments["ids"], nil)
        XCTAssertEqual(recorder.torrentGetActions[1].arguments["ids"], .string("recently-active"))
        XCTAssertEqual(recorder.torrentGetActions.last?.arguments["ids"], .array([.int(3)]))
        XCTAssertEqual(store.torrents.map(\.id), [2, 3])
        XCTAssertEqual(store.torrents.first?.name, "Two updated")
        XCTAssertEqual(store.selectedTorrentIDs, [2])
        store.disconnect()
    }

    func testExpiredRepairDeadlineUsesFullSnapshotInsteadOfDelta() async throws {
        let clock = TestPollingClock()
        let coordinator = PollingCoordinator(clock: clock)
        let recorder = PollingRPCActionRecorder()
        AppStoreMockURLProtocol.requestHandler = { request in
            let action = try request.decodedActionBody()
            recorder.record(action)
            return appStoreRPCResponse(for: action.method)
        }
        let store = try makeStore(
            pollingCoordinator: coordinator,
            torrentListRepairInterval: .zero
        )

        await store.start()
        let initialScheduleStarted = await waitForPollingCondition { clock.pendingSleepCount == 1 }
        XCTAssertTrue(initialScheduleStarted)
        clock.advance(by: .seconds(5))
        let repairCompleted = await waitForPollingCondition {
            recorder.torrentGetActions.count == 2
        }

        XCTAssertTrue(repairCompleted)
        XCTAssertTrue(recorder.torrentGetActions.allSatisfy { $0.arguments["ids"] == nil })
        store.disconnect()
    }

    func testAllStoppedDeltaReplacesActiveForegroundScheduleWithIdleCadence() async throws {
        let clock = TestPollingClock()
        let coordinator = PollingCoordinator(clock: clock)
        let recorder = PollingRPCActionRecorder()
        AppStoreMockURLProtocol.requestHandler = { request in
            let action = try request.decodedActionBody()
            recorder.record(action)
            guard action.method == "torrent-get" else {
                return appStoreRPCResponse(for: action.method)
            }
            let isDelta = action.arguments["ids"] == .string("recently-active")
            let status = isDelta ? 0 : 4
            return rpcTestResponse(
                body: #"{"result":"success","arguments":{"torrents":[{"id":1,"hashString":"1111111111111111111111111111111111111111","name":"Cadence","status":\#(status)}]}}"#
            )
        }
        let store = try makeStore(
            pollingCoordinator: coordinator,
            adaptivePollingClock: clock,
            adaptiveIdleEnabled: true
        )

        await store.start()
        let activeScheduleStarted = await waitForPollingCondition { clock.pendingSleepCount == 1 }
        XCTAssertTrue(activeScheduleStarted)

        clock.advance(by: .seconds(5))
        let idleScheduleStarted = await waitForPollingCondition {
            recorder.torrentGetActions.count == 2
                && store.torrents.first?.status == .stopped
                && clock.pendingSleepCount == 1
                && clock.earliestPendingDeadline == .seconds(25)
        }
        XCTAssertTrue(idleScheduleStarted)

        clock.advance(by: .seconds(19))
        await Task.yield()
        XCTAssertEqual(recorder.torrentGetActions.count, 2)
        clock.advance(by: .seconds(1))
        let idleRefreshCompleted = await waitForPollingCondition {
            recorder.torrentGetActions.count == 3
        }
        XCTAssertTrue(idleRefreshCompleted)
        store.disconnect()
    }

    func testSuccessfulMutationRefreshesImmediatelyAndPromotesIdleSchedule() async throws {
        let clock = TestPollingClock()
        let coordinator = PollingCoordinator(clock: clock)
        let recorder = PollingRPCActionRecorder()
        AppStoreMockURLProtocol.requestHandler = { request in
            let action = try request.decodedActionBody()
            recorder.record(action)
            guard action.method == "torrent-get" else {
                return appStoreRPCResponse(for: action.method)
            }
            return rpcTestResponse(
                body: #"{"result":"success","arguments":{"torrents":[{"id":1,"hashString":"1111111111111111111111111111111111111111","name":"Stopped","status":0}]}}"#
            )
        }
        let store = try makeStore(
            pollingCoordinator: coordinator,
            adaptivePollingClock: clock,
            adaptiveIdleEnabled: true
        )

        await store.start()
        let idleScheduleStarted = await waitForPollingCondition { clock.pendingSleepCount == 1 }
        XCTAssertTrue(idleScheduleStarted)
        store.isTorrentDetailVisible = false
        store.selectedTorrentIDs = [1]
        let cancellationsBeforeMutation = clock.cancellationCount

        await store.startSelected()

        XCTAssertEqual(recorder.count(of: "torrent-start"), 1)
        XCTAssertEqual(recorder.torrentGetActions.count, 2)
        let activeScheduleStarted = await waitForPollingCondition {
            clock.cancellationCount > cancellationsBeforeMutation
                && clock.pendingSleepCount == 1
        }
        XCTAssertTrue(activeScheduleStarted)
        clock.advance(by: .seconds(4))
        await Task.yield()
        XCTAssertEqual(recorder.torrentGetActions.count, 2)
        clock.advance(by: .seconds(1))
        let activeRefreshCompleted = await waitForPollingCondition {
            recorder.torrentGetActions.count == 3
        }
        XCTAssertTrue(activeRefreshCompleted)
        store.disconnect()
    }

    func testIDLessSuccessfulAddRepairsRowsAndPromotesIdleSchedule() async throws {
        let clock = TestPollingClock()
        let coordinator = PollingCoordinator(clock: clock)
        let recorder = PollingRPCActionRecorder()
        AppStoreMockURLProtocol.requestHandler = { request in
            let action = try request.decodedActionBody()
            recorder.record(action)
            if action.method == "torrent-add" {
                return rpcTestResponse(
                    body: #"{"result":"success","arguments":{"torrent-added":{"name":"ID-less"}}}"#
                )
            }
            return appStoreRPCResponse(for: action.method)
        }
        let store = try makeStore(
            pollingCoordinator: coordinator,
            adaptivePollingClock: clock,
            adaptiveIdleEnabled: true
        )

        await store.start()
        let idleScheduleStarted = await waitForPollingCondition {
            clock.pendingSleepCount == 1
                && clock.earliestPendingDeadline == .seconds(20)
        }
        XCTAssertTrue(idleScheduleStarted)
        let cancellationsBeforeMutation = clock.cancellationCount

        let ownerID = UUID()
        store.registerAddTorrentPresentationOwner(ownerID)
        let source = "https://downloads.example/id-less.torrent"
        store.requestAddTorrent(source: source)
        let request = try XCTUnwrap(store.presentedAddTorrent(for: ownerID))
        let result = await store.addTorrent(
            requestID: request.id,
            presentationOwnerID: ownerID,
            source: source,
            startPaused: true,
            downloadDirectory: nil
        )

        XCTAssertEqual(result, .succeeded)
        let repairAndActiveScheduleCompleted = await waitForPollingCondition {
            recorder.count(of: "torrent-add") == 1
                && recorder.torrentGetActions.count == 2
                && clock.cancellationCount == cancellationsBeforeMutation + 1
                && clock.pendingSleepCount == 1
                && clock.earliestPendingDeadline == .seconds(5)
        }
        XCTAssertTrue(repairAndActiveScheduleCompleted)
        XCTAssertTrue(recorder.torrentGetActions.allSatisfy { $0.arguments["ids"] == nil })
        store.disconnect()
    }

    func testUnresolvedDuplicateTrackerMergeRepairsRowsAndPromotesIdleSchedule() async throws {
        let clock = TestPollingClock()
        let coordinator = PollingCoordinator(clock: clock)
        let recorder = PollingRPCActionRecorder()
        AppStoreMockURLProtocol.requestHandler = { request in
            let action = try request.decodedActionBody()
            recorder.record(action)
            return appStoreRPCResponse(for: action.method)
        }
        let store = try makeStore(
            pollingCoordinator: coordinator,
            adaptivePollingClock: clock,
            adaptiveIdleEnabled: true
        )

        await store.start()
        let idleScheduleStarted = await waitForPollingCondition {
            clock.pendingSleepCount == 1
                && clock.earliestPendingDeadline == .seconds(20)
        }
        XCTAssertTrue(idleScheduleStarted)
        let cancellationsBeforeMutation = clock.cancellationCount

        let ownerID = UUID()
        store.registerAddTorrentPresentationOwner(ownerID)
        store.requestAddTorrent(source: "magnet:?xt=urn:btih:missing")
        let request = try XCTUnwrap(store.presentedAddTorrent(for: ownerID))
        let torrentHash = "0123456789abcdef0123456789abcdef01234567"
        let result = await store.applyDuplicateTorrentTrackerPlan(
            requestID: request.id,
            presentationOwnerID: ownerID,
            plan: TorrentDuplicateTrackerPlan(
                target: .hash(torrentHash),
                torrentName: "Missing locally",
                missingTrackerURLs: ["https://tracker.example/announce"]
            ),
            downloadDirectory: nil
        )

        XCTAssertEqual(result, .succeeded)
        let repairAndActiveScheduleCompleted = await waitForPollingCondition {
            recorder.count(of: "torrent-set") == 1
                && recorder.torrentGetActions.count == 2
                && clock.cancellationCount == cancellationsBeforeMutation + 1
                && clock.pendingSleepCount == 1
                && clock.earliestPendingDeadline == .seconds(5)
        }
        XCTAssertTrue(repairAndActiveScheduleCompleted)
        let trackerSet = try XCTUnwrap(recorder.firstAction(for: "torrent-set"))
        XCTAssertEqual(trackerSet.arguments["ids"], .array([.string(torrentHash)]))
        XCTAssertTrue(recorder.torrentGetActions.allSatisfy { $0.arguments["ids"] == nil })
        store.disconnect()
    }

    private func makeStore(
        pollingCoordinator: PollingCoordinator,
        adaptivePollingClock: (any PollingClock)? = nil,
        adaptiveIdleEnabled: Bool = false,
        torrentListRepairInterval: Duration = .seconds(600)
    ) throws -> AppStore {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directoryURL.appendingPathComponent("profiles.json")
        let defaultsSuiteName = "AppStorePollingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuiteName)!
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directoryURL)
            defaults.removePersistentDomain(forName: defaultsSuiteName)
        }
        PollingPreferences(
            foregroundIntervalSeconds: 5,
            backgroundIntervalSeconds: 20,
            backgroundPolicy: .pollSlowly,
            adaptiveIdleEnabled: adaptiveIdleEnabled
        ).save(to: defaults)

        let profile = ConnectionProfile(name: "Polling", host: "127.0.0.1")
        let profileStore = ConnectionProfileStore(
            fileURL: fileURL,
            passwordStore: PollingTestPasswordStore()
        )
        try profileStore.save(
            ConnectionProfileCollection(profiles: [profile], selectedProfileID: profile.id)
        )
        let session = makeAppStoreMockSession()
        return AppStore(
            profileStore: profileStore,
            userDefaults: defaults,
            downloadCompletionNotifier: PollingTestNotifier(),
            pollingCoordinator: pollingCoordinator,
            adaptivePollingClock: adaptivePollingClock ?? ContinuousPollingClock(),
            selectionDebounceDuration: .zero,
            torrentListRepairInterval: torrentListRepairInterval,
            clientFactory: { profile in
                TransmissionRPCClient(profile: profile, urlSession: session)
            }
        )
    }
}

private final class PollingRPCRequestRecorder {
    private let lock = NSLock()
    private var methods: [String] = []

    func record(_ method: String) {
        lock.withLock { methods.append(method) }
    }

    func count(of method: String) -> Int {
        lock.withLock { methods.filter { $0 == method }.count }
    }
}

private final class PollingRPCActionRecorder {
    private let lock = NSLock()
    private var actions: [RPCRequest] = []

    var torrentGetActions: [RPCRequest] {
        lock.withLock { actions.filter { $0.method == "torrent-get" } }
    }

    func record(_ action: RPCRequest) {
        lock.withLock { actions.append(action) }
    }

    func count(of method: String) -> Int {
        lock.withLock { actions.filter { $0.method == method }.count }
    }

    func firstAction(for method: String) -> RPCRequest? {
        lock.withLock { actions.first { $0.method == method } }
    }
}

private final class PollingTestPasswordStore: ConnectionPasswordStoring {
    func password(for profileID: ConnectionProfile.ID) throws -> String? { nil }
    func setPassword(_ password: String, for profileID: ConnectionProfile.ID) throws {}
    func removePassword(for profileID: ConnectionProfile.ID) throws {}
}

private final class PollingTestNotifier: DownloadCompletionNotifying {
    func notifyDownloadCompleted(torrentName: String) {}
}
