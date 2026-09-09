// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Combine
import XCTest
@testable import TransmissionRemoteMac

@MainActor
final class AppStoreInstantDetailTests: XCTestCase {
    override func tearDown() {
        AppStoreMockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testReselectionRendersCachedFilesImmediatelyButCannotReuseOldMutationOwner() async throws {
        let recorder = AppStoreRequestRecorder()
        let store = makeStore(recorder: recorder)
        await store.connect()
        store.selectedTorrentDetailPane = .files
        store.selectedTorrentIDs = [1]
        let loaded = await waitForPollingCondition { store.selectedTorrentFileMutationOwner != nil }
        XCTAssertTrue(loaded)
        let original = try XCTUnwrap(store.selectedTorrentDetailState.detail)
        let oldOwner = try XCTUnwrap(store.selectedTorrentFileMutationOwner)

        store.selectedTorrentIDs = [2]
        store.selectedTorrentIDs = [1]
        XCTAssertEqual(store.selectedTorrentDetailState.detail?.filesSnapshotRevision, original.filesSnapshotRevision)
        XCTAssertEqual(store.selectedTorrentDetailState.detail?.files.count, 1)
        XCTAssertNil(store.selectedTorrentFileMutationOwner)

        var detailPublications = 0
        let observation = store.$selectedTorrentDetailState.dropFirst().sink { _ in detailPublications += 1 }
        let revalidated = await waitForPollingCondition { store.selectedTorrentFileMutationOwner != nil }
        XCTAssertTrue(revalidated)
        XCTAssertEqual(detailPublications, 0)
        XCTAssertEqual(store.selectedTorrentDetailState.detail?.filesSnapshotRevision, original.filesSnapshotRevision)
        await store.setTorrentFilesWanted(false, fileIndexes: [0], owner: oldOwner)
        XCTAssertEqual(try recorder.requests.filter { try $0.decodedActionBody().method == "torrent-set" }.count, 0)
        withExtendedLifetime(observation) {}
        store.disconnect()
    }

    func testReselectionKeepsCachedTrackersReadOnlyUntilEqualPayloadRevalidates() async throws {
        let store = makeStore(recorder: AppStoreRequestRecorder())
        await store.connect()
        store.selectedTorrentDetailPane = .trackers
        store.selectedTorrentIDs = [1]
        let loaded = await waitForPollingCondition { store.selectedTorrentTrackerMutationOwner != nil }
        XCTAssertTrue(loaded)
        let revision = store.selectedTorrentDetailState.detail?.trackersSnapshotRevision
        store.selectedTorrentIDs = [2]
        store.selectedTorrentIDs = [1]
        XCTAssertEqual(store.selectedTorrentDetailState.detail?.trackersSnapshotRevision, revision)
        XCTAssertNil(store.selectedTorrentTrackerMutationOwner)
        let revalidated = await waitForPollingCondition { store.selectedTorrentTrackerMutationOwner != nil }
        XCTAssertTrue(revalidated)
        XCTAssertEqual(store.selectedTorrentDetailState.detail?.trackersSnapshotRevision, revision)
        store.disconnect()
    }

    func testDefaultSelectionRequestsOnlyDemandedPaneAndReconnectDropsCache() async throws {
        let recorder = AppStoreRequestRecorder()
        let store = makeStore(recorder: recorder)
        await store.connect()
        store.selectedTorrentIDs = [1]
        let loaded = await waitForPollingCondition { store.selectedTorrentDetailState.detail?.generalInfo != nil }
        XCTAssertTrue(loaded)
        let details = try recorder.requests.map { try $0.decodedActionBody() }.filter {
            $0.method == "torrent-get" && $0.arguments["ids"]?.arrayValue?.first?.stringValue != nil
        }
        XCTAssertEqual(details.count, 1)
        XCTAssertEqual(details.first?.arguments["ids"], .array([.string(String(repeating: "1", count: 40))]))
        XCTAssertFalse(details.contains { $0.arguments["fields"]?.arrayValue?.contains(.string("peers")) == true })
        store.disconnect()
        await store.connect()
        store.selectedTorrentIDs = [1]
        XCTAssertNil(store.selectedTorrentDetailState.detail)
        store.disconnect()
    }

    func testFailedFilesSubmissionRevokesFreshnessAndOldOwnerUntilAuthoritativeRefresh() async throws {
        let recorder = AppStoreRequestRecorder()
        let store = makeStore(recorder: recorder, failingMethods: ["torrent-set"])
        await store.connect()
        store.selectedTorrentDetailPane = .files
        store.selectedTorrentIDs = [1]
        let loaded = await waitForPollingCondition { store.selectedTorrentFileMutationOwner != nil }
        XCTAssertTrue(loaded)
        let oldOwner = try XCTUnwrap(store.selectedTorrentFileMutationOwner)
        await store.setTorrentFilesWanted(false, fileIndexes: [0], owner: oldOwner)
        XCTAssertNil(store.selectedTorrentFileMutationOwner)
        XCTAssertNotNil(store.selectedTorrentDetailState.detail)
        await store.refresh()
        XCTAssertNotNil(store.selectedTorrentFileMutationOwner)
        await store.setTorrentFilesWanted(false, fileIndexes: [0], owner: oldOwner)
        XCTAssertEqual(try recorder.requests.filter { try $0.decodedActionBody().method == "torrent-set" }.count, 1)
        store.disconnect()
    }

    func testLostVerifyResponseRequiresFreshPiecesAcrossReselectionThenRecovers() async throws {
        let recorder = AppStoreRequestRecorder()
        let store = makeStore(recorder: recorder, failingMethods: ["torrent-verify"], completed: true)
        await store.connect()
        store.selectedTorrentIDs = [1]
        XCTAssertNil(store.selectedTorrentDetailState.detail)
        XCTAssertEqual(
            TorrentPiecePresentation.state(summary: try XCTUnwrap(store.selectedTorrent), cachedInfo: nil),
            .complete(pieceCount: 8)
        )
        let loaded = await waitForPollingCondition { store.selectedTorrentDetailState.detail?.generalInfo != nil }
        XCTAssertTrue(loaded)
        let initialRequest = try XCTUnwrap(recorder.requests.map { try $0.decodedActionBody() }.first {
            $0.method == "torrent-get" && $0.arguments["ids"]?.arrayValue?.first?.stringValue != nil
        })
        let initialFields = initialRequest.arguments["fields"]?.arrayValue ?? []
        for field in ["pieces", "pieceCount", "pieceSize"] {
            XCTAssertFalse(initialFields.contains(.string(field)), "Completed summary already supplies \(field)")
        }
        store.requestVerifySelected()
        await store.confirmVerify()
        XCTAssertTrue(store.selectedTorrentRequiresPieceRevalidation)
        store.selectedTorrentIDs = [2]
        store.selectedTorrentIDs = [1]
        XCTAssertTrue(store.selectedTorrentRequiresPieceRevalidation)
        let recovered = await waitForPollingCondition { !store.selectedTorrentRequiresPieceRevalidation }
        XCTAssertTrue(recovered)
        let detailRequests = try recorder.requests.map { try $0.decodedActionBody() }.filter {
            $0.method == "torrent-get" && $0.arguments["ids"]?.arrayValue?.first?.stringValue != nil
        }
        XCTAssertTrue(detailRequests.last?.arguments["fields"]?.arrayValue?.contains(.string("pieces")) == true)
        store.disconnect()
    }

    func testFailedPropertiesTrackerEditRevokesCachedTrackerMutationOwner() async throws {
        let recorder = AppStoreRequestRecorder()
        let store = makeStore(recorder: recorder, failingMethods: ["torrent-set"])
        await store.connect()
        store.selectedTorrentDetailPane = .trackers
        store.selectedTorrentIDs = [1]
        let loaded = await waitForPollingCondition { store.selectedTorrentTrackerMutationOwner != nil }
        XCTAssertTrue(loaded)
        let oldOwner = try XCTUnwrap(store.selectedTorrentTrackerMutationOwner)
        await store.requestEditSelectedTorrentProperties()
        XCTAssertNotNil(store.torrentPropertiesEditor)
        store.torrentPropertiesEditor?.draft.trackerText = "https://new.example/announce"
        await store.applyTorrentProperties()
        XCTAssertNil(store.selectedTorrentTrackerMutationOwner)
        XCTAssertFalse(store.selectedTorrentRequiresPieceRevalidation)
        XCTAssertNotNil(store.selectedTorrentDetailState.detail)
        await store.refresh()
        XCTAssertNotNil(store.selectedTorrentTrackerMutationOwner)
        await store.addTorrentTracker("https://another.example/announce", owner: oldOwner)
        XCTAssertEqual(try recorder.requests.filter { try $0.decodedActionBody().method == "torrent-set" }.count, 1)
        store.disconnect()
    }

    func testRPC4FailedVerifyRecoversFromFreshTypedEvidenceWithoutUnavailableBitfield() async throws {
        let recorder = AppStoreRequestRecorder()
        let store = makeStore(recorder: recorder, failingMethods: ["torrent-verify"], rpcVersion: 4, completed: true)
        await store.connect()
        store.selectedTorrentIDs = [1]
        let loaded = await waitForPollingCondition { store.selectedTorrentDetailState.detail?.generalInfo != nil }
        XCTAssertTrue(loaded)
        store.requestVerifySelected()
        await store.confirmVerify()
        XCTAssertTrue(store.selectedTorrentRequiresPieceRevalidation)
        await store.refresh()
        XCTAssertFalse(store.selectedTorrentRequiresPieceRevalidation)
        let requests = try recorder.requests.map { try $0.decodedActionBody() }
        XCTAssertFalse(requests.contains { $0.arguments["fields"]?.arrayValue?.contains(.string("pieces")) == true })
        store.disconnect()
    }

    func testLostRemovalResponseEvictsAllCachedPanesAndRevokesMutationOwnership() async throws {
        let recorder = AppStoreRequestRecorder()
        let store = makeStore(recorder: recorder, failingMethods: ["torrent-remove"])
        await store.connect()
        store.selectedTorrentDetailPane = .files
        store.selectedTorrentIDs = [1]
        let filesLoaded = await waitForPollingCondition { store.selectedTorrentFileMutationOwner != nil }
        XCTAssertTrue(filesLoaded)
        let oldFilesOwner = try XCTUnwrap(store.selectedTorrentFileMutationOwner)
        store.selectedTorrentDetailPane = .trackers
        let trackersLoaded = await waitForPollingCondition { store.selectedTorrentTrackerMutationOwner != nil }
        XCTAssertTrue(trackersLoaded)
        store.requestRemoveSelected(deleteLocalData: true)
        let confirmation = try XCTUnwrap(store.removalConfirmation)
        await store.confirmRemoval(confirmation)
        XCTAssertNil(store.selectedTorrentTrackerMutationOwner)
        XCTAssertTrue(store.selectedTorrentRequiresPieceRevalidation)
        store.selectedTorrentDetailPane = .files
        XCTAssertNil(store.selectedTorrentFileMutationOwner)
        store.selectedTorrentIDs = [2]
        store.selectedTorrentIDs = [1]
        XCTAssertNil(store.selectedTorrentDetailState.detail)
        let recovered = await waitForPollingCondition { store.selectedTorrentFileMutationOwner != nil }
        XCTAssertTrue(recovered)
        await store.setTorrentFilesWanted(false, fileIndexes: [0], owner: oldFilesOwner)
        XCTAssertEqual(try recorder.requests.filter { try $0.decodedActionBody().method == "torrent-set" }.count, 0)
        store.disconnect()
    }

    func testClientUsesNumericSelectorBeforeRPC5AndCanonicalHashFromRPC5() async throws {
        for version in [4, 5] {
            let recorder = AppStoreRequestRecorder()
            AppStoreMockURLProtocol.requestHandler = { request in
                recorder.record(request)
                let action = try request.decodedActionBody()
                if action.method == "session-get" {
                    return rpcTestResponse(body: #"{"result":"success","arguments":{"rpc-version":\#(version)}}"#)
                }
                return rpcTestResponse(body: #"{"result":"success","arguments":{"torrents":[{"id":1,"hashString":"abcdefabcdefabcdefabcdefabcdefabcdefabcd","peers":[]}]}}"#)
            }
            let client = TransmissionRPCClient(profile: .localDefault, urlSession: makeAppStoreMockSession())
            _ = try await client.connect()
            _ = try await client.fetchTorrentDetail(id: 1, pane: .peers, hash: "ABCDEFABCDEFABCDEFABCDEFABCDEFABCDEFABCD")
            let last = try XCTUnwrap(recorder.requests.last).decodedActionBody()
            XCTAssertEqual(last.arguments["ids"], .array([version < 5 ? .int(1) : .string("abcdefabcdefabcdefabcdefabcdefabcdefabcd")]))
        }
    }

    func testFilesDemandDuringBlockedTrackerMutationResumesExactlyOnceAfterSuccessOrFailure() async throws {
        for fails in [false, true] {
            let recorder = AppStoreRequestRecorder()
            let store = makeStore(recorder: recorder, failingMethods: fails ? ["torrent-set"] : [])
            let originalHandler = try XCTUnwrap(AppStoreMockURLProtocol.requestHandler)
            let mutationStarted = expectation(description: "Tracker mutation started, fails=\(fails)")
            let releaseMutation = DispatchSemaphore(value: 0)
            AppStoreMockURLProtocol.requestHandler = { request in
                if try request.decodedActionBody().method == "torrent-set" {
                    mutationStarted.fulfill()
                    _ = releaseMutation.wait(timeout: .now() + 2)
                }
                return try originalHandler(request)
            }
            await store.connect()
            store.selectedTorrentDetailPane = .trackers
            store.selectedTorrentIDs = [1]
            let trackersLoaded = await waitForPollingCondition { store.selectedTorrentTrackerMutationOwner != nil }
            XCTAssertTrue(trackersLoaded)
            let owner = try XCTUnwrap(store.selectedTorrentTrackerMutationOwner)
            let mutation = Task { await store.addTorrentTracker("https://new.example/announce", owner: owner) }
            await fulfillment(of: [mutationStarted], timeout: 1)
            store.selectedTorrentDetailPane = .files
            XCTAssertNil(store.selectedTorrentDetailState.detail)
            releaseMutation.signal()
            await mutation.value
            let filesLoaded = await waitForPollingCondition { store.selectedTorrentFileMutationOwner != nil }
            XCTAssertTrue(filesLoaded, "Files demand must resume after the barrier, even when submission fails")
            let filesRequests = try recorder.requests.map { try $0.decodedActionBody() }.filter {
                $0.arguments["fields"]?.arrayValue?.contains(.string("files")) == true
            }
            XCTAssertEqual(filesRequests.count, 1)
            store.disconnect()
        }
    }

    func testPropertiesCompletionResumesSurvivingTargetDemandWhenAnotherTargetIsReplaced() async throws {
        for fails in [false, true] {
            let recorder = AppStoreRequestRecorder()
            let store = makeStore(recorder: recorder, failingMethods: fails ? ["torrent-set"] : [])
            let originalHandler = try XCTUnwrap(AppStoreMockURLProtocol.requestHandler)
            let mutationStarted = expectation(description: "Properties mutation started, fails=\(fails)")
            let releaseMutation = DispatchSemaphore(value: 0)
            defer { releaseMutation.signal() }
            AppStoreMockURLProtocol.requestHandler = { request in
                if try request.decodedActionBody().method == "torrent-set" {
                    mutationStarted.fulfill()
                    _ = releaseMutation.wait(timeout: .now() + 2)
                }
                return try originalHandler(request)
            }
            await store.connect()
            defer { store.disconnect() }
            store.selectedTorrentDetailPane = .trackers
            store.selectedTorrentIDs = [1]
            let trackersLoaded = await waitForPollingCondition { store.selectedTorrentTrackerMutationOwner != nil }
            XCTAssertTrue(trackersLoaded)
            store.selectedTorrentIDs = [1, 2]
            await store.requestEditSelectedTorrentProperties()
            XCTAssertEqual(store.torrentPropertiesEditor?.torrentIDs, [1, 2])
            store.torrentPropertiesEditor?.draft.peerLimit = 80
            let mutation = Task { await store.applyTorrentProperties() }
            await fulfillment(of: [mutationStarted], timeout: 1)
            let postSubmissionRequestStart = recorder.requests.count

            let replacementHash = String(repeating: "3", count: 40)
            var rows = store.torrents
            let replacementIndex = try XCTUnwrap(rows.firstIndex { $0.id == 2 })
            rows[replacementIndex].hashString = replacementHash
            store.torrents = rows
            store.selectedTorrentIDs = [1]
            store.selectedTorrentDetailPane = .files
            store.errorMessage = "Replacement notice"
            XCTAssertNil(store.selectedTorrentDetailState.detail)
            releaseMutation.signal()
            await mutation.value

            let filesLoaded = await waitForPollingCondition { store.selectedTorrentFileMutationOwner != nil }
            XCTAssertTrue(filesLoaded, "The surviving selected torrent must resume its blocked Files demand")
            XCTAssertNil(store.torrentPropertiesEditor)
            XCTAssertEqual(store.errorMessage, "Replacement notice")
            XCTAssertEqual(store.torrents.first { $0.id == 2 }?.hashString, replacementHash)
            let laterActions = try recorder.requests.dropFirst(postSubmissionRequestStart).map {
                try $0.decodedActionBody()
            }
            let filesRequests = laterActions.filter {
                $0.method == "torrent-get" && $0.arguments["fields"]?.arrayValue?.contains(.string("files")) == true
            }
            XCTAssertEqual(filesRequests.count, 1)
            XCTAssertEqual(filesRequests.first?.arguments["ids"], .array([.string(String(repeating: "1", count: 40))]))
            XCTAssertFalse(laterActions.contains {
                $0.method == "torrent-get" && $0.arguments["ids"]?.arrayValue?.contains(.int(2)) == true
            })
        }
    }

    private func makeStore(
        recorder: AppStoreRequestRecorder,
        failingMethods: Set<String> = [],
        rpcVersion: Int = 18,
        completed: Bool = false
    ) -> AppStore {
        AppStoreMockURLProtocol.requestHandler = { request in
            recorder.record(request)
            let action = try request.decodedActionBody()
            if failingMethods.contains(action.method) { throw URLError(.networkConnectionLost) }
            if action.method == "session-get" {
                return rpcTestResponse(body: #"{"result":"success","arguments":{"rpc-version":\#(rpcVersion),"version":"4.0","download-dir":"/downloads"}}"#)
            }
            guard action.method == "torrent-get" else { return appStoreRPCResponse(for: action.method) }
            let fields = Set(action.arguments["fields"]?.arrayValue?.compactMap(\.stringValue) ?? [])
            let selector = action.arguments["ids"]?.arrayValue?.first
            let id = selector?.intValue ?? [1, 2].first {
                String(repeating: String($0), count: 40) == selector?.stringValue
            }
            let ids = !fields.contains("name") ? id.map { [$0] } ?? [] : [1, 2]
            let torrents = ids.map { id in
                JSONValue.object(instantDetailFixture(id: id, completed: completed, rpcVersion: rpcVersion)
                    .filter { fields.contains($0.key) })
            }
            let response = JSONValue.object(["result": .string("success"), "arguments": .object(["torrents": .array(torrents)])])
            return rpcTestResponse(body: String(decoding: try JSONEncoder().encode(response), as: UTF8.self))
        }
        let profileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("profiles.json")
        let session = makeAppStoreMockSession()
        return AppStore(
            profileStore: makePersistedConnectionProfileStore(fileURL: profileURL, passwordStore: InstantDetailPasswordStore()),
            userDefaults: UserDefaults(suiteName: UUID().uuidString)!,
            downloadCompletionNotifier: InstantDetailNotifier(),
            pollingCoordinator: PollingCoordinator(clock: TestPollingClock()),
            selectionDebounceDuration: .zero,
            clientFactory: { TransmissionRPCClient(profile: $0, urlSession: session) }
        )
    }
}

private func instantDetailFixture(id: Int, completed: Bool, rpcVersion: Int) -> RPCArguments {
    [
        "id": .int(id), "hashString": .string(String(repeating: String(id), count: 40)),
        "name": .string("Torrent \(id)"), "comment": .string("overview"),
        "status": .int(completed ? (rpcVersion < 14 ? 8 : 6) : (rpcVersion < 14 ? 16 : 0)),
        "error": .int(0), "errorString": .string(""), "metadataPercentComplete": .int(1),
        "totalSize": .int(100), "sizeWhenDone": .int(100), "leftUntilDone": .int(completed ? 0 : 50),
        "haveValid": .int(completed ? 100 : 50), "haveUnchecked": .int(0),
        "pieceCount": .int(8), "pieceSize": .int(13), "pieces": .string(completed ? "/w==" : "8A=="),
        "files": .array([.object(["name": .string("file.bin"), "length": .int(100), "bytesCompleted": .int(50)])]),
        "fileStats": .array([.object(["wanted": .bool(true), "priority": .int(0)])]),
        "trackerStats": .array([.object(["id": .int(1), "host": .string("tracker.example"), "hasAnnounced": .bool(true), "lastAnnounceSucceeded": .bool(true)])]),
    ]
}

private struct InstantDetailPasswordStore: ConnectionPasswordStoring {
    func password(for profileID: ConnectionProfile.ID) throws -> String? { nil }
    func setPassword(_ password: String, for profileID: ConnectionProfile.ID) throws {}
    func removePassword(for profileID: ConnectionProfile.ID) throws {}
}

private struct InstantDetailNotifier: DownloadCompletionNotifying {
    func notifyDownloadCompleted(torrentName: String) {}
}
