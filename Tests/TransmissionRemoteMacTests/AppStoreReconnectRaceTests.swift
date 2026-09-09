// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation
import XCTest
@testable import TransmissionRemoteMac

@MainActor
final class AppStoreReconnectRaceTests: XCTestCase {
    override func tearDown() {
        AppStoreMockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testProfileSwitchWhileWaitingCancelsOldRetryAndConnectsOnlyNewProfile() async throws {
        let oldProfile = raceProfile(name: "Old", host: "old.example", autoReconnect: true)
        let newProfile = raceProfile(name: "New", host: "new.example", autoReconnect: true)
        let sleeper = ControlledReconnectSleeper()
        let requests = RaceRequestRecorder()
        AppStoreMockURLProtocol.requestHandler = { request in
            let action = try request.decodedActionBody()
            requests.record(request, method: action.method)
            if request.url?.host == oldProfile.host, action.method == "session-get" {
                throw URLError(.networkConnectionLost)
            }
            return appStoreRPCResponse(for: action.method)
        }
        let store = try makeRaceStore(
            profiles: [oldProfile, newProfile],
            selectedProfileID: oldProfile.id,
            sleeper: sleeper
        )

        await store.start()
        await sleeper.waitForSleepCount(1)

        await store.switchProfile(to: newProfile.id)
        await sleeper.waitUntilIdle()

        XCTAssertEqual(store.selectedProfileID, newProfile.id)
        XCTAssertEqual(store.connectionState, .connected(rpcVersion: 18))
        XCTAssertEqual(requests.count(host: oldProfile.host, method: "session-get"), 1)
        XCTAssertEqual(requests.count(host: newProfile.host, method: "session-get"), 1)

        sleeper.release(10)
        await Task.yield()

        XCTAssertEqual(requests.count(host: oldProfile.host, method: "session-get"), 1)
        XCTAssertEqual(requests.count(host: newProfile.host, method: "session-get"), 1)
        store.disconnect()
    }

    func testRepeatedSessionIDRejectionReconnectsWithFreshClientAndRecovers() async throws {
        let profile = raceProfile(name: "Session Retry", host: "session.example", autoReconnect: true)
        let sleeper = ControlledReconnectSleeper()
        let requests = RaceRequestRecorder()
        AppStoreMockURLProtocol.requestHandler = { request in
            let action = try request.decodedActionBody()
            let requestNumber = requests.record(request, method: action.method)
            if action.method == "session-get", requestNumber <= 2 {
                return raceResponse(
                    for: request,
                    statusCode: 409,
                    headers: ["X-Transmission-Session-Id": "rejected-\(requestNumber)"],
                    body: ""
                )
            }
            return appStoreRPCResponse(for: action.method)
        }
        let store = try makeRaceStore(
            profiles: [profile],
            selectedProfileID: profile.id,
            sleeper: sleeper,
            createsSeparateClientSessions: true
        )

        await store.start()
        await sleeper.waitForSleepCount(1)

        guard case .reconnecting = store.connectionState else {
            return XCTFail("Expected repeated 409 rejection to schedule a reconnect")
        }

        sleeper.release(5)
        await requests.waitForCount(host: profile.host, method: "session-get", atLeast: 3)
        await requests.waitForCount(host: profile.host, method: "torrent-get", atLeast: 1)

        let sessionRequests = requests.entries(host: profile.host, method: "session-get")
        XCTAssertEqual(sessionRequests.count, 3)
        XCTAssertNil(sessionRequests[0].sessionID)
        XCTAssertEqual(sessionRequests[1].sessionID, "rejected-1")
        XCTAssertNil(sessionRequests[2].sessionID, "The reconnect must use a fresh RPC client")
        XCTAssertEqual(store.connectionState, .connected(rpcVersion: 18))
        store.disconnect()
    }

    func testConcurrentBackgroundRefreshRequestsScheduleOneRetryAndOneReconnect() async throws {
        let profile = raceProfile(name: "Coalesced", host: "coalesced.example", autoReconnect: true)
        let sleeper = ControlledReconnectSleeper()
        let requests = RaceRequestRecorder()
        let failures = OneShotTorrentRefreshFailure()
        AppStoreMockURLProtocol.requestHandler = { request in
            let action = try request.decodedActionBody()
            requests.record(request, method: action.method)
            if action.method == "torrent-get", failures.consumeFailure() {
                throw URLError(.networkConnectionLost)
            }
            return appStoreRPCResponse(for: action.method)
        }
        let store = try makeRaceStore(
            profiles: [profile],
            selectedProfileID: profile.id,
            sleeper: sleeper
        )
        await store.start()
        failures.arm()

        let refreshes = (0..<6).map { _ in
            Task { @MainActor in
                await store.refresh()
            }
        }
        for refresh in refreshes {
            await refresh.value
        }
        await sleeper.waitForSleepCount(1)

        guard case .reconnecting = store.connectionState else {
            return XCTFail("Expected the background transport failure to schedule a reconnect")
        }
        XCTAssertEqual(sleeper.sleepCount, 1)
        XCTAssertEqual(requests.count(host: profile.host, method: "session-get"), 1)

        await store.refresh()
        await store.refresh()
        XCTAssertEqual(sleeper.sleepCount, 1)
        XCTAssertEqual(requests.count(host: profile.host, method: "session-get"), 1)

        sleeper.release(5)
        await requests.waitForCount(host: profile.host, method: "session-get", atLeast: 2)
        await requests.waitForCount(host: profile.host, method: "torrent-get", atLeast: 3)

        XCTAssertEqual(requests.count(host: profile.host, method: "session-get"), 2)
        XCTAssertEqual(store.connectionState, .connected(rpcVersion: 18))
        store.disconnect()
    }

    func testForegroundTorrentActionTransportFailureLeavesConnectionConnected() async throws {
        let profile = raceProfile(name: "Foreground", host: "foreground.example", autoReconnect: true)
        let sleeper = ControlledReconnectSleeper()
        let requests = RaceRequestRecorder()
        AppStoreMockURLProtocol.requestHandler = { request in
            let action = try request.decodedActionBody()
            requests.record(request, method: action.method)
            if action.method == "torrent-start" {
                throw URLError(.networkConnectionLost)
            }
            if action.method == "torrent-get" {
                return raceTorrentListResponse(for: request)
            }
            return appStoreRPCResponse(for: action.method)
        }
        let store = try makeRaceStore(
            profiles: [profile],
            selectedProfileID: profile.id,
            sleeper: sleeper
        )
        await store.start()
        store.selectedTorrentIDs = [1]

        await store.startSelected()

        XCTAssertEqual(requests.count(host: profile.host, method: "torrent-start"), 1)
        XCTAssertEqual(store.connectionState, .connected(rpcVersion: 18))
        XCTAssertEqual(store.torrents.map(\.id), [1])
        XCTAssertNotNil(store.errorMessage)
        XCTAssertEqual(sleeper.sleepCount, 0)
        XCTAssertEqual(requests.count(host: profile.host, method: "session-get"), 1)
        store.disconnect()
    }

    func testActiveProfileEditWhileWaitingInvalidatesOldRetryAndConnectsEditedEndpoint() async throws {
        let profile = raceProfile(name: "Editable", host: "before.example", autoReconnect: true)
        var editedProfile = profile
        editedProfile.host = "after.example"
        let sleeper = ControlledReconnectSleeper()
        let requests = RaceRequestRecorder()
        AppStoreMockURLProtocol.requestHandler = { request in
            let action = try request.decodedActionBody()
            requests.record(request, method: action.method)
            if request.url?.host == profile.host, action.method == "session-get" {
                throw URLError(.cannotConnectToHost)
            }
            return appStoreRPCResponse(for: action.method)
        }
        let store = try makeRaceStore(
            profiles: [profile],
            selectedProfileID: profile.id,
            sleeper: sleeper
        )

        await store.start()
        await sleeper.waitForSleepCount(1)

        store.applyConnectionProfiles([editedProfile], selectedProfileID: editedProfile.id)
        await requests.waitForCount(host: editedProfile.host, method: "session-get", atLeast: 1)
        await requests.waitForCount(host: editedProfile.host, method: "torrent-get", atLeast: 1)
        await sleeper.waitUntilIdle()

        XCTAssertEqual(store.selectedProfile.host, editedProfile.host)
        XCTAssertEqual(store.connectionState, .connected(rpcVersion: 18))
        XCTAssertEqual(requests.count(host: profile.host, method: "session-get"), 1)
        XCTAssertEqual(requests.count(host: editedProfile.host, method: "session-get"), 1)

        sleeper.release(10)
        await Task.yield()

        XCTAssertEqual(requests.count(host: profile.host, method: "session-get"), 1)
        XCTAssertEqual(requests.count(host: editedProfile.host, method: "session-get"), 1)
        store.disconnect()
    }

    private func makeRaceStore(
        profiles: [ConnectionProfile],
        selectedProfileID: ConnectionProfile.ID,
        sleeper: any ReconnectSleeping,
        createsSeparateClientSessions: Bool = false
    ) throws -> AppStore {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directoryURL.appendingPathComponent("profiles.json")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        let profileStore = ConnectionProfileStore(
            fileURL: fileURL,
            passwordStore: ReconnectRacePasswordStore()
        )
        try profileStore.save(
            ConnectionProfileCollection(profiles: profiles, selectedProfileID: selectedProfileID)
        )
        let defaultsSuiteName = "AppStoreReconnectRaceTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: defaultsSuiteName)!
        addTeardownBlock {
            userDefaults.removePersistentDomain(forName: defaultsSuiteName)
        }
        let sharedSession = makeAppStoreMockSession()
        return AppStore(
            profileStore: profileStore,
            userDefaults: userDefaults,
            downloadCompletionNotifier: ReconnectRaceNotifier(),
            reconnectSleeper: sleeper,
            selectionDebounceDuration: .zero,
            clientFactory: { profile in
                let session = createsSeparateClientSessions ? makeAppStoreMockSession() : sharedSession
                return TransmissionRPCClient(profile: profile, urlSession: session)
            }
        )
    }
}

private func raceProfile(
    name: String,
    host: String,
    autoReconnect: Bool
) -> ConnectionProfile {
    ConnectionProfile(
        name: name,
        host: host,
        autoReconnect: autoReconnect
    )
}

private func raceResponse(
    for request: URLRequest,
    statusCode: Int,
    headers: [String: String]? = nil,
    body: String
) -> (HTTPURLResponse, Data) {
    let response = HTTPURLResponse(
        url: request.url!,
        statusCode: statusCode,
        httpVersion: nil,
        headerFields: headers
    )!
    return (response, Data(body.utf8))
}

private func raceTorrentListResponse(for request: URLRequest) -> (HTTPURLResponse, Data) {
    raceResponse(
        for: request,
        statusCode: 200,
        body: """
        {"result":"success","arguments":{"torrents":[{
          "id":1,
          "name":"Foreground Torrent",
          "status":0,
          "percentDone":0.5,
          "totalSize":100,
          "sizeWhenDone":100,
          "leftUntilDone":50,
          "hashString":"foreground-hash",
          "downloadDir":"/downloads",
          "trackerStats":[]
        }]}}
        """
    )
}

private final class ControlledReconnectSleeper: ReconnectSleeping, @unchecked Sendable {
    private struct SleepObserver {
        var expectedCount: Int
        var continuation: CheckedContinuation<Void, Never>
    }

