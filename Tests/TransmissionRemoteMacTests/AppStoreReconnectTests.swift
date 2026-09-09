// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation
import XCTest
@testable import TransmissionRemoteMac

@MainActor
final class AppStoreReconnectTests: XCTestCase {
    override func tearDown() {
        AppStoreMockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testBackoffMatchesLegacySequenceAndResets() {
        var backoff = ReconnectBackoff()

        XCTAssertEqual(
            (0..<8).map { _ in backoff.nextDelay() },
            [5, 10, 20, 30, 40, 50, 60, 60]
        )

        backoff.reset()
        XCTAssertEqual(backoff.nextDelay(), 5)
    }

    func testStartupTransportFailureReconnectsWithoutWaitingRealTime() async throws {
        let profile = reconnectProfile(autoReconnect: true)
        let sleeper = ImmediateReconnectSleeper()
        let requests = ReconnectRequestState()
        AppStoreMockURLProtocol.requestHandler = { request in
            let action = try request.decodedActionBody()
            let requestNumber = requests.record(method: action.method)
            if action.method == "session-get", requestNumber == 1 {
                throw URLError(.cannotConnectToHost)
            }
            return appStoreRPCResponse(for: action.method)
        }
        let store = try makeReconnectStore(profile: profile, sleeper: sleeper)

        await store.start()
        let connected = await waitForReconnectCondition {
            store.connectionState == .connected(rpcVersion: 18)
        }

        XCTAssertTrue(connected)
        XCTAssertEqual(requests.count(of: "session-get"), 2)
        XCTAssertEqual(sleeper.recordedDurations.count, 5)
        store.disconnect()
    }

    func testManualCancelStopsScheduledRetry() async throws {
        let profile = reconnectProfile(autoReconnect: true)
        let sleeper = BlockingReconnectSleeper()
        let requests = ReconnectRequestState()
        AppStoreMockURLProtocol.requestHandler = { request in
            let action = try request.decodedActionBody()
            requests.record(method: action.method)
            throw URLError(.networkConnectionLost)
        }
        let store = try makeReconnectStore(profile: profile, sleeper: sleeper)

        await store.start()
        guard case .reconnecting = store.connectionState else {
            return XCTFail("Expected a scheduled reconnect")
        }
        let retrySleepStarted = await waitForReconnectCondition {
            sleeper.sleepCount == 1
        }
        XCTAssertTrue(retrySleepStarted)

        store.cancelRetry()
        await Task.yield()

        XCTAssertEqual(store.connectionState, .disconnected)
        XCTAssertEqual(requests.count(of: "session-get"), 1)
        XCTAssertEqual(sleeper.sleepCount, 1)
    }

    func testHTTPFailureDoesNotScheduleReconnect() async throws {
        let profile = reconnectProfile(autoReconnect: true)
        let sleeper = ImmediateReconnectSleeper()
        AppStoreMockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 503,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }
        let store = try makeReconnectStore(profile: profile, sleeper: sleeper)

        await store.start()

        guard case .failed = store.connectionState else {
            return XCTFail("Expected terminal HTTP failure")
        }
        XCTAssertTrue(sleeper.recordedDurations.isEmpty)
    }

    func testBackgroundTransportFailureClearsStaleDataAndReconnects() async throws {
        let profile = reconnectProfile(autoReconnect: true)
        let sleeper = ImmediateReconnectSleeper()
        let requests = ReconnectRequestState()
        AppStoreMockURLProtocol.requestHandler = { request in
            let action = try request.decodedActionBody()
            requests.record(method: action.method)
            if action.method == "torrent-get", requests.shouldFailNextTorrentRefresh() {
                throw URLError(.networkConnectionLost)
            }
            return appStoreRPCResponse(for: action.method)
        }
        let store = try makeReconnectStore(profile: profile, sleeper: sleeper)

        await store.start()
        store.torrents = [reconnectTorrent()]
        requests.armTorrentRefreshFailure()
        await store.refresh()
        let connected = await waitForReconnectCondition {
            store.connectionState == .connected(rpcVersion: 18)
                && requests.count(of: "session-get") == 2
        }

        XCTAssertTrue(connected)
        XCTAssertTrue(store.torrents.isEmpty)
        store.disconnect()
    }

