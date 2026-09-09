// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation
import XCTest
@testable import TransmissionRemoteMac

@MainActor
final class AppStorePendingAddTorrentQueueTests: XCTestCase {
    override func tearDown() {
        AppStoreMockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testBatchPreservesOrderAndSuppressesExactDuplicatesWhilePending() async {
        let store = await makeConnectedStore()
        let ownerID = registerOwner(in: store)
        let magnet = "magnet:?xt=urn:btih:first"
        let torrentFile = URL(fileURLWithPath: "/tmp/second.torrent")

        store.requestAddTorrents([
            .remote(magnet),
            .remote(magnet),
            .localFile(torrentFile),
            .localFile(torrentFile)
        ])

        let firstRequest = assertPresented(store, ownerID: ownerID, source: .remote(magnet))
        cancelAndDismiss(firstRequest, ownerID: ownerID, in: store)
        let secondRequest = assertPresented(store, ownerID: ownerID, source: .localFile(torrentFile))
        cancelAndDismiss(secondRequest, ownerID: ownerID, in: store)
        XCTAssertNil(store.pendingAddTorrent)

        store.requestAddTorrent(source: magnet)

        _ = assertPresented(store, ownerID: ownerID, source: .remote(magnet))
    }

    func testPendingRequestPreservesExplicitInitialAddChoices() async throws {
        let store = await makeConnectedStore()
        let ownerID = registerOwner(in: store)
        let initialOptions = AddTorrentInitialOptions(
            startIntent: .paused,
            priority: .high,
            unwantedFiles: .allUnwantedWhenFileListKnown,
            peerLimit: .daemonDefault
        )

        store.requestAddTorrent(
            source: "magnet:?xt=urn:btih:explicit",
            initialOptions: initialOptions
        )

        XCTAssertEqual(
            try XCTUnwrap(store.presentedAddTorrent(for: ownerID)).initialOptions,
            initialOptions
        )
    }

    func testStaleDismissalCannotAdvanceOrClearNewerRequest() async {
        let store = await makeConnectedStore()
        let ownerID = registerOwner(in: store)
        store.requestAddTorrents([
            .remote("magnet:?xt=urn:btih:first"),
            .remote("magnet:?xt=urn:btih:second")
        ])
        let firstRequest = try! XCTUnwrap(store.pendingAddTorrent)

        cancelAndDismiss(firstRequest, ownerID: ownerID, in: store)
        let secondRequest = try! XCTUnwrap(store.pendingAddTorrent)

        store.addTorrentPresentationWillDismiss(requestID: firstRequest.id, ownerID: ownerID)
        store.addTorrentSheetDidDismiss(requestID: firstRequest.id, ownerID: ownerID)

        XCTAssertEqual(store.pendingAddTorrent?.id, secondRequest.id)
        XCTAssertTrue(store.showingAddTorrent)
    }

    func testDuplicateWindowCallbacksCannotClaimOrDismissOwnersRequest() async {
        let store = await makeConnectedStore()
        let ownerID = registerOwner(in: store)
        let duplicateWindowOwnerID = registerOwner(in: store)
        store.requestAddTorrent(source: "magnet:?xt=urn:btih:owned")
        let request = try! XCTUnwrap(store.pendingAddTorrent)

        XCTAssertEqual(store.presentedAddTorrent(for: ownerID)?.id, request.id)
        XCTAssertNil(store.presentedAddTorrent(for: duplicateWindowOwnerID))

        store.addTorrentPresentationWillDismiss(
            requestID: request.id,
            ownerID: duplicateWindowOwnerID
        )
        store.addTorrentSheetDidDismiss(
            requestID: request.id,
            ownerID: duplicateWindowOwnerID
        )

        XCTAssertEqual(store.pendingAddTorrent?.id, request.id)
        XCTAssertTrue(store.showingAddTorrent)
    }

    func testCancelAdvancesExactlyOnce() async {
        let store = await makeConnectedStore()
        let ownerID = registerOwner(in: store)
        store.requestAddTorrents([
            .remote("magnet:?xt=urn:btih:first"),
            .remote("magnet:?xt=urn:btih:second")
        ])
        let firstRequest = try! XCTUnwrap(store.pendingAddTorrent)

        XCTAssertTrue(store.cancelPendingAddTorrent(requestID: firstRequest.id, ownerID: ownerID))
        XCTAssertFalse(store.cancelPendingAddTorrent(requestID: firstRequest.id, ownerID: ownerID))
        dismiss(firstRequest, ownerID: ownerID, in: store)
        let secondRequest = try! XCTUnwrap(store.pendingAddTorrent)

        store.addTorrentSheetDidDismiss(requestID: firstRequest.id, ownerID: ownerID)

        XCTAssertEqual(store.pendingAddTorrent?.id, secondRequest.id)
        XCTAssertEqual(
            store.pendingAddTorrent?.source,
            .remote("magnet:?xt=urn:btih:second")
        )
    }

    func testDisconnectedSubmissionWaitsWithoutPresentingOrSurfacingError() {
        let store = makeStore()
        let ownerID = registerOwner(in: store)
        store.requestAddTorrent(source: "magnet:?xt=urn:btih:offline")

        XCTAssertNil(store.pendingAddTorrent)
        XCTAssertNil(store.presentedAddTorrent(for: ownerID))
        XCTAssertFalse(store.showingAddTorrent)
        XCTAssertFalse(store.isAddingTorrent)
        XCTAssertNil(store.errorMessage)
    }

    func testProfileChangeInvalidatesBoundRequestInsteadOfRetargetingIt() async throws {
        let store = await makeConnectedStore()
        let ownerID = registerOwner(in: store)
        store.requestAddTorrent(source: "magnet:?xt=urn:btih:bound")
        XCTAssertNotNil(store.presentedAddTorrent(for: ownerID))
        let otherProfile = try ConnectionProfile.validated(
            id: UUID(),
            name: "Other",
            host: "other.example"
        )

        let result = store.applyConnectionProfiles(
            [store.selectedProfile, otherProfile],
            selectedProfileID: otherProfile.id
        )
        guard case .success = result else {
            return XCTFail("Expected the profile switch to be accepted")
        }
        XCTAssertEqual(store.selectedProfileID, otherProfile.id)
        XCTAssertNil(store.pendingAddTorrent)
        XCTAssertNil(store.presentedAddTorrent(for: ownerID))
        XCTAssertFalse(store.showingAddTorrent)
        XCTAssertNil(store.errorMessage)
        store.disconnect()
    }

    func testSuccessAdvancesExactlyOnceAfterRPCAndMatchingDismissal() async throws {
        let store = await makeConnectedStore()
        let ownerID = registerOwner(in: store)
        store.requestAddTorrents([
            .remote("magnet:?xt=urn:btih:first"),
            .remote("magnet:?xt=urn:btih:second")
        ])
        let firstRequest = try XCTUnwrap(store.pendingAddTorrent)

        let result = await store.addTorrent(
            requestID: firstRequest.id,
            presentationOwnerID: ownerID,
            source: "magnet:?xt=urn:btih:first",
            startPaused: false,
            downloadDirectory: nil
        )

        XCTAssertEqual(result, .succeeded)
        XCTAssertEqual(store.pendingAddTorrent?.id, firstRequest.id)
        dismiss(firstRequest, ownerID: ownerID, in: store)
        let secondRequest = try XCTUnwrap(store.pendingAddTorrent)
        store.addTorrentSheetDidDismiss(requestID: firstRequest.id, ownerID: ownerID)

        XCTAssertEqual(store.pendingAddTorrent?.id, secondRequest.id)
        XCTAssertEqual(
            store.pendingAddTorrent?.source,
            .remote("magnet:?xt=urn:btih:second")
        )
        cancelAndDismiss(secondRequest, ownerID: ownerID, in: store)
        store.disconnect()
    }

    func testConfirmedManualAddKeepsAReplacementCreatedAfterDescriptorRead() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sourceURL = directoryURL.appendingPathComponent("release.torrent")
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let fileCleanup = DarwinRaceResistantFileCleanup()
        try Data("original".utf8).write(to: sourceURL)
        let snapshot = try fileCleanup.readRegularFile(at: sourceURL)
        AppStoreMockURLProtocol.requestHandler = { request in
            let action = try request.decodedActionBody()
            if action.method == "torrent-add" {
                try FileManager.default.removeItem(at: sourceURL)
                try Data("replacement".utf8).write(to: sourceURL)
                return rpcTestResponse(
                    body: #"{"result":"success","arguments":{"torrent-added":{"id":42,"hashString":"0123456789abcdef0123456789abcdef01234567","name":"Release"}}}"#
                )
            }
            return appStoreRPCResponse(for: action.method)
        }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let intakePreferences = IntakeAutomationPreferencesStore(userDefaults: defaults)
        try intakePreferences.save(IntakeAutomationPreferences(
            clipboardIntake: .defaults,
            sourceTorrentDeletion: .afterSuccessfulNonDuplicateAdd,
            updateChecks: .defaults
        ))
        let store = makeStore(
            urlSession: makeAppStoreMockSession(),
            persistedProfile: true,
            intakeAutomationPreferencesStore: intakePreferences
        )
        await store.connect()
        let ownerID = registerOwner(in: store)
        store.requestAddTorrent(fileURL: sourceURL)
        let request = try XCTUnwrap(store.presentedAddTorrent(for: ownerID))

        let result = await store.addTorrentFile(
            requestID: request.id,
            presentationOwnerID: ownerID,
            data: snapshot.data,
            sourceFileURL: sourceURL,
            sourceFileIdentity: snapshot.identity,
            startPaused: false,
            downloadDirectory: nil
        )

        XCTAssertEqual(result, .succeeded)
        XCTAssertEqual(try Data(contentsOf: sourceURL), Data("replacement".utf8))
        XCTAssertTrue(store.errorMessage?.contains("source .torrent could not be deleted") == true)
        dismiss(request, ownerID: ownerID, in: store)
        store.disconnect()
    }

