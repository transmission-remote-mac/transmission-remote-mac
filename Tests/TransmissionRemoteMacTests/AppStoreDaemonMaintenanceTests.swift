// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation
import XCTest
@testable import TransmissionRemoteMac

@MainActor
final class AppStoreDaemonMaintenanceTests: XCTestCase {
    override func tearDown() {
        AppStoreMockURLProtocol.requestHandler = nil
        AppStoreMockURLProtocol.requestDidFinish = nil
        super.tearDown()
    }

    func testPortTestSuppressesDuplicatesAndDoesNotRefreshSessionOrTorrents() async throws {
        let portStarted = expectation(description: "port test started")
        let portGate = DispatchSemaphore(value: 0)
        let recorder = MaintenanceRequestRecorder()
        AppStoreMockURLProtocol.requestHandler = { request in
            let method = try request.maintenanceRPCMethod()
            recorder.record(method)
            if method == "port-test" {
                portStarted.fulfill()
                _ = portGate.wait(timeout: .now() + 2)
            }
            return maintenanceResponse(for: method, blocklistEnabled: true)
        }
        let store = try makeStore()
        await store.connect()
        let baselineSessionGets = recorder.count("session-get")
        let baselineTorrentGets = recorder.count("torrent-get")

        store.testPort(.ipv6)
        store.testPort(.ipv4)
        await fulfillment(of: [portStarted], timeout: 1)

        XCTAssertTrue(store.isTestingPort)
        XCTAssertEqual(recorder.count("port-test"), 1)
        portGate.signal()
        let portCompleted = await waitUntil { !store.isTestingPort }
        XCTAssertTrue(portCompleted)

        XCTAssertEqual(recorder.count("session-get"), baselineSessionGets)
        XCTAssertEqual(recorder.count("torrent-get"), baselineTorrentGets)
        XCTAssertEqual(
            store.daemonMaintenanceNotice,
            .portTestSucceeded(
                try PortTestResult(
                    requestedProtocol: .ipv6,
                    reportedProtocol: .ipv6,
                    isOpen: true
                )
            )
        )
        store.disconnect()
    }

    func testDisconnectRejectsStaleMaintenanceCompletion() async throws {
        let portStarted = expectation(description: "port test started")
        let portFinished = expectation(description: "port test transport finished")
        let portGate = DispatchSemaphore(value: 0)
        AppStoreMockURLProtocol.requestDidFinish = { request in
            if (try? request.maintenanceRPCMethod()) == "port-test" {
                portFinished.fulfill()
            }
        }
        AppStoreMockURLProtocol.requestHandler = { request in
            let method = try request.maintenanceRPCMethod()
            if method == "port-test" {
                portStarted.fulfill()
                _ = portGate.wait(timeout: .now() + 2)
            }
            return maintenanceResponse(for: method, blocklistEnabled: true)
        }
        let store = try makeStore()
        await store.connect()

        store.testPort(.automatic)
        await fulfillment(of: [portStarted], timeout: 1)
        store.disconnect()
        portGate.signal()
        await fulfillment(of: [portFinished], timeout: 1)
        await Task.yield()

        XCTAssertFalse(store.isTestingPort)
        XCTAssertNil(store.daemonMaintenanceNotice)
        XCTAssertEqual(store.connectionState, .disconnected)
    }

    func testBlocklistSuccessPerformsExactlyOneNarrowSessionRefresh() async throws {
        let recorder = MaintenanceRequestRecorder()
        AppStoreMockURLProtocol.requestHandler = { request in
            let method = try request.maintenanceRPCMethod()
            recorder.record(method)
            return maintenanceResponse(for: method, blocklistEnabled: true)
        }
        let store = try makeStore()
        await store.connect()
        let baselineSessionGets = recorder.count("session-get")
        let baselineSessionStats = recorder.count("session-stats")
        let baselineTorrentGets = recorder.count("torrent-get")

        store.updateBlocklist()
        let blocklistCompleted = await waitUntil { !store.isUpdatingBlocklist }
        XCTAssertTrue(blocklistCompleted)

        XCTAssertEqual(recorder.count("blocklist-update"), 1)
        XCTAssertEqual(recorder.count("session-get"), baselineSessionGets + 1)
        XCTAssertEqual(recorder.count("session-stats"), baselineSessionStats)
        XCTAssertEqual(recorder.count("torrent-get"), baselineTorrentGets)
        XCTAssertEqual(
            store.daemonMaintenanceNotice,
            .blocklistUpdateSucceeded(try BlocklistUpdateResult(entryCount: 12_345))
        )
        store.disconnect()
    }