    func testPollingTransportFailureSchedulesRetryAfterPollingCancelsItself() async throws {
        let profile = reconnectProfile(autoReconnect: true)
        let sleeper = BlockingReconnectSleeper()
        let requests = ReconnectRequestState()
        AppStoreMockURLProtocol.requestHandler = { request in
            let action = try request.decodedActionBody()
            requests.record(method: action.method)
            if action.method == "torrent-get", requests.shouldFailNextTorrentRefresh() {
                throw URLError(.cannotConnectToHost)
            }
            return appStoreRPCResponse(for: action.method)
        }
        let store = try makeReconnectStore(profile: profile, sleeper: sleeper)

        await store.start()
        store.torrents = [reconnectTorrent()]
        requests.armTorrentRefreshFailure()
        let reconnecting = await waitForReconnectCondition(timeout: .seconds(7)) {
            if case .reconnecting = store.connectionState {
                return true
            }
            return false
        }
        let retrySleepStarted = await waitForReconnectCondition {
            sleeper.sleepCount == 1
        }

        XCTAssertTrue(reconnecting)
        XCTAssertTrue(retrySleepStarted)
        XCTAssertTrue(store.torrents.isEmpty)
        XCTAssertEqual(requests.count(of: "session-get"), 1)
        guard case .reconnecting = store.connectionState else {
            return XCTFail("Expected polling failure to remain in reconnect countdown")
        }
        store.cancelRetry()
    }

    func testInvalidTorrentListRPCFailureStaysConnectedWithoutRetry() async throws {
        let profile = reconnectProfile(autoReconnect: true)
        let sleeper = ImmediateReconnectSleeper()
        let requests = ReconnectRequestState()
        AppStoreMockURLProtocol.requestHandler = { request in
            let action = try request.decodedActionBody()
            requests.record(method: action.method)
            if action.method == "torrent-get", requests.shouldFailNextTorrentListRefresh() {
                return rpcTestResponse(
                    body: #"{"result":"invalid argument","arguments":{}}"#
                )
            }
            return appStoreRPCResponse(for: action.method)
        }
        let store = try makeReconnectStore(profile: profile, sleeper: sleeper)

        await store.start()
        requests.armTorrentListRPCFailure()
        await store.refresh()

        XCTAssertEqual(store.connectionState, .connected(rpcVersion: 18))
        XCTAssertNotNil(store.errorMessage)
        XCTAssertTrue(sleeper.recordedDurations.isEmpty)
        store.disconnect()
    }

    func testInvalidSelectedDetailRPCFailurePreservesConnectionAndPaneFailure() async throws {
        let profile = reconnectProfile(autoReconnect: true)
        let sleeper = ImmediateReconnectSleeper()
        let requests = ReconnectRequestState()
        AppStoreMockURLProtocol.requestHandler = { request in
            let action = try request.decodedActionBody()
            requests.record(method: action.method)
            let fields = action.arguments["fields"]?.arrayValue?.compactMap(\.stringValue) ?? []
            if
                action.method == "torrent-get",
                fields.contains("activityDate"),
                requests.shouldFailNextSelectedDetailRefresh()
            {
                return rpcTestResponse(
                    body: #"{"result":"invalid argument","arguments":{}}"#
                )
            }
            return appStoreRPCResponse(for: action.method)
        }
        let store = try makeReconnectStore(profile: profile, sleeper: sleeper)

        await store.start()
        store.torrents = [reconnectTorrent()]
        requests.armSelectedDetailRPCFailure()
        store.selectedTorrentIDs = [1]
        let detailFailed = await waitForReconnectCondition {
            if case .failed = store.selectedTorrentDetailState {
                return true
            }
            return false
        }

        XCTAssertTrue(detailFailed)
        XCTAssertEqual(store.connectionState, .connected(rpcVersion: 18))
        XCTAssertNotNil(store.errorMessage)
        XCTAssertTrue(sleeper.recordedDurations.isEmpty)
        store.disconnect()
    }