    func testDisconnectIsBlockedWhileAddMutationIsInFlight() async throws {
        let addStarted = expectation(description: "torrent add started")
        let releaseAdd = DispatchSemaphore(value: 0)
        AppStoreMockURLProtocol.requestHandler = { request in
            let action = try request.decodedActionBody()
            if action.method == "torrent-add" {
                addStarted.fulfill()
                _ = releaseAdd.wait(timeout: .now() + 2)
                return rpcTestResponse(
                    body: #"{"result":"success","arguments":{"torrent-added":{"id":42,"hashString":"0123456789abcdef0123456789abcdef01234567","name":"Pending metadata"}}}"#
                )
            }
            return appStoreRPCResponse(for: action.method)
        }
        let store = makeStore(urlSession: makeAppStoreMockSession(), persistedProfile: true)
        await store.connect()
        let ownerID = registerOwner(in: store)
        store.requestAddTorrent(source: "magnet:?xt=urn:btih:inflight")
        let request = try XCTUnwrap(store.pendingAddTorrent)

        let addTask = Task {
            await store.addTorrent(
                requestID: request.id,
                presentationOwnerID: ownerID,
                source: "magnet:?xt=urn:btih:inflight",
                startPaused: false,
                downloadDirectory: nil
            )
        }
        await fulfillment(of: [addStarted], timeout: 1)

        store.disconnect()

        XCTAssertTrue(store.connectionState.isConnected)
        XCTAssertTrue(store.isAddingTorrent)
        XCTAssertTrue(store.errorMessage?.contains("Wait for the torrent add request") == true)
        releaseAdd.signal()
        let result = await addTask.value
        XCTAssertEqual(result, .succeeded)
        dismiss(request, ownerID: ownerID, in: store)
        store.disconnect()
    }

