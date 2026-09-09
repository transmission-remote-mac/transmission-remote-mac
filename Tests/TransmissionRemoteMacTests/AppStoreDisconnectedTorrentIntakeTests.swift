// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation
import XCTest
@testable import TransmissionRemoteMac

@MainActor
final class AppStoreDisconnectedTorrentIntakeTests: XCTestCase {
    override func tearDown() {
        AppStoreMockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testDisconnectedExternalBatchBindsOnceAfterConnectAndPreservesOrder() async throws {
        let recorder = AppStoreRequestRecorder()
        AppStoreMockURLProtocol.requestHandler = { request in
            recorder.record(request)
            let action = try request.decodedActionBody()
            if action.method == "torrent-add" {
                return rpcTestResponse(
                    body: #"{"result":"success","arguments":{"torrent-added":{"id":42,"hashString":"0123456789abcdef0123456789abcdef01234567","name":"External"}}}"#
                )
            }
            return appStoreRPCResponse(for: action.method)
        }
        let store = try makeStore(promptsForDownloadOptions: true)
        let ownerID = UUID()
        store.registerAddTorrentPresentationOwner(ownerID)
        let firstSource = "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567"
        let secondFile = URL(fileURLWithPath: "/tmp/second-open-event.torrent")
        let initialOptions = AddTorrentInitialOptions(
            startIntent: .paused,
            priority: .high,
            unwantedFiles: .daemonDefault,
            peerLimit: .limited(29)
        )

        store.requestAddTorrents(
            [
                .remote(firstSource),
                .remote(firstSource),
                .localFile(secondFile)
            ],
            initialOptions: initialOptions
        )

        XCTAssertNil(store.pendingAddTorrent)
        XCTAssertFalse(store.showingAddTorrent)
        XCTAssertFalse(recordedActions(recorder).contains { $0.method == "torrent-add" })

        await store.connect()

        let firstRequest = try XCTUnwrap(store.presentedAddTorrent(for: ownerID))
        XCTAssertEqual(firstRequest.source, .remote(firstSource))
        XCTAssertEqual(firstRequest.initialOptions, initialOptions)
        let result = await store.addTorrent(
            requestID: firstRequest.id,
            presentationOwnerID: ownerID,
            source: firstSource,
            startPaused: true,
            downloadDirectory: nil,
            peerLimit: 29
        )
        XCTAssertEqual(result, .succeeded)
        XCTAssertEqual(
            recordedActions(recorder).filter { $0.method == "torrent-add" }.count,
            1
        )
        store.addTorrentPresentationWillDismiss(requestID: firstRequest.id, ownerID: ownerID)
        store.addTorrentSheetDidDismiss(requestID: firstRequest.id, ownerID: ownerID)

        let secondRequest = try XCTUnwrap(store.presentedAddTorrent(for: ownerID))
        XCTAssertEqual(secondRequest.source, .localFile(secondFile))
        XCTAssertEqual(secondRequest.initialOptions, initialOptions)
        XCTAssertNil(store.errorMessage)
        store.disconnect()
    }

    func testDisconnectedPromptlessSourceDirectSubmitsExactlyOnceAfterConnect() async throws {
        let recorder = AppStoreRequestRecorder()
        AppStoreMockURLProtocol.requestHandler = { request in
            recorder.record(request)
            let action = try request.decodedActionBody()
            if action.method == "torrent-add" {
                return rpcTestResponse(
                    body: #"{"result":"success","arguments":{"torrent-added":{"id":43,"hashString":"abcdef0123456789abcdef0123456789abcdef01","name":"Direct external"}}}"#
                )
            }
            return appStoreRPCResponse(for: action.method)
        }
        let store = try makeStore(promptsForDownloadOptions: false)
        let source = "magnet:?xt=urn:btih:abcdef0123456789abcdef0123456789abcdef01"

        store.requestAddTorrents([.remote(source), .remote(source)])

        XCTAssertNil(store.pendingAddTorrent)
        XCTAssertFalse(recordedActions(recorder).contains { $0.method == "torrent-add" })

        await store.connect()

        let didFinish = await waitUntil {
            self.recordedActions(recorder).filter { $0.method == "torrent-add" }.count == 1
                && store.pendingAddTorrent == nil
        }
        XCTAssertTrue(didFinish)
        XCTAssertEqual(
            recordedActions(recorder).filter { $0.method == "torrent-add" }.count,
            1
        )
        XCTAssertFalse(store.showingAddTorrent)
        XCTAssertNil(store.errorMessage)
        store.disconnect()
    }

    func testTeardownDiscardsBoundRequestWithoutRebindingItOnReconnect() async throws {
        let recorder = AppStoreRequestRecorder()
        AppStoreMockURLProtocol.requestHandler = { request in
            recorder.record(request)
            return appStoreRPCResponse(for: try request.decodedActionBody().method)
        }
        let store = try makeStore(promptsForDownloadOptions: true)
        let ownerID = UUID()
        store.registerAddTorrentPresentationOwner(ownerID)
        await store.connect()
        store.requestAddTorrent(
            source: "magnet:?xt=urn:btih:fedcba9876543210fedcba9876543210fedcba98"
        )
        let staleRequest = try XCTUnwrap(store.presentedAddTorrent(for: ownerID))

        store.disconnect()

        XCTAssertNil(store.pendingAddTorrent)
        XCTAssertFalse(store.showingAddTorrent)
        await store.connect()
        XCTAssertNil(store.presentedAddTorrent(for: ownerID))
        XCTAssertFalse(recordedActions(recorder).contains { $0.method == "torrent-add" })
        XCTAssertNil(store.errorMessage)

        store.addTorrentPresentationWillDismiss(requestID: staleRequest.id, ownerID: ownerID)
        store.addTorrentSheetDidDismiss(requestID: staleRequest.id, ownerID: ownerID)
        XCTAssertNil(store.pendingAddTorrent)
        store.disconnect()
    }

    private func makeStore(promptsForDownloadOptions: Bool) throws -> AppStore {
        let profileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("profiles.json")
        let profileStore = makePersistedConnectionProfileStore(
            fileURL: profileURL,
            passwordStore: DisconnectedIntakeTestPasswordStore()
        )
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let behaviorStore = ApplicationBehaviorPreferencesStore(userDefaults: defaults)
        try behaviorStore.save(ApplicationBehaviorPreferences(
            speedAveraging: .defaults,
            completionNotificationsEnabled: true,
            promptsForDownloadOptions: promptsForDownloadOptions,
            addDefaults: .defaults
        ))
        let session = makeAppStoreMockSession()
        return AppStore(
            profileStore: profileStore,
            userDefaults: defaults,
            downloadCompletionNotifier: DisconnectedIntakeTestNotifier(),
            behaviorPreferencesStore: behaviorStore,
            clientFactory: { profile in
                TransmissionRPCClient(profile: profile, urlSession: session)
            }
        )
    }

    private func recordedActions(_ recorder: AppStoreRequestRecorder) -> [RPCRequest] {
        recorder.requests.compactMap { try? $0.decodedActionBody() }
    }

    private func waitUntil(
        attempts: Int = 200,
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0 ..< attempts {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }
}

private final class DisconnectedIntakeTestPasswordStore: ConnectionPasswordStoring {
    func password(for profileID: ConnectionProfile.ID) throws -> String? { nil }
    func setPassword(_ password: String, for profileID: ConnectionProfile.ID) throws {}
    func removePassword(for profileID: ConnectionProfile.ID) throws {}
}

private final class DisconnectedIntakeTestNotifier: DownloadCompletionNotifying {
    func notifyDownloadCompleted(torrentName: String) {}
}