    func testDisabledSavedBlocklistRejectsUpdateBeforeRPC() async throws {
        let recorder = MaintenanceRequestRecorder()
        AppStoreMockURLProtocol.requestHandler = { request in
            let method = try request.maintenanceRPCMethod()
            recorder.record(method)
            return maintenanceResponse(for: method, blocklistEnabled: false)
        }
        let store = try makeStore()
        await store.connect()

        store.updateBlocklist()
        await Task.yield()

        XCTAssertEqual(recorder.count("blocklist-update"), 0)
        XCTAssertFalse(store.isUpdatingBlocklist)
        store.disconnect()
    }

    private func makeStore() throws -> AppStore {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directoryURL.appendingPathComponent("profiles.json")
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        var profile = ConnectionProfile.localDefault
        profile.connectOnLaunch = false
        let profileStore = ConnectionProfileStore(
            fileURL: fileURL,
            passwordStore: MaintenancePasswordStore()
        )
        try profileStore.save(
            try ConnectionProfileCollection(profiles: [profile], selectedProfileID: profile.id)
        )
        return AppStore(
            profileStore: profileStore,
            userDefaults: temporaryUserDefaults(),
            downloadCompletionNotifier: MaintenanceNotifier(),
            selectionDebounceDuration: .zero,
            clientFactory: { profile in
                TransmissionRPCClient(profile: profile, urlSession: makeAppStoreMockSession())
            }
        )
    }

    private func temporaryUserDefaults() -> UserDefaults {
        let suiteName = "AppStoreDaemonMaintenanceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return defaults
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
}

private func maintenanceResponse(
    for method: String,
    blocklistEnabled: Bool
) -> (HTTPURLResponse, Data) {
    switch method {
    case "session-get":
        rpcTestResponse(
            body: #"{"result":"success","arguments":{"rpc-version":18,"version":"4.1","download-dir":"/downloads","peer-port":51413,"blocklist-enabled":\#(blocklistEnabled)}}"#
        )
    case "session-stats":
        rpcTestResponse(body: #"{"result":"success","arguments":{}}"#)
    case "torrent-get":
        rpcTestResponse(body: #"{"result":"success","arguments":{"torrents":[]}}"#)
    case "port-test":
        rpcTestResponse(
            body: #"{"result":"success","arguments":{"port-is-open":true,"ip-protocol":"ipv6"}}"#
        )
    case "blocklist-update":
        rpcTestResponse(body: #"{"result":"success","arguments":{"blocklist-size":12345}}"#)
    default:
        rpcTestResponse(body: #"{"result":"success","arguments":{}}"#)
    }
}

private final class MaintenanceRequestRecorder {
    private let lock = NSLock()
    private var methods: [String] = []

    func record(_ method: String) {
        lock.withLock { methods.append(method) }
    }

    func count(_ method: String) -> Int {
        lock.withLock { methods.filter { $0 == method }.count }
    }
}

private final class MaintenancePasswordStore: ConnectionPasswordStoring {
    func password(for profileID: ConnectionProfile.ID) throws -> String? { nil }
    func setPassword(_ password: String, for profileID: ConnectionProfile.ID) throws {}
    func removePassword(for profileID: ConnectionProfile.ID) throws {}
}

private struct MaintenanceNotifier: DownloadCompletionNotifying {
    func notifyDownloadCompleted(torrentName: String) {}
}

private extension URLRequest {
    func maintenanceRPCMethod() throws -> String {
        let data: Data
        if let httpBody {
            data = httpBody
        } else if let httpBodyStream {
            httpBodyStream.open()
            defer { httpBodyStream.close() }
            var body = Data()
            var buffer = [UInt8](repeating: 0, count: 1_024)
            while httpBodyStream.hasBytesAvailable {
                let count = httpBodyStream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                body.append(buffer, count: count)
            }
            data = body
        } else {
            throw TransmissionRPCError.invalidResponse
        }
        return try JSONDecoder().decode(RPCRequest.self, from: data).method
    }
}