    private let lock = NSLock()
    private var permits = 0
    private var sleepCounter = 0
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var cancelledWaiterIDs: Set<UUID> = []
    private var sleepObservers: [SleepObserver] = []
    private var idleObservers: [CheckedContinuation<Void, Never>] = []

    var sleepCount: Int {
        lock.withLock { sleepCounter }
    }

    func sleep(for duration: Duration) async throws {
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                var result: Result<Void, Error>?
                var observers: [CheckedContinuation<Void, Never>] = []
                lock.withLock {
                    sleepCounter += 1
                    observers = fulfilledSleepObservers()
                    if cancelledWaiterIDs.remove(waiterID) != nil || Task.isCancelled {
                        result = .failure(CancellationError())
                    } else if permits > 0 {
                        permits -= 1
                        result = .success(())
                    } else {
                        waiters[waiterID] = continuation
                    }
                }
                observers.forEach { $0.resume() }
                if let result {
                    continuation.resume(with: result)
                }
            }
        } onCancel: {
            self.cancel(waiterID)
        }
    }

    func release(_ count: Int = 1) {
        guard count > 0 else { return }
        var continuations: [CheckedContinuation<Void, Error>] = []
        var idle: [CheckedContinuation<Void, Never>] = []
        lock.withLock {
            var remaining = count
            while remaining > 0, let entry = waiters.first {
                waiters.removeValue(forKey: entry.key)
                continuations.append(entry.value)
                remaining -= 1
            }
            permits += remaining
            if waiters.isEmpty {
                idle = idleObservers
                idleObservers.removeAll()
            }
        }
        continuations.forEach { $0.resume() }
        idle.forEach { $0.resume() }
    }

    func waitForSleepCount(_ expectedCount: Int) async {
        guard sleepCount < expectedCount else { return }
        await withCheckedContinuation { continuation in
            var resumeImmediately = false
            lock.withLock {
                if sleepCounter >= expectedCount {
                    resumeImmediately = true
                } else {
                    sleepObservers.append(
                        SleepObserver(expectedCount: expectedCount, continuation: continuation)
                    )
                }
            }
            if resumeImmediately {
                continuation.resume()
            }
        }
    }

    func waitUntilIdle() async {
        await withCheckedContinuation { continuation in
            var resumeImmediately = false
            lock.withLock {
                if waiters.isEmpty {
                    resumeImmediately = true
                } else {
                    idleObservers.append(continuation)
                }
            }
            if resumeImmediately {
                continuation.resume()
            }
        }
    }

    private func cancel(_ waiterID: UUID) {
        var continuation: CheckedContinuation<Void, Error>?
        var idle: [CheckedContinuation<Void, Never>] = []
        lock.withLock {
            if let waiter = waiters.removeValue(forKey: waiterID) {
                continuation = waiter
            } else {
                cancelledWaiterIDs.insert(waiterID)
            }
            if waiters.isEmpty {
                idle = idleObservers
                idleObservers.removeAll()
            }
        }
        continuation?.resume(throwing: CancellationError())
        idle.forEach { $0.resume() }
    }

    private func fulfilledSleepObservers() -> [CheckedContinuation<Void, Never>] {
        var fulfilled: [CheckedContinuation<Void, Never>] = []
        sleepObservers.removeAll { observer in
            guard sleepCounter >= observer.expectedCount else { return false }
            fulfilled.append(observer.continuation)
            return true
        }
        return fulfilled
    }
}