    func testAskEveryTimePasswordIsReusedOnlyForAutomaticRetry() async throws {
        let profile = reconnectProfile(
            username: "rpc-user",
            askPasswordAtConnect: true,
            autoReconnect: true
        )
        let passwordStore = ReconnectTestPasswordStore()
        let sleeper = ImmediateReconnectSleeper()
        let requests = ReconnectRequestState()
        AppStoreMockURLProtocol.requestHandler = { request in
            let action = try request.decodedActionBody()
            let requestNumber = requests.record(
                method: action.method,
                authorization: request.value(forHTTPHeaderField: "Authorization")
            )
            if action.method == "session-get", requestNumber == 2 {
                throw URLError(.cannotConnectToHost)
            }
            return appStoreRPCResponse(for: action.method)
        }
        let store = try makeReconnectStore(
            profile: profile,
            passwordStore: passwordStore,
            sleeper: sleeper
        )
        await store.start()
        let firstPrompt = try XCTUnwrap(store.passwordPrompt)
        await store.connectWithPromptPassword("prior-session", for: firstPrompt)
        XCTAssertEqual(store.connectionState, .connected(rpcVersion: 18))
        store.disconnect()

        await store.connect()
        let currentPrompt = try XCTUnwrap(store.passwordPrompt)
        await store.connectWithPromptPassword("current-session", for: currentPrompt)
        let reconnected = await waitForReconnectCondition {
            store.connectionState == .connected(rpcVersion: 18)
                && requests.count(of: "session-get") == 3
        }

        XCTAssertTrue(reconnected)
        XCTAssertNil(store.passwordPrompt)
        XCTAssertTrue(passwordStore.savedPasswords.isEmpty)
        XCTAssertEqual(
            requests.authorizations(for: "session-get"),
            [
                basicAuthorization(username: "rpc-user", password: "prior-session"),
                basicAuthorization(username: "rpc-user", password: "current-session"),
                basicAuthorization(username: "rpc-user", password: "current-session")
            ]
        )
        store.disconnect()
    }

    func testCancelledStartupDoesNotScheduleReconnectAndCanStartAgain() async throws {
        let profile = reconnectProfile(autoReconnect: true)
        let sleeper = ImmediateReconnectSleeper()
        let requests = ReconnectRequestState()
        let firstRequestStarted = expectation(description: "cancelled startup request started")
        let firstRequestGate = DispatchSemaphore(value: 0)
        AppStoreMockURLProtocol.requestHandler = { request in
            let action = try request.decodedActionBody()
            let requestNumber = requests.record(method: action.method)
            if action.method == "session-get", requestNumber == 1 {
                firstRequestStarted.fulfill()
                _ = firstRequestGate.wait(timeout: .now() + 2)
                throw URLError(.cancelled)
            }
            return appStoreRPCResponse(for: action.method)
        }
        let store = try makeReconnectStore(profile: profile, sleeper: sleeper)

        let firstStart = Task {
            await store.start()
        }
        await fulfillment(of: [firstRequestStarted], timeout: 1)
        firstStart.cancel()
        firstRequestGate.signal()
        await firstStart.value

        XCTAssertEqual(store.connectionState, .disconnected)
        XCTAssertTrue(sleeper.recordedDurations.isEmpty)
        XCTAssertEqual(requests.count(of: "session-get"), 1)

        await store.start()

        XCTAssertEqual(store.connectionState, .connected(rpcVersion: 18))
        XCTAssertEqual(requests.count(of: "session-get"), 2)
        store.disconnect()
    }

    private func makeReconnectStore(
        profile: ConnectionProfile,
        passwordStore: ReconnectTestPasswordStore = ReconnectTestPasswordStore(),
        sleeper: any ReconnectSleeping
    ) throws -> AppStore {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directoryURL.appendingPathComponent("profiles.json")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        let profileStore = ConnectionProfileStore(fileURL: fileURL, passwordStore: passwordStore)
        try profileStore.save(
            ConnectionProfileCollection(profiles: [profile], selectedProfileID: profile.id)
        )
        let session = makeAppStoreMockSession()
        let defaultsSuiteName = "AppStoreReconnectTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: defaultsSuiteName)!
        addTeardownBlock {
            userDefaults.removePersistentDomain(forName: defaultsSuiteName)
        }
        return AppStore(
            profileStore: profileStore,
            userDefaults: userDefaults,
            downloadCompletionNotifier: ReconnectTestNotifier(),
            reconnectSleeper: sleeper,
            selectionDebounceDuration: .zero,
            clientFactory: { profile in
                TransmissionRPCClient(profile: profile, urlSession: session)
            }
        )
    }