    func testFailedMutationReassignsRequestWhenPresentationOwnerDisappears() async throws {
        let addStarted = expectation(description: "torrent add started")
        let releaseAdd = DispatchSemaphore(value: 0)
        AppStoreMockURLProtocol.requestHandler = { request in
            let action = try request.decodedActionBody()
            if action.method == "torrent-add" {
                addStarted.fulfill()
                _ = releaseAdd.wait(timeout: .now() + 2)
                return rpcTestResponse(
                    body: #"{"result":"add failed","arguments":{}}"#
                )
            }
            return appStoreRPCResponse(for: action.method)
        }
        let store = makeStore(urlSession: makeAppStoreMockSession(), persistedProfile: true)
        await store.connect()
        let firstOwnerID = registerOwner(in: store)
        let secondOwnerID = registerOwner(in: store)
        store.requestAddTorrent(source: "magnet:?xt=urn:btih:retry-owner")
        let request = try XCTUnwrap(store.pendingAddTorrent)

        let addTask = Task {
            await store.addTorrent(
                requestID: request.id,
                presentationOwnerID: firstOwnerID,
                source: "magnet:?xt=urn:btih:retry-owner",
                startPaused: false,
                downloadDirectory: nil
            )
        }
        await fulfillment(of: [addStarted], timeout: 1)

        store.unregisterAddTorrentPresentationOwner(firstOwnerID)
        releaseAdd.signal()
        let result = await addTask.value

        guard case .failed = result else {
            return XCTFail("expected the failed RPC mutation to remain available for retry")
        }
        XCTAssertFalse(store.isAddingTorrent)
        XCTAssertEqual(store.presentedAddTorrent(for: secondOwnerID)?.id, request.id)
        XCTAssertEqual(store.pendingAddTorrent?.presentationOwnerID, secondOwnerID)

        cancelAndDismiss(request, ownerID: secondOwnerID, in: store)
        store.disconnect()
    }