private final class RaceRequestRecorder: @unchecked Sendable {
    struct Entry: Equatable {
        var host: String?
        var method: String
        var sessionID: String?
    }

    private struct Observer {
        var host: String
        var method: String
        var expectedCount: Int
        var continuation: CheckedContinuation<Void, Never>
    }

    private let lock = NSLock()
    private var recordedEntries: [Entry] = []
    private var observers: [Observer] = []

    @discardableResult
    func record(_ request: URLRequest, method: String) -> Int {
        var methodCount = 0
        var fulfilled: [CheckedContinuation<Void, Never>] = []
        lock.withLock {
            recordedEntries.append(
                Entry(
                    host: request.url?.host,
                    method: method,
                    sessionID: request.value(forHTTPHeaderField: "X-Transmission-Session-Id")
                )
            )
            methodCount = recordedEntries.filter { $0.method == method }.count
            observers.removeAll { observer in
                let count = recordedEntries.filter {
                    $0.host == observer.host && $0.method == observer.method
                }.count
                guard count >= observer.expectedCount else { return false }
                fulfilled.append(observer.continuation)
                return true
            }
        }
        fulfilled.forEach { $0.resume() }
        return methodCount
    }

    func count(host: String, method: String) -> Int {
        entries(host: host, method: method).count
    }

