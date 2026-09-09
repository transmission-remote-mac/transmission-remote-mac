// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation
import XCTest
@testable import TransmissionRemoteMac

@MainActor
final class AppStoreApplicationBehaviorTests: XCTestCase {
    override func tearDown() {
        AppStoreMockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testSpeedAveragingChangesDisplayedAggregatesWithoutExtraRPCAndResetsOnProfileChange() async throws {
        let requestState = ApplicationBehaviorRPCState(
            sessionSpeeds: [(100, 200), (300, 600), (900, 1_200)]
        )
        AppStoreMockURLProtocol.requestHandler = requestState.response
        let clock = ApplicationBehaviorTestClock(now: 1)
        let setup = try makeStore(
            preferences: ApplicationBehaviorPreferences(
                speedAveraging: SpeedAveragingPolicy(
                    isEnabled: true,
                    sampleLimit: 10,
                    windowSeconds: 120
                ),
                completionNotificationsEnabled: true,
                addDefaults: .defaults
            ),
            speedSampleClock: { clock.now }
        )

        await setup.store.connect()
        XCTAssertEqual(setup.store.sessionStats?.downloadSpeed, 100)
        XCTAssertEqual(setup.store.sessionStats?.uploadSpeed, 200)

        clock.now = 2
        await setup.store.refresh()
        XCTAssertEqual(setup.store.sessionStats?.downloadSpeed, 200)
        XCTAssertEqual(setup.store.sessionStats?.uploadSpeed, 400)
        XCTAssertEqual(requestState.count(of: "session-stats"), 2)

        clock.now = 3
        await setup.store.switchProfile(to: setup.otherProfileID)
        XCTAssertEqual(setup.store.sessionStats?.downloadSpeed, 900)
        XCTAssertEqual(setup.store.sessionStats?.uploadSpeed, 1_200)
        XCTAssertEqual(requestState.count(of: "session-stats"), 3)
    }

    func testDisconnectDropsPreviousSpeedSamplesBeforeReconnect() async throws {
        let requestState = ApplicationBehaviorRPCState(
            sessionSpeeds: [(100, 200), (300, 600), (900, 1_200)]
        )
        AppStoreMockURLProtocol.requestHandler = requestState.response
        let clock = ApplicationBehaviorTestClock(now: 1)
        let setup = try makeStore(
            preferences: ApplicationBehaviorPreferences(
                speedAveraging: SpeedAveragingPolicy(
                    isEnabled: true,
                    sampleLimit: 10,
                    windowSeconds: 120
                ),
                completionNotificationsEnabled: true,
                addDefaults: .defaults
            ),
            speedSampleClock: { clock.now }
        )

        await setup.store.connect()
        clock.now = 2
        await setup.store.refresh()
        XCTAssertEqual(setup.store.sessionStats?.downloadSpeed, 200)

        setup.store.disconnect()
        clock.now = 3
        await setup.store.connect()

        XCTAssertEqual(setup.store.sessionStats?.downloadSpeed, 900)
        XCTAssertEqual(setup.store.sessionStats?.uploadSpeed, 1_200)
    }

    func testDisabledCompletionNotificationsSuppressDeliveryWithoutReplay() async throws {
        let requestState = ApplicationBehaviorRPCState(
            sessionSpeeds: [(0, 0), (0, 0), (0, 0), (0, 0)],
            torrentStatuses: [4, 6, 4, 6]
        )
        AppStoreMockURLProtocol.requestHandler = requestState.response
        let notifier = ApplicationBehaviorTestNotifier()
        let setup = try makeStore(
            preferences: ApplicationBehaviorPreferences(
                speedAveraging: .defaults,
                completionNotificationsEnabled: false,
                addDefaults: .defaults
            ),
            notifier: notifier
        )

        await setup.store.connect()
        await setup.store.refresh()
        XCTAssertTrue(notifier.torrentNames.isEmpty)

        var enabledPreferences = setup.behaviorStore.preferences
        enabledPreferences.completionNotificationsEnabled = true
        try setup.behaviorStore.save(enabledPreferences)
        await Task.yield()

        await setup.store.refresh()
        XCTAssertTrue(notifier.torrentNames.isEmpty)
        await setup.store.refresh()
        XCTAssertEqual(notifier.torrentNames, ["Example"])
    }

    private func makeStore(
        preferences: ApplicationBehaviorPreferences,
        notifier: ApplicationBehaviorTestNotifier = ApplicationBehaviorTestNotifier(),
        speedSampleClock: @escaping () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        }
    ) throws -> (
        store: AppStore,
        behaviorStore: ApplicationBehaviorPreferencesStore,
        otherProfileID: ConnectionProfile.ID
    ) {
        let suiteName = "AppStoreApplicationBehaviorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let profileStore = ConnectionProfileStore(
            fileURL: directoryURL.appendingPathComponent("profiles.json"),
            passwordStore: ApplicationBehaviorTestPasswordStore()
        )
        let primaryProfile = ConnectionProfile(name: "Primary", host: "primary.invalid")
        let otherProfile = ConnectionProfile(name: "Other", host: "other.invalid")
        try profileStore.save(ConnectionProfileCollection(
            profiles: [primaryProfile, otherProfile],
            selectedProfileID: primaryProfile.id
        ))
        let behaviorStore = ApplicationBehaviorPreferencesStore(userDefaults: defaults)
        try behaviorStore.save(preferences)
        let session = makeAppStoreMockSession()
        let store = AppStore(
            profileStore: profileStore,
            userDefaults: defaults,
            downloadCompletionNotifier: notifier,
            behaviorPreferencesStore: behaviorStore,
            speedSampleClock: speedSampleClock,
            clientFactory: { profile in
                TransmissionRPCClient(profile: profile, urlSession: session)
            }
        )