    func testMagnetSaveAsPollsOnlyAddedTorrentThenRenamesAndRefreshesTarget() async throws {
        let recorder = AppStoreRequestRecorder()
        let metadataRequestCount = LockedAddMetadataCounter()
        let hash = "0123456789abcdef0123456789abcdef01234567"
        AppStoreMockURLProtocol.requestHandler = { request in
            recorder.record(request)
            let action = try request.decodedActionBody()
            if action.method == "torrent-add" {
                return rpcTestResponse(
                    body: #"{"result":"success","arguments":{"torrent-added":{"id":42,"hashString":"0123456789abcdef0123456789abcdef01234567","name":"Magnetized transfer"}}}"#
                )
            }
            if action.method == "torrent-get",
               action.arguments["ids"] == .array([.string(hash)]) {
                let attempt = metadataRequestCount.increment()
                let percent = attempt == 1 ? "0.5" : "1"
                return rpcTestResponse(
                    body: "{\"result\":\"success\",\"arguments\":{\"torrents\":[{\"id\":42,\"hashString\":\"0123456789abcdef0123456789abcdef01234567\",\"metadataPercentComplete\":\(percent),\"name\":\"Ubuntu\"}]}}"
                )
            }
            return appStoreRPCResponse(for: action.method)
        }
        let store = makeStore(
            urlSession: makeAppStoreMockSession(),
            persistedProfile: true,
            provisionalMetadataSleeper: ImmediateAddMetadataSleeper(),
            provisionalMetadataPollingPolicy: .init(interval: .zero, maximumAttempts: 3)
        )
        await store.connect()
        let ownerID = registerOwner(in: store)
        store.requestAddTorrent(source: "magnet:?xt=urn:btih:\(hash)")
        let request = try XCTUnwrap(store.pendingAddTorrent)

        let addResult = await store.addTorrent(
            requestID: request.id,
            presentationOwnerID: ownerID,
            source: "magnet:?xt=urn:btih:\(hash)",
            startPaused: false,
            downloadDirectory: nil,
            peerLimit: 37,
            saveAsRequested: true
        )

        XCTAssertEqual(addResult, .awaitingSaveAs)
        let metadataReady = await waitUntil {
            if case .ready = store.provisionalTorrentAddState { return true }
            return false
        }
        XCTAssertTrue(metadataReady)

        let renameResult = await store.renameProvisionalTorrent(
            requestID: request.id,
            presentationOwnerID: ownerID,
            newName: "Ubuntu 24.04"
        )

        XCTAssertEqual(renameResult, .succeeded)
        let actions = try recorder.requests.map { try $0.decodedActionBody() }
        XCTAssertEqual(actions.filter { $0.method == "torrent-add" }.count, 1)
        XCTAssertEqual(
            actions.filter {
                $0.method == "torrent-get"
                    && $0.arguments["ids"] == .array([.string(hash)])
            }.count,
            2
        )
        XCTAssertEqual(actions.filter { $0.method == "torrent-rename-path" }.count, 1)
        XCTAssertEqual(
            actions.filter {
                $0.method == "torrent-get"
                    && $0.arguments["ids"] == .array([.int(42)])
            }.count,
            2
        )
        let addAction = try XCTUnwrap(actions.first { $0.method == "torrent-add" })
        XCTAssertEqual(addAction.arguments["peer-limit"], .int(37))
        let renameAction = try XCTUnwrap(actions.first { $0.method == "torrent-rename-path" })
        XCTAssertEqual(renameAction.arguments["ids"], .array([.string(hash)]))
        XCTAssertEqual(renameAction.arguments["path"], .string("Ubuntu"))
        XCTAssertEqual(renameAction.arguments["name"], .string("Ubuntu 24.04"))

        dismiss(request, ownerID: ownerID, in: store)
        store.disconnect()
    }

    func testBlankSaveAsCompletesMagnetAddWithZeroMetadataRequests() async throws {
        let recorder = AppStoreRequestRecorder()
        let hash = "0123456789abcdef0123456789abcdef01234567"
        AppStoreMockURLProtocol.requestHandler = { request in
            recorder.record(request)
            let action = try request.decodedActionBody()
            if action.method == "torrent-add" {
                return rpcTestResponse(
                    body: #"{"result":"success","arguments":{"torrent-added":{"id":42,"hashString":"0123456789abcdef0123456789abcdef01234567","name":"Pending metadata"}}}"#
                )
            }
            return appStoreRPCResponse(for: action.method)
        }
        let store = makeStore(
            urlSession: makeAppStoreMockSession(),
            persistedProfile: true,
            provisionalMetadataSleeper: ImmediateAddMetadataSleeper()
        )
        await store.connect()
        let ownerID = registerOwner(in: store)
        store.requestAddTorrent(source: "magnet:?xt=urn:btih:\(hash)")
        let request = try XCTUnwrap(store.pendingAddTorrent)

        let result = await store.addTorrent(
            requestID: request.id,
            presentationOwnerID: ownerID,
            source: "magnet:?xt=urn:btih:\(hash)",
            startPaused: false,
            downloadDirectory: nil,
            saveAsRequested: false
        )

        XCTAssertEqual(result, .succeeded)
        XCTAssertEqual(store.provisionalTorrentAddState, .idle)
        let actions = try recorder.requests.map { try $0.decodedActionBody() }
        XCTAssertEqual(actions.filter { $0.method == "torrent-add" }.count, 1)
        XCTAssertFalse(actions.contains {
            $0.method == "torrent-get"
                && $0.arguments["ids"] == .array([.string(hash)])
        })

        dismiss(request, ownerID: ownerID, in: store)
        store.disconnect()
    }

