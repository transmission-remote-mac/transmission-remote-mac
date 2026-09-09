// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import XCTest
@testable import TransmissionRemoteMac

final class SessionBandwidthControlTests: XCTestCase {
    func testNormalSpeedLimitsExposeCurrentPresetsAndDisplay() {
        let session = SessionInfo(arguments: [
            "rpc-version": .int(17),
            "speed-limit-down-enabled": .bool(true),
            "speed-limit-down": .int(500),
            "speed-limit-up-enabled": .bool(false),
            "speed-limit-up": .int(100),
            "alt-speed-enabled": .bool(false)
        ])

        XCTAssertEqual(session.activeDownloadSpeedLimitKBps, 500)
        XCTAssertNil(session.activeUploadSpeedLimitKBps)
        XCTAssertTrue(session.isCurrentSpeedPreset(.limited(500), direction: .download))
        XCTAssertTrue(session.isCurrentSpeedPreset(.unlimited, direction: .upload))
        XCTAssertEqual(session.activeSpeedLimitsDisplay, "Limits: ↓ 500 KB/s · ↑ Unlimited")
    }

    func testAlternateSpeedLimitsReplaceNormalPresetSelection() {
        let session = SessionInfo(arguments: [
            "rpc-version": .int(5),
            "speed-limit-down-enabled": .bool(true),
            "speed-limit-down": .int(500),
            "speed-limit-up-enabled": .bool(false),
            "alt-speed-enabled": .bool(true),
            "alt-speed-down": .int(100),
            "alt-speed-up": .int(25)
        ])

        XCTAssertTrue(session.isAlternateSpeedEnabled)
        XCTAssertEqual(session.activeDownloadSpeedLimitKBps, 100)
        XCTAssertEqual(session.activeUploadSpeedLimitKBps, 25)
        XCTAssertFalse(session.isCurrentSpeedPreset(.limited(500), direction: .download))
        XCTAssertFalse(session.isCurrentSpeedPreset(.unlimited, direction: .upload))
        XCTAssertEqual(session.activeSpeedLimitsDisplay, "Alt limits: ↓ 100 KB/s · ↑ 25 KB/s")
    }

    func testAlternateSpeedIsUnavailableBeforeRPCFive() {
        let session = SessionInfo(arguments: [
            "rpc-version": .int(4),
            "speed-limit-down-enabled": .bool(false),
            "speed-limit-up-enabled": .bool(false),
            "alt-speed-enabled": .bool(true),
            "alt-speed-down": .int(100),
            "alt-speed-up": .int(25)
        ])

        XCTAssertFalse(session.isAlternateSpeedEnabled)
        XCTAssertNil(session.activeDownloadSpeedLimitKBps)
        XCTAssertNil(session.activeUploadSpeedLimitKBps)
    }

    @MainActor
    func testCustomCurrentLimitIsIncludedInAvailablePresets() {
        let store = AppStore(
            profileStore: ConnectionProfileStore(
                fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
                passwordStore: BandwidthTestPasswordStore()
            ),
            userDefaults: UserDefaults(suiteName: UUID().uuidString)!,
            downloadCompletionNotifier: BandwidthTestNotifier()
        )
        store.sessionInfo = SessionInfo(arguments: [
            "rpc-version": .int(18),
            "speed-limit-down-enabled": .bool(true),
            "speed-limit-down": .int(750),
            "speed-limit-up-enabled": .bool(false),
            "alt-speed-enabled": .bool(false)
        ])

        XCTAssertTrue(store.speedPresets(for: .download).contains(.limited(750)))
        XCTAssertTrue(store.isCurrentSpeedPreset(.limited(750), direction: .download))
    }

    @MainActor
    func testSelectedProfileProvidesPerServerSpeedPresets() throws {
        let store = AppStore(
            profileStore: ConnectionProfileStore(
                fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
                passwordStore: BandwidthTestPasswordStore()
            ),
            userDefaults: UserDefaults(suiteName: UUID().uuidString)!,
            downloadCompletionNotifier: BandwidthTestNotifier()
        )
        let profile = try ConnectionProfile.validated(
            name: "Custom speeds",
            host: "transmission.example",
            transferPreferences: ProfileTransferPreferences(
                downloadSpeedPresetsKBps: [123, 456],
                uploadSpeedPresetsKBps: [78]
            )
        )

        store.applyConnectionProfiles([profile], selectedProfileID: profile.id)
        store.sessionInfo = SessionInfo(arguments: [
            "rpc-version": .int(18),
            "speed-limit-down-enabled": .bool(false),
            "speed-limit-up-enabled": .bool(false),
            "alt-speed-enabled": .bool(false),
        ])

        XCTAssertEqual(store.speedPresets(for: .download), [.unlimited, .limited(123), .limited(456)])
        XCTAssertEqual(store.speedPresets(for: .upload), [.unlimited, .limited(78)])
    }