    private func waitForReconnectCondition(
        timeout: Duration = .seconds(1),
        condition: @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}

private func reconnectProfile(
    username: String = "",
    askPasswordAtConnect: Bool = false,
    autoReconnect: Bool
) -> ConnectionProfile {
    ConnectionProfile(
        name: "Reconnect",
        host: "reconnect.example",
        username: username,
        askPasswordAtConnect: askPasswordAtConnect,
        autoReconnect: autoReconnect
    )
}

private func reconnectTorrent() -> TorrentSummary {
    TorrentSummary(json: [
        "id": .int(1),
        "name": .string("Reconnect Torrent"),
        "status": .int(TorrentStatus.downloading.rawValue),
        "percentDone": .double(0.5),
        "totalSize": .int(100),
        "sizeWhenDone": .int(100),
        "leftUntilDone": .int(50),
        "hashString": .string(String(repeating: "A", count: 40)),
        "downloadDir": .string("/downloads"),
        "trackerStats": .array([])
    ])
}

private func basicAuthorization(username: String, password: String) -> String {
    let token = Data("\(username):\(password)".utf8).base64EncodedString()
    return "Basic \(token)"
}

private final class ImmediateReconnectSleeper: ReconnectSleeping, @unchecked Sendable {
    private let lock = NSLock()
    private var durations: [Duration] = []

    var recordedDurations: [Duration] {
        lock.withLock { durations }
    }

    func sleep(for duration: Duration) async throws {
        lock.withLock {
            durations.append(duration)
        }
        try Task.checkCancellation()
    }
}

private final class BlockingReconnectSleeper: ReconnectSleeping, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var sleepCount: Int {
        lock.withLock { count }
    }

    func sleep(for duration: Duration) async throws {
        lock.withLock {
            count += 1
        }
        try await Task.sleep(for: .seconds(3_600))
    }
}

private final class ReconnectRequestState: @unchecked Sendable {
    private let lock = NSLock()
    private var methods: [String] = []
    private var authorizationsByMethod: [String: [String?]] = [:]
    private var failNextTorrentRefresh = false
    private var failNextTorrentListRefresh = false
    private var failNextSelectedDetailRefresh = false

    @discardableResult
    func record(method: String, authorization: String? = nil) -> Int {
        lock.withLock {
            methods.append(method)
            authorizationsByMethod[method, default: []].append(authorization)
            return methods.filter { $0 == method }.count
        }
    }

    func count(of method: String) -> Int {
        lock.withLock { methods.filter { $0 == method }.count }
    }

    func authorizations(for method: String) -> [String?] {
        lock.withLock { authorizationsByMethod[method] ?? [] }
    }

    func armTorrentRefreshFailure() {
        lock.withLock {
            failNextTorrentRefresh = true
        }
    }

    func shouldFailNextTorrentRefresh() -> Bool {
        lock.withLock {
            guard failNextTorrentRefresh else { return false }
            failNextTorrentRefresh = false
            return true
        }
    }

    func armTorrentListRPCFailure() {
        lock.withLock {
            failNextTorrentListRefresh = true
        }
    }

    func shouldFailNextTorrentListRefresh() -> Bool {
        lock.withLock {
            guard failNextTorrentListRefresh else { return false }
            failNextTorrentListRefresh = false
            return true
        }
    }

    func armSelectedDetailRPCFailure() {
        lock.withLock {
            failNextSelectedDetailRefresh = true
        }
    }

    func shouldFailNextSelectedDetailRefresh() -> Bool {
        lock.withLock {
            guard failNextSelectedDetailRefresh else { return false }
            failNextSelectedDetailRefresh = false
            return true
        }
    }
}

private final class ReconnectTestPasswordStore: ConnectionPasswordStoring {
    private(set) var savedPasswords: [ConnectionProfile.ID: String] = [:]

    func password(for profileID: ConnectionProfile.ID) throws -> String? {
        savedPasswords[profileID]
    }

    func setPassword(_ password: String, for profileID: ConnectionProfile.ID) throws {
        savedPasswords[profileID] = password
    }

    func removePassword(for profileID: ConnectionProfile.ID) throws {
        savedPasswords[profileID] = nil
    }
}

private struct ReconnectTestNotifier: DownloadCompletionNotifying {
    func notifyDownloadCompleted(torrentName: String) {}
}