    func testRequestedSaveAsWithInvalidReturnedHashNeverPollsOrRenames() async throws {
        let recorder = AppStoreRequestRecorder()
        AppStoreMockURLProtocol.requestHandler = { request in
            recorder.record(request)
            let action = try request.decodedActionBody()
            if action.method == "torrent-add" {
                return rpcTestResponse(
                    body: #"{"result":"success","arguments":{"torrent-added":{"id":42,"hashString":"not-a-full-hash","name":"Pending metadata"}}}"#
                )
            }
            return appStoreRPCResponse(for: action.method)
        }
        let store = makeStore(
            urlSession: makeAppStoreMockSession(),
            persistedProfile: true,
            provisionalMetadataSleeper: ImmediateAddMetadataSleeper()
        )
        await store.connect()
        let ownerID = registerOwner(in: store)
        store.requestAddTorrent(source: "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567")
        let request = try XCTUnwrap(store.pendingAddTorrent)

        let result = await store.addTorrent(
            requestID: request.id,
            presentationOwnerID: ownerID,
            source: "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567",
            startPaused: false,
            downloadDirectory: nil,
            saveAsRequested: true
        )

        XCTAssertEqual(result, .awaitingSaveAs)
        guard case .unavailable = store.provisionalTorrentAddState else {
            return XCTFail("invalid returned hash should leave a visible non-mutating state")
        }
        let actions = try recorder.requests.map { try $0.decodedActionBody() }
        XCTAssertFalse(actions.contains { action in
            action.method == "torrent-rename-path"
                || (action.method == "torrent-get"
                    && action.arguments["ids"]?.arrayValue?.contains(.string("not-a-full-hash")) == true)
        })

        XCTAssertEqual(
            store.finishProvisionalTorrentAdd(
                requestID: request.id,
                presentationOwnerID: ownerID
            ),
            .succeeded
        )
        dismiss(request, ownerID: ownerID, in: store)
        store.disconnect()
    }

    func testRequestedLocalSaveAsBecomesReadyWithoutMetadataPolling() async throws {
        let recorder = AppStoreRequestRecorder()
        let hash = "0123456789abcdef0123456789abcdef01234567"
        AppStoreMockURLProtocol.requestHandler = { request in
            recorder.record(request)
            let action = try request.decodedActionBody()
            if action.method == "torrent-add" {
                return rpcTestResponse(
                    body: #"{"result":"success","arguments":{"torrent-added":{"id":42,"hashString":"0123456789ABCDEF0123456789ABCDEF01234567","name":"Ubuntu"}}}"#
                )
            }
            return appStoreRPCResponse(for: action.method)
        }
        let store = makeStore(urlSession: makeAppStoreMockSession(), persistedProfile: true)
        await store.connect()
        let ownerID = registerOwner(in: store)
        store.requestAddTorrent()
        let request = try XCTUnwrap(store.pendingAddTorrent)

        let result = await store.addTorrentFile(
            requestID: request.id,
            presentationOwnerID: ownerID,
            data: Data([1, 2, 3]),
            startPaused: false,
            downloadDirectory: nil,
            originalRootName: "Ubuntu",
            saveAsRequested: true
        )

        XCTAssertEqual(result, .awaitingSaveAs)
        guard case .ready(let provisionalOwner, let originalRootName) = store.provisionalTorrentAddState else {
            return XCTFail("local metainfo should make Save As ready without polling")
        }
        XCTAssertEqual(provisionalOwner.torrentHash, hash)
        XCTAssertEqual(originalRootName, "Ubuntu")
        let actions = try recorder.requests.map { try $0.decodedActionBody() }
        XCTAssertFalse(actions.contains {
            $0.method == "torrent-get"
                && $0.arguments["ids"] == .array([.string(hash)])
        })
        XCTAssertFalse(actions.contains { $0.method == "torrent-rename-path" })

        XCTAssertEqual(
            store.finishProvisionalTorrentAdd(
                requestID: request.id,
                presentationOwnerID: ownerID
            ),
            .succeeded
        )
        dismiss(request, ownerID: ownerID, in: store)
        store.disconnect()
    }