    @MainActor
    func testGlobalSpeedMutationSendsExpectedPayloadAndResetsBusyState() async throws {
        defer { AppStoreMockURLProtocol.requestHandler = nil }
        let recorder = AppStoreRequestRecorder()
        AppStoreMockURLProtocol.requestHandler = { request in
            recorder.record(request)
            let body = try request.decodedActionBody()
            return appStoreRPCResponse(for: body.method)
        }
        let store = makeConnectedStore()
        await store.connect()

        await store.setGlobalSpeedLimit(.limited(750), direction: .download)

        let requests = try recorder.requests.map { try $0.decodedActionBody() }
        let sessionSet = try XCTUnwrap(requests.first { $0.method == "session-set" })
        XCTAssertEqual(sessionSet.arguments["speed-limit-down-enabled"], .bool(true))
        XCTAssertEqual(sessionSet.arguments["speed-limit-down"], .int(750))
        XCTAssertEqual(sessionSet.arguments["alt-speed-enabled"], .bool(false))
        XCTAssertFalse(store.isUpdatingGlobalBandwidth)
        store.disconnect()
    }

    @MainActor
    func testGlobalSpeedMutationSurfacesFailureAndResetsBusyState() async {
        defer { AppStoreMockURLProtocol.requestHandler = nil }
        AppStoreMockURLProtocol.requestHandler = { request in
            let body = try request.decodedActionBody()
            if body.method == "session-set" {
                return rpcTestResponse(body: #"{"result":"permission denied"}"#)
            }
            return appStoreRPCResponse(for: body.method)
        }
        let store = makeConnectedStore()
        await store.connect()

        await store.setGlobalSpeedLimit(.limited(750), direction: .download)

        XCTAssertEqual(store.errorMessage, "Transmission RPC failed: permission denied")
        XCTAssertFalse(store.isUpdatingGlobalBandwidth)
        store.disconnect()
    }

    @MainActor
    func testReconnectWaitsForCancelledGlobalSpeedMutation() async throws {
        defer { AppStoreMockURLProtocol.requestHandler = nil }
        let recorder = AppStoreRequestRecorder()
        let requestStarted = expectation(description: "session-set started")
        let releaseRequest = DispatchSemaphore(value: 0)
        AppStoreMockURLProtocol.requestHandler = { request in
            recorder.record(request)
            let body = try request.decodedActionBody()
            if body.method == "session-set" {
                requestStarted.fulfill()
                _ = releaseRequest.wait(timeout: .now() + 2)
            }
            return appStoreRPCResponse(for: body.method)
        }
        let store = makeConnectedStore()
        await store.connect()
        let initialMethods = try recorder.requests.map { try $0.decodedActionBody().method }
        let initialSessionGetCount = initialMethods.filter { $0 == "session-get" }.count

        let updateTask = Task {
            await store.setGlobalSpeedLimit(.limited(750), direction: .download)
        }
        await fulfillment(of: [requestStarted], timeout: 1)
        XCTAssertTrue(store.isUpdatingGlobalBandwidth)

        store.disconnect()
        let reconnectTask = Task {
            await store.connect()
        }
        await Task.yield()
        await Task.yield()
        var methods = try recorder.requests.map { try $0.decodedActionBody().method }
        XCTAssertEqual(methods.filter { $0 == "session-get" }.count, initialSessionGetCount)
        XCTAssertFalse(store.canConnect)
        XCTAssertFalse(store.canSetGlobalSpeedLimit)

        releaseRequest.signal()
        await updateTask.value
        await reconnectTask.value

        XCTAssertFalse(store.isUpdatingGlobalBandwidth)
        XCTAssertNil(store.errorMessage)
        methods = try recorder.requests.map { try $0.decodedActionBody().method }
        XCTAssertEqual(methods.filter { $0 == "session-get" }.count, initialSessionGetCount * 2)
        XCTAssertTrue(store.connectionState.isConnected)
        store.disconnect()
    }

    @MainActor
    private func makeConnectedStore() -> AppStore {
        let profileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("profiles.json")
        let session = makeAppStoreMockSession()
        return AppStore(
            profileStore: makePersistedConnectionProfileStore(
                fileURL: profileURL,
                passwordStore: BandwidthTestPasswordStore()
            ),
            userDefaults: UserDefaults(suiteName: UUID().uuidString)!,
            downloadCompletionNotifier: BandwidthTestNotifier(),
            clientFactory: { profile in
                TransmissionRPCClient(profile: profile, urlSession: session)
            }
        )
    }
}

private final class BandwidthTestPasswordStore: ConnectionPasswordStoring {
    func password(for profileID: ConnectionProfile.ID) throws -> String? { nil }
    func setPassword(_ password: String, for profileID: ConnectionProfile.ID) throws {}
    func removePassword(for profileID: ConnectionProfile.ID) throws {}
}

private final class BandwidthTestNotifier: DownloadCompletionNotifying {
    func notifyDownloadCompleted(torrentName: String) {}
}
