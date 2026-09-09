// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import XCTest
@testable import TransmissionRemoteMac

@MainActor
final class AppStoreRemovalTests: XCTestCase {
    override func tearDown() {
        AppStoreMockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testExplicitBatchRemovalFreezesTargetsAcrossSelectionMutation() {
        let store = makeStore()
        let profile = ConnectionProfile(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            name: "Removal Test",
            host: "transmission.example"
        )
        store.profiles = [profile]
        store.selectedProfileID = profile.id
        store.connectionState = .connected(rpcVersion: 18)
        store.torrents = [
            torrent(id: 1, name: "Alpha", totalSize: 100),
            torrent(id: 2, name: "Beta", totalSize: 250),
            torrent(id: 3, name: "Gamma", totalSize: 500)
        ]
        store.selectedTorrentIDs = [3]

        store.requestRemoveTorrents(in: Set([2, 1]), deleteLocalData: true)

        let confirmation = store.removalConfirmation
        XCTAssertEqual(confirmation?.torrentIDs, [1, 2])
        XCTAssertEqual(confirmation?.torrentHashes, ["hash-1", "hash-2"])
        XCTAssertEqual(confirmation?.torrentNames, ["Alpha", "Beta"])
        XCTAssertEqual(confirmation?.totalSize, 175)
        XCTAssertEqual(confirmation?.profileID, profile.id)
        XCTAssertEqual(confirmation?.deleteLocalData, true)

        store.selectedTorrentIDs = [2, 3]
        store.torrents = [torrent(id: 3, name: "Changed", totalSize: 999)]

        XCTAssertEqual(store.removalConfirmation, confirmation)
        XCTAssertEqual(store.removalConfirmation?.connectionToken, confirmation?.connectionToken)
    }

    func testDeleteDataCapabilityIsSeparateFromPlainRemovalAtRPC4() {
        let store = makeStore()
        store.torrents = [torrent(id: 1, name: "Alpha", totalSize: 100)]
        store.selectedTorrentIDs = [1]

        store.connectionState = .connected(rpcVersion: 3)
        XCTAssertTrue(store.canRemoveSelectedTorrents)
        XCTAssertFalse(store.canDeleteSelectedTorrentData)

        store.requestRemoveSelected(deleteLocalData: true)
        XCTAssertNil(store.removalConfirmation)

        store.connectionState = .connected(rpcVersion: 4)
        XCTAssertTrue(store.canRemoveSelectedTorrents)
        XCTAssertTrue(store.canDeleteSelectedTorrentData)

        store.requestRemoveSelected(deleteLocalData: true)
        XCTAssertEqual(store.removalConfirmation?.torrentIDs, [1])
        XCTAssertTrue(store.removalConfirmation?.deleteLocalData == true)
    }

    func testDisconnectInvalidatesPendingRemovalConfirmation() {
        let store = makeStore()
        store.connectionState = .connected(rpcVersion: 18)
        store.torrents = [torrent(id: 1, name: "Alpha", totalSize: 100)]
        store.selectedTorrentIDs = [1]
        store.requestRemoveSelected()

        XCTAssertNotNil(store.removalConfirmation)

        store.disconnect()

        XCTAssertNil(store.removalConfirmation)
        XCTAssertFalse(store.isRemoving)
    }

    func testConfirmRemovalSubmitsFrozenHashesAndCleansUp() async throws {
        let recorder = AppStoreRequestRecorder()
        AppStoreMockURLProtocol.requestHandler = { request in
            recorder.record(request)
            let body = try request.decodedActionBody()
            return appStoreRPCResponse(for: body.method)
        }
        let store = makeStore(urlSession: makeAppStoreMockSession())
        await store.connect()
        store.torrents = [torrent(id: 1, name: "Alpha", totalSize: 100)]
        store.selectedTorrentIDs = [1]
        store.requestRemoveSelected(deleteLocalData: true)
        let confirmation = try XCTUnwrap(store.removalConfirmation)

        store.torrents = [torrent(id: 1, name: "Replacement", totalSize: 200, hash: "replacement-hash")]
        await store.confirmRemoval(confirmation)

        let requests = try recorder.requests.map { try $0.decodedActionBody() }
        let removal = try XCTUnwrap(requests.first { $0.method == "torrent-remove" })
        XCTAssertEqual(removal.arguments["ids"], .array([.string("hash-1")]))
        XCTAssertEqual(removal.arguments["delete-local-data"], .bool(true))
        XCTAssertNil(store.removalConfirmation)
        XCTAssertFalse(store.isRemoving)
        store.disconnect()
    }

    func testConfirmRemovalSurfacesRPCFailureAndCleansUp() async throws {
        AppStoreMockURLProtocol.requestHandler = { request in
            let body = try request.decodedActionBody()
            if body.method == "torrent-remove" {
                return rpcTestResponse(body: #"{"result":"permission denied"}"#)
            }
            return appStoreRPCResponse(for: body.method)
        }
        let store = makeStore(urlSession: makeAppStoreMockSession())
        await store.connect()
        store.torrents = [torrent(id: 1, name: "Alpha", totalSize: 100)]
        store.selectedTorrentIDs = [1]
        store.requestRemoveSelected()
        let confirmation = try XCTUnwrap(store.removalConfirmation)

        await store.confirmRemoval(confirmation)

        XCTAssertEqual(store.errorMessage, "Transmission RPC failed: permission denied")
        XCTAssertNil(store.removalConfirmation)
        XCTAssertFalse(store.isRemoving)
        store.disconnect()
    }

    func testConfirmRemovalRejectsStaleConnectionWithoutSendingRPC() async throws {
        let recorder = AppStoreRequestRecorder()
        AppStoreMockURLProtocol.requestHandler = { request in
            recorder.record(request)
            let body = try request.decodedActionBody()
            return appStoreRPCResponse(for: body.method)
        }
        let store = makeStore(urlSession: makeAppStoreMockSession())
        await store.connect()
        store.torrents = [torrent(id: 1, name: "Alpha", totalSize: 100)]
        store.selectedTorrentIDs = [1]
        store.requestRemoveSelected()
        let confirmation = try XCTUnwrap(store.removalConfirmation)

        store.disconnect()
        await store.confirmRemoval(confirmation)

        let methods = try recorder.requests.map { try $0.decodedActionBody().method }
        XCTAssertFalse(methods.contains("torrent-remove"))
        XCTAssertEqual(
            store.errorMessage,
            "The Transmission connection changed. Review the current torrents before removing them."
        )
    }

    func testDuplicateConfirmationSubmitsOnlyOneRemovalRequest() async throws {
        let recorder = AppStoreRequestRecorder()
        let requestStarted = expectation(description: "torrent-remove started")
        let releaseRequest = DispatchSemaphore(value: 0)
        AppStoreMockURLProtocol.requestHandler = { request in
            recorder.record(request)
            let body = try request.decodedActionBody()
            if body.method == "torrent-remove" {
                requestStarted.fulfill()
                _ = releaseRequest.wait(timeout: .now() + 2)
            }
            return appStoreRPCResponse(for: body.method)
        }
        let store = makeStore(urlSession: makeAppStoreMockSession())
        await store.connect()
        store.torrents = [torrent(id: 1, name: "Alpha", totalSize: 100)]
        store.selectedTorrentIDs = [1]
        store.requestRemoveSelected()
        let confirmation = try XCTUnwrap(store.removalConfirmation)

        let firstConfirmation = Task {
            await store.confirmRemoval(confirmation)
        }
        await fulfillment(of: [requestStarted], timeout: 1)
        await store.confirmRemoval(confirmation)
        releaseRequest.signal()
        await firstConfirmation.value

        let methods = try recorder.requests.map { try $0.decodedActionBody().method }
        XCTAssertEqual(methods.filter { $0 == "torrent-remove" }.count, 1)
        XCTAssertFalse(store.isRemoving)
        store.disconnect()
    }

    func testFilterChangesPruneSelectionToVisibleTorrents() {
        let store = makeStore()
        let retained = torrent(
            id: 1,
            name: "Retained",
            totalSize: 100,
            downloadDir: "/downloads/keep",
            trackerHost: "keep.example",
            labels: ["keep"]
        )
        let removed = torrent(
            id: 2,
            name: "Removed",
            totalSize: 200,
            downloadDir: "/downloads/remove",
            trackerHost: "remove.example",
            labels: ["remove"]
        )
        store.torrents = [retained, removed]
        store.selectedTorrentIDs = [1, 2]

        store.torrentFilters.paths = ["/downloads/keep"]

        XCTAssertEqual(store.selectedTorrentIDs, [1])

        store.filterText = "no matching torrent"

        XCTAssertTrue(store.selectedTorrentIDs.isEmpty)
    }

    func testRemovalSizeIncludesValidAndUncheckedDataOnDisk() {
        let store = makeStore()
        store.connectionState = .connected(rpcVersion: 18)
        store.torrents = [
            torrent(
                id: 1,
                name: "Partial",
                totalSize: 1_000,
                haveValid: 125,
                haveUnchecked: 75
            )
        ]
        store.selectedTorrentIDs = [1]

        store.requestRemoveSelected(deleteLocalData: true)

        XCTAssertEqual(store.removalConfirmation?.totalSize, 200)
    }

    private func makeStore(urlSession: URLSession = .shared) -> AppStore {
        let profileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("profiles.json")
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        return AppStore(
            profileStore: makePersistedConnectionProfileStore(
                fileURL: profileURL,
                passwordStore: RemovalTestPasswordStore()
            ),
            userDefaults: defaults,
            downloadCompletionNotifier: RemovalTestDownloadCompletionNotifier(),
            clientFactory: { profile in
                TransmissionRPCClient(profile: profile, urlSession: urlSession)
            }
        )
    }

    private func torrent(
        id: Int,
        name: String,
        totalSize: Int,
        downloadDir: String = "/downloads",
        trackerHost: String = "tracker.example",
        labels: [String] = [],
        hash: String? = nil,
        haveValid: Int? = nil,
        haveUnchecked: Int? = nil
    ) -> TorrentSummary {
        var json: RPCArguments = [
            "id": .int(id),
            "name": .string(name),
            "status": .int(TorrentStatus.stopped.rawValue),
            "percentDone": .double(0),
            "totalSize": .int(totalSize),
            "sizeWhenDone": .int(totalSize),
            "leftUntilDone": .int(totalSize / 2),
            "hashString": .string(hash ?? "hash-\(id)"),
            "downloadDir": .string(downloadDir),
            "labels": .array(labels.map(JSONValue.string)),
            "trackerStats": .array([.object(["host": .string(trackerHost)])])
        ]
        if let haveValid {
            json["haveValid"] = .int(haveValid)
        }
        if let haveUnchecked {
            json["haveUnchecked"] = .int(haveUnchecked)
        }
        return TorrentSummary(json: json)
    }
}

private final class RemovalTestDownloadCompletionNotifier: DownloadCompletionNotifying {
    func notifyDownloadCompleted(torrentName: String) {}
}

private final class RemovalTestPasswordStore: ConnectionPasswordStoring {
    func password(for profileID: ConnectionProfile.ID) throws -> String? { nil }
    func setPassword(_ password: String, for profileID: ConnectionProfile.ID) throws {}
    func removePassword(for profileID: ConnectionProfile.ID) throws {}
}