    func testURLAndDaemonPathSaveAsUseAddedNameWithoutMetadataPolling() async throws {
        let hash = "0123456789abcdef0123456789abcdef01234567"
        let sources = [
            "https://downloads.example/ubuntu.torrent",
            "/srv/watch/ubuntu.torrent"
        ]

        for source in sources {
            let recorder = AppStoreRequestRecorder()
            AppStoreMockURLProtocol.requestHandler = { request in
                recorder.record(request)
                let action = try request.decodedActionBody()
                if action.method == "torrent-add" {
                    return rpcTestResponse(
                        body: #"{"result":"success","arguments":{"torrent-added":{"id":42,"hashString":"0123456789abcdef0123456789abcdef01234567","name":"Ubuntu"}}}"#
                    )
                }
                return appStoreRPCResponse(for: action.method)
            }
            let store = makeStore(urlSession: makeAppStoreMockSession(), persistedProfile: true)
            await store.connect()
            let ownerID = registerOwner(in: store)
            store.requestAddTorrent(source: source)
            let request = try XCTUnwrap(store.pendingAddTorrent)

            let addResult = await store.addTorrent(
                requestID: request.id,
                presentationOwnerID: ownerID,
                source: source,
                startPaused: false,
                downloadDirectory: nil,
                saveAsRequested: true
            )

            XCTAssertEqual(addResult, .awaitingSaveAs, source)
            guard case .ready(let owner, let originalRootName) = store.provisionalTorrentAddState else {
                XCTFail("non-magnet Save As should be ready immediately: \(source)")
                store.disconnect()
                continue
            }
            XCTAssertEqual(owner.torrentHash, hash, source)
            XCTAssertEqual(originalRootName, "Ubuntu", source)

            let renameResult = await store.renameProvisionalTorrent(
                requestID: request.id,
                presentationOwnerID: ownerID,
                newName: "Ubuntu 24.04"
            )
            XCTAssertEqual(renameResult, .succeeded, source)

            let actions = try recorder.requests.map { try $0.decodedActionBody() }
            XCTAssertEqual(actions.filter { $0.method == "torrent-add" }.count, 1, source)
            XCTAssertFalse(actions.contains {
                $0.method == "torrent-get"
                    && $0.arguments["ids"] == .array([.string(hash)])
            }, source)
            XCTAssertEqual(actions.filter { $0.method == "torrent-rename-path" }.count, 1, source)
            let renameAction = try XCTUnwrap(actions.first { $0.method == "torrent-rename-path" })
            XCTAssertEqual(renameAction.arguments["ids"], .array([.string(hash)]), source)
            XCTAssertEqual(renameAction.arguments["path"], .string("Ubuntu"), source)
            XCTAssertEqual(renameAction.arguments["name"], .string("Ubuntu 24.04"), source)

            dismiss(request, ownerID: ownerID, in: store)
            store.disconnect()
        }
    }

    func testNonMagnetSaveAsWithoutAddedNameStaysUnavailableAndNonMutating() async throws {
        let recorder = AppStoreRequestRecorder()
        let hash = "0123456789abcdef0123456789abcdef01234567"
        let source = "https://downloads.example/unnamed.torrent"
        AppStoreMockURLProtocol.requestHandler = { request in
            recorder.record(request)
            let action = try request.decodedActionBody()
            if action.method == "torrent-add" {
                return rpcTestResponse(
                    body: #"{"result":"success","arguments":{"torrent-added":{"id":42,"hashString":"0123456789abcdef0123456789abcdef01234567"}}}"#
                )
            }
            return appStoreRPCResponse(for: action.method)
        }
        let store = makeStore(urlSession: makeAppStoreMockSession(), persistedProfile: true)
        await store.connect()
        let ownerID = registerOwner(in: store)
        store.requestAddTorrent(source: source)
        let request = try XCTUnwrap(store.pendingAddTorrent)

        let result = await store.addTorrent(
            requestID: request.id,
            presentationOwnerID: ownerID,
            source: source,
            startPaused: false,
            downloadDirectory: nil,
            saveAsRequested: true
        )

        XCTAssertEqual(result, .awaitingSaveAs)
        guard case .unavailable = store.provisionalTorrentAddState else {
            return XCTFail("missing authoritative added name should remain visibly unavailable")
        }
        let actions = try recorder.requests.map { try $0.decodedActionBody() }
        XCTAssertFalse(actions.contains {
            $0.method == "torrent-rename-path"
                || $0.method == "torrent-remove"
                || ($0.method == "torrent-get"
                    && $0.arguments["ids"] == .array([.string(hash)]))
        })

        XCTAssertEqual(
            store.finishProvisionalTorrentAdd(
                requestID: request.id,
                presentationOwnerID: ownerID
            ),
            .succeeded
        )
        dismiss(request, ownerID: ownerID, in: store)
        store.disconnect()
    }

    func testDuplicateMagnetNeverStartsMetadataPollingOrRename() async throws {
        let recorder = AppStoreRequestRecorder()
        AppStoreMockURLProtocol.requestHandler = { request in
            recorder.record(request)
            let action = try request.decodedActionBody()
            if action.method == "torrent-add" {
                return rpcTestResponse(
                    body: #"{"result":"success","arguments":{"torrent-duplicate":{"id":42,"hashString":"0123456789abcdef0123456789abcdef01234567","name":"Existing"}}}"#
                )
            }
            return appStoreRPCResponse(for: action.method)
        }
        let store = makeStore(urlSession: makeAppStoreMockSession(), persistedProfile: true)
        await store.connect()
        let ownerID = registerOwner(in: store)
        store.requestAddTorrent(source: "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567")
        let request = try XCTUnwrap(store.pendingAddTorrent)

        let result = await store.addTorrent(
            requestID: request.id,
            presentationOwnerID: ownerID,
            source: "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567",
            startPaused: false,
            downloadDirectory: nil
        )

        XCTAssertEqual(result, .awaitingSaveAs)
        XCTAssertEqual(store.provisionalTorrentAddState, .duplicate(name: "Existing"))
        let actions = try recorder.requests.map { try $0.decodedActionBody() }
        XCTAssertFalse(actions.contains { action in
            action.method == "torrent-rename-path"
                || (action.method == "torrent-get"
                    && action.arguments["ids"] == .array([.string("0123456789abcdef0123456789abcdef01234567")]))
        })
        XCTAssertEqual(
            store.finishProvisionalTorrentAdd(
                requestID: request.id,
                presentationOwnerID: ownerID
            ),
            .succeeded
        )
        dismiss(request, ownerID: ownerID, in: store)
        store.disconnect()
    }