    func entries(host: String, method: String) -> [Entry] {
        lock.withLock {
            recordedEntries.filter { $0.host == host && $0.method == method }
        }
    }

    func waitForCount(host: String, method: String, atLeast expectedCount: Int) async {
        guard count(host: host, method: method) < expectedCount else { return }
        await withCheckedContinuation { continuation in
            var resumeImmediately = false
            lock.withLock {
                let currentCount = recordedEntries.filter {
                    $0.host == host && $0.method == method
                }.count
                if currentCount >= expectedCount {
                    resumeImmediately = true
                } else {
                    observers.append(
                        Observer(
                            host: host,
                            method: method,
                            expectedCount: expectedCount,
                            continuation: continuation
                        )
                    )
                }
            }
            if resumeImmediately {
                continuation.resume()
            }
        }
    }
}

private final class OneShotTorrentRefreshFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var isArmed = false

    func arm() {
        lock.withLock {
            isArmed = true
        }
    }

    func consumeFailure() -> Bool {
        lock.withLock {
            guard isArmed else { return false }
            isArmed = false
            return true
        }
    }
}

private final class ReconnectRacePasswordStore: ConnectionPasswordStoring {
    private let lock = NSLock()
    private var passwords: [ConnectionProfile.ID: String] = [:]

    func password(for profileID: ConnectionProfile.ID) throws -> String? {
        lock.withLock { passwords[profileID] }
    }

    func setPassword(_ password: String, for profileID: ConnectionProfile.ID) throws {
        lock.withLock {
            passwords[profileID] = password
        }
    }

    func removePassword(for profileID: ConnectionProfile.ID) throws {
        _ = lock.withLock {
            passwords.removeValue(forKey: profileID)
        }
    }
}

private struct ReconnectRaceNotifier: DownloadCompletionNotifying {
    func notifyDownloadCompleted(torrentName: String) {}
}