        addTeardownBlock {
            try? FileManager.default.removeItem(at: directoryURL)
            defaults.removePersistentDomain(forName: suiteName)
        }
        return (store, behaviorStore, otherProfile.id)
    }
}

private final class ApplicationBehaviorTestClock {
    var now: TimeInterval

    init(now: TimeInterval) {
        self.now = now
    }
}

private final class ApplicationBehaviorRPCState: @unchecked Sendable {
    private let lock = NSLock()
    private var methods: [String] = []
    private var sessionSpeeds: [(Int64, Int64)]
    private var torrentStatuses: [Int]

    init(
        sessionSpeeds: [(Int64, Int64)],
        torrentStatuses: [Int] = []
    ) {
        self.sessionSpeeds = sessionSpeeds
        self.torrentStatuses = torrentStatuses
    }

    func response(for request: URLRequest) throws -> (HTTPURLResponse, Data) {
        let action = try request.decodedActionBody()
        return lock.withLock {
            methods.append(action.method)
            switch action.method {
            case "session-get":
                return rpcTestResponse(
                    body: #"{"result":"success","arguments":{"rpc-version":18,"version":"4.0","download-dir":"/downloads"}}"#
                )
            case "session-stats":
                let speed = sessionSpeeds.isEmpty ? (0, 0) : sessionSpeeds.removeFirst()
                return rpcTestResponse(
                    body: """
                    {"result":"success","arguments":{"downloadSpeed":\(speed.0),"uploadSpeed":\(speed.1)}}
                    """
                )
            case "torrent-get":
                guard !torrentStatuses.isEmpty else {
                    return rpcTestResponse(
                        body: #"{"result":"success","arguments":{"torrents":[]}}"#
                    )
                }
                let status = torrentStatuses.removeFirst()
                let isComplete = status == 6
                return rpcTestResponse(
                    body: """
                    {"result":"success","arguments":{"torrents":[{"id":1,"name":"Example","hashString":"0123456789abcdef0123456789abcdef01234567","status":\(status),"percentDone":\(isComplete ? 1 : 0.5),"sizeWhenDone":100,"leftUntilDone":\(isComplete ? 0 : 50)}]}}
                    """
                )
            default:
                return rpcTestResponse(body: #"{"result":"success","arguments":{}}"#)
            }
        }
    }

    func count(of method: String) -> Int {
        lock.withLock { methods.filter { $0 == method }.count }
    }
}

private final class ApplicationBehaviorTestNotifier: DownloadCompletionNotifying {
    private(set) var torrentNames: [String] = []

    func notifyDownloadCompleted(torrentName: String) {
        torrentNames.append(torrentName)
    }
}

private final class ApplicationBehaviorTestPasswordStore: ConnectionPasswordStoring {
    func password(for profileID: ConnectionProfile.ID) throws -> String? { nil }
    func setPassword(_ password: String, for profileID: ConnectionProfile.ID) throws {}
    func removePassword(for profileID: ConnectionProfile.ID) throws {}
}