    func testMagnetMetadataTimeoutIsBoundedAndNeverRemovesTorrent() async throws {
        let recorder = AppStoreRequestRecorder()
        let hash = "0123456789abcdef0123456789abcdef01234567"
        AppStoreMockURLProtocol.requestHandler = { request in
            recorder.record(request)
            let action = try request.decodedActionBody()
            if action.method == "torrent-add" {
                return rpcTestResponse(
                    body: #"{"result":"success","arguments":{"torrent-added":{"id":42,"hashString":"0123456789abcdef0123456789abcdef01234567","name":"Pending metadata"}}}"#
                )
            }
            if action.method == "torrent-get",
               action.arguments["ids"] == .array([.string(hash)]) {
                return rpcTestResponse(
                    body: #"{"result":"success","arguments":{"torrents":[{"id":42,"hashString":"0123456789abcdef0123456789abcdef01234567","metadataPercentComplete":0.5,"name":"Pending metadata"}]}}"#
                )
            }
            return appStoreRPCResponse(for: action.method)
        }
        let store = makeStore(
            urlSession: makeAppStoreMockSession(),
            persistedProfile: true,
            provisionalMetadataSleeper: ImmediateAddMetadataSleeper(),
            provisionalMetadataPollingPolicy: .init(interval: .zero, maximumAttempts: 2)
        )
        await store.connect()
        let ownerID = registerOwner(in: store)
        store.requestAddTorrent(source: "magnet:?xt=urn:btih:\(hash)")
        let request = try XCTUnwrap(store.pendingAddTorrent)

        let addResult = await store.addTorrent(
            requestID: request.id,
            presentationOwnerID: ownerID,
            source: "magnet:?xt=urn:btih:\(hash)",
            startPaused: false,
            downloadDirectory: nil,
            saveAsRequested: true
        )
        XCTAssertEqual(addResult, .awaitingSaveAs)
        let timedOut = await waitUntil {
            if case .timedOut = store.provisionalTorrentAddState { return true }
            return false
        }
        XCTAssertTrue(timedOut)

        let actions = try recorder.requests.map { try $0.decodedActionBody() }
        XCTAssertEqual(
            actions.filter {
                $0.method == "torrent-get"
                    && $0.arguments["ids"] == .array([.string(hash)])
            }.count,
            2
        )
        XCTAssertFalse(actions.contains { $0.method == "torrent-remove" || $0.method == "torrent-rename-path" })

        XCTAssertEqual(
            store.finishProvisionalTorrentAdd(
                requestID: request.id,
                presentationOwnerID: ownerID
            ),
            .succeeded
        )
        dismiss(request, ownerID: ownerID, in: store)
        store.disconnect()
    }

    func testDisconnectCancelsProvisionalMetadataWithoutTouchingAddedTorrent() async throws {
        let recorder = AppStoreRequestRecorder()
        let hash = "0123456789abcdef0123456789abcdef01234567"
        AppStoreMockURLProtocol.requestHandler = { request in
            recorder.record(request)
            let action = try request.decodedActionBody()
            if action.method == "torrent-add" {
                return rpcTestResponse(
                    body: #"{"result":"success","arguments":{"torrent-added":{"id":42,"hashString":"0123456789abcdef0123456789abcdef01234567","name":"Pending metadata"}}}"#
                )
            }
            return appStoreRPCResponse(for: action.method)
        }
        let store = makeStore(
            urlSession: makeAppStoreMockSession(),
            persistedProfile: true,
            provisionalMetadataSleeper: SlowAddMetadataSleeper()
        )
        await store.connect()
        let ownerID = registerOwner(in: store)
        store.requestAddTorrent(source: "magnet:?xt=urn:btih:\(hash)")
        let request = try XCTUnwrap(store.pendingAddTorrent)

        let addResult = await store.addTorrent(
            requestID: request.id,
            presentationOwnerID: ownerID,
            source: "magnet:?xt=urn:btih:\(hash)",
            startPaused: false,
            downloadDirectory: nil,
            saveAsRequested: true
        )
        XCTAssertEqual(addResult, .awaitingSaveAs)

        store.disconnect()
        await Task.yield()

        XCTAssertEqual(store.connectionState, .disconnected)
        XCTAssertEqual(store.provisionalTorrentAddState, .idle)
        let actions = try recorder.requests.map { try $0.decodedActionBody() }
        XCTAssertFalse(actions.contains { $0.method == "torrent-remove" || $0.method == "torrent-rename-path" })
        XCTAssertFalse(actions.contains {
            $0.method == "torrent-get"
                && $0.arguments["ids"] == .array([.string(hash)])
        })

        store.addTorrentPresentationWillDismiss(requestID: request.id, ownerID: ownerID)
        store.addTorrentSheetDidDismiss(requestID: request.id, ownerID: ownerID)
    }

    private func registerOwner(in store: AppStore) -> UUID {
        let ownerID = UUID()
        store.registerAddTorrentPresentationOwner(ownerID)
        return ownerID
    }

    private func cancelAndDismiss(
        _ request: AppStore.PendingAddTorrent,
        ownerID: UUID,
        in store: AppStore
    ) {
        XCTAssertTrue(store.cancelPendingAddTorrent(requestID: request.id, ownerID: ownerID))
        dismiss(request, ownerID: ownerID, in: store)
    }

    private func dismiss(
        _ request: AppStore.PendingAddTorrent,
        ownerID: UUID,
        in store: AppStore
    ) {
        store.addTorrentPresentationWillDismiss(requestID: request.id, ownerID: ownerID)
        store.addTorrentSheetDidDismiss(requestID: request.id, ownerID: ownerID)
    }

    @discardableResult
    private func assertPresented(
        _ store: AppStore,
        ownerID: UUID,
        source: AppStore.PendingAddTorrent.Source,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> AppStore.PendingAddTorrent {
        let request = try! XCTUnwrap(
            store.presentedAddTorrent(for: ownerID),
            file: file,
            line: line
        )
        XCTAssertTrue(store.showingAddTorrent, file: file, line: line)
        XCTAssertEqual(request.source, source, file: file, line: line)
        XCTAssertEqual(request.presentationOwnerID, ownerID, file: file, line: line)
        return request
    }

    private func makeConnectedStore() async -> AppStore {
        AppStoreMockURLProtocol.requestHandler = { request in
            let action = try request.decodedActionBody()
            if action.method == "torrent-add" {
                return rpcTestResponse(
                    body: #"{"result":"success","arguments":{"torrent-added":{"id":42,"hashString":"0123456789abcdef0123456789abcdef01234567","name":"Pending metadata"}}}"#
                )
            }
            return appStoreRPCResponse(for: action.method)
        }
        let store = makeStore(urlSession: makeAppStoreMockSession(), persistedProfile: true)
        await store.connect()
        return store
    }

    private func makeStore(
        urlSession: URLSession = .shared,
        persistedProfile: Bool = false,
        provisionalMetadataSleeper: any ReconnectSleeping = TaskReconnectSleeper(),
        provisionalMetadataPollingPolicy: ProvisionalTorrentMetadataPollingPolicy = .standard,
        intakeAutomationPreferencesStore: IntakeAutomationPreferencesStore? = nil
    ) -> AppStore {
        let profileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("profiles.json")
        let passwordStore = PendingAddTorrentTestPasswordStore()
        let profileStore = persistedProfile
            ? makePersistedConnectionProfileStore(
                fileURL: profileURL,
                passwordStore: passwordStore
            )
            : ConnectionProfileStore(fileURL: profileURL, passwordStore: passwordStore)
        return AppStore(
            profileStore: profileStore,
            userDefaults: UserDefaults(suiteName: UUID().uuidString)!,
            downloadCompletionNotifier: PendingAddTorrentTestNotifier(),
            provisionalMetadataSleeper: provisionalMetadataSleeper,
            provisionalMetadataPollingPolicy: provisionalMetadataPollingPolicy,
            intakeAutomationPreferencesStore: intakeAutomationPreferencesStore,
            clientFactory: { profile in
                TransmissionRPCClient(profile: profile, urlSession: urlSession)
            }
        )
    }

    private func waitUntil(
        attempts: Int = 100,
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0 ..< attempts {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }
}

private final class PendingAddTorrentTestPasswordStore: ConnectionPasswordStoring {
    func password(for profileID: ConnectionProfile.ID) throws -> String? {
        nil
    }

    func setPassword(_ password: String, for profileID: ConnectionProfile.ID) throws {}

    func removePassword(for profileID: ConnectionProfile.ID) throws {}
}

private final class PendingAddTorrentTestNotifier: DownloadCompletionNotifying {
    func notifyDownloadCompleted(torrentName: String) {}
}

private struct ImmediateAddMetadataSleeper: ReconnectSleeping {
    func sleep(for duration: Duration) async throws {
        try Task.checkCancellation()
        await Task.yield()
    }
}

private struct SlowAddMetadataSleeper: ReconnectSleeping {
    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: .seconds(60))
    }
}

private final class LockedAddMetadataCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() -> Int {
        lock.withLock {
            value += 1
            return value
        }
    }
}
