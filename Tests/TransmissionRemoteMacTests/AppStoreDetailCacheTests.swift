// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Combine
import XCTest
@testable import TransmissionRemoteMac

@MainActor
final class AppStoreDetailCacheTests: XCTestCase {
    override func tearDown() {
        AppStoreMockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testRapidSelectionDebouncesDetailFetchToFinalTorrent() async throws {
        let recorder = AppStoreRequestRecorder()
        let detailLog = AppStoreDetailRequestLog()
        let finalDetailStarted = expectation(description: "final selected torrent detail started")
        AppStoreMockURLProtocol.requestHandler = { request in
            recorder.record(request)
            let body = try request.decodedActionBody()
            if let detailRequest = appStoreDetailRequest(from: body) {
                detailLog.record(detailRequest)
                if detailRequest.torrentID == 3, detailRequest.pane == .overview {
                    finalDetailStarted.fulfill()
                }
                return appStoreDetailResponse(torrentID: detailRequest.torrentID)
            }
            return appStoreResponse(for: body)
        }
        let store = makeStore()
        await store.connect()

        store.selectedTorrentIDs = [1]
        store.selectedTorrentIDs = [2]
        store.selectedTorrentIDs = [3]

        await fulfillment(of: [finalDetailStarted], timeout: 1)

        XCTAssertFalse(detailLog.requests.contains { $0.torrentID == 1 || $0.torrentID == 2 })
        XCTAssertEqual(
            detailLog.requests.filter { $0.torrentID == 3 && $0.pane == .overview }.count,
            1
        )
        XCTAssertTrue(try recorder.requests.map { try $0.decodedActionBody() }.contains { request in
            appStoreDetailRequest(from: request)?.torrentID == 3
        })
        store.disconnect()
    }

    func testPrefetchedPaneRevisitUsesCacheWithoutFreshRequestOrLoadingFlicker() async {
        let detailLog = AppStoreDetailRequestLog()
        let cacheReady = expectation(description: "standard pane snapshots cached")
        AppStoreMockURLProtocol.requestHandler = { request in
            let body = try request.decodedActionBody()
            if let detailRequest = appStoreDetailRequest(from: body) {
                detailLog.record(detailRequest)
                return appStoreDetailResponse(torrentID: detailRequest.torrentID)
            }
            return appStoreResponse(for: body)
        }
        let store = makeStore(selectionDebounceDuration: .zero)
        var fulfilledCacheReady = false
        let cacheObservation = store.$selectedTorrentDetailState.sink { state in
            guard
                !fulfilledCacheReady,
                let detail = state.detail,
                detail.generalInfo != nil,
                !detail.peers.isEmpty,
                !detail.trackers.isEmpty
            else {
                return
            }
            fulfilledCacheReady = true
            cacheReady.fulfill()
        }
        await store.connect()

        store.selectedTorrentIDs = [1]
        await fulfillment(of: [cacheReady], timeout: 1)
        XCTAssertEqual(detailLog.requests.count, 3)
        XCTAssertEqual(detailLog.count(torrentID: 1, pane: .files), 0)

        store.selectedTorrentDetailPane = .trackers
        XCTAssertNotNil(store.selectedTorrentDetailState.detail)
        XCTAssertFalse(store.selectedTorrentDetailState.detail?.trackers.isEmpty ?? true)
        store.selectedTorrentDetailPane = .overview
        XCTAssertNotNil(store.selectedTorrentDetailState.detail?.generalInfo)
        XCTAssertEqual(detailLog.requests.count, 3)

        withExtendedLifetime(cacheObservation) {}
        store.disconnect()
    }

    func testStaleSelectionResponseCannotReplaceNewTorrentDetail() async {
        let firstDetailStarted = expectation(description: "first torrent detail started")
        let secondDetailLoaded = expectation(description: "second torrent detail loaded")
        let releaseFirstDetail = DispatchSemaphore(value: 0)
        AppStoreMockURLProtocol.requestHandler = { request in
            let body = try request.decodedActionBody()
            if let detailRequest = appStoreDetailRequest(from: body) {
                if detailRequest.torrentID == 1, detailRequest.pane == .overview {
                    firstDetailStarted.fulfill()
                    _ = releaseFirstDetail.wait(timeout: .now() + 2)
                }
                return appStoreDetailResponse(torrentID: detailRequest.torrentID)
            }
            return appStoreResponse(for: body)
        }
        let store = makeStore(selectionDebounceDuration: .zero)
        var fulfilledSecondDetail = false
        let detailObservation = store.$selectedTorrentDetailState.sink { state in
            guard
                !fulfilledSecondDetail,
                state.detail?.id == 2,
                state.detail?.generalInfo?.comment == "detail-2"
            else {
                return
            }
            fulfilledSecondDetail = true
            secondDetailLoaded.fulfill()
        }
        await store.connect()

        store.selectedTorrentIDs = [1]
        await fulfillment(of: [firstDetailStarted], timeout: 1)
        store.selectedTorrentIDs = [2]
        XCTAssertNil(store.selectedTorrentDetailState.detail)

        releaseFirstDetail.signal()
        await fulfillment(of: [secondDetailLoaded], timeout: 1)

        XCTAssertEqual(store.selectedTorrentDetailState.detail?.id, 2)
        XCTAssertEqual(store.selectedTorrentDetailState.detail?.generalInfo?.comment, "detail-2")
        withExtendedLifetime(detailObservation) {}
        store.disconnect()
    }

    func testFileActionInvalidationRefetchesFilesPane() async {
        let detailLog = AppStoreDetailRequestLog()
        let cacheReady = expectation(description: "file snapshot cached")
        let filesRefetched = expectation(description: "files pane refetched after mutation")
        AppStoreMockURLProtocol.requestHandler = { request in
            let body = try request.decodedActionBody()
            if let detailRequest = appStoreDetailRequest(from: body) {
                let paneRequestCount = detailLog.record(detailRequest)
                if detailRequest.pane == .files, paneRequestCount == 2 {
                    filesRefetched.fulfill()
                }
                return appStoreDetailResponse(torrentID: detailRequest.torrentID)
            }
            return appStoreResponse(for: body)
        }
        let store = makeStore(selectionDebounceDuration: .zero)
        var fulfilledCacheReady = false
        let cacheObservation = store.$selectedTorrentDetailState.sink { state in
            guard !fulfilledCacheReady, state.detail?.files.count == 1 else { return }
            fulfilledCacheReady = true
            cacheReady.fulfill()
        }
        await store.connect()

        store.selectedTorrentIDs = [1]
        store.selectedTorrentDetailPane = .files
        await fulfillment(of: [cacheReady], timeout: 1)
        XCTAssertNotNil(store.selectedTorrentFileMutationOwner)
        XCTAssertEqual(detailLog.count(torrentID: 1, pane: .files), 1)

        guard let owner = store.selectedTorrentFileMutationOwner else {
            return XCTFail("Expected an immutable Files mutation owner")
        }
        await store.setTorrentFilesWanted(false, fileIndexes: [0], owner: owner)
        await fulfillment(of: [filesRefetched], timeout: 1)

        XCTAssertEqual(detailLog.count(torrentID: 1, pane: .files), 2)
        withExtendedLifetime(cacheObservation) {}
        store.disconnect()
    }

    func testManualRefreshFetchesActiveDetailPaneOnlyOnce() async {
        let detailLog = AppStoreDetailRequestLog()
        let cacheReady = expectation(description: "standard pane snapshots cached")
        let refreshedOverview = expectation(description: "overview refreshed once")
        AppStoreMockURLProtocol.requestHandler = { request in
            let body = try request.decodedActionBody()
            if let detailRequest = appStoreDetailRequest(from: body) {
                let paneRequestCount = detailLog.record(detailRequest)
                if detailRequest.pane == .overview, paneRequestCount == 2 {
                    refreshedOverview.fulfill()
                }
                return appStoreDetailResponse(torrentID: detailRequest.torrentID)
            }
            return appStoreResponse(for: body)
        }
        let store = makeStore(selectionDebounceDuration: .zero)
        var fulfilledCacheReady = false
        let cacheObservation = store.$selectedTorrentDetailState.sink { state in
            guard
                !fulfilledCacheReady,
                let detail = state.detail,
                detail.generalInfo != nil,
                !detail.peers.isEmpty,
                !detail.trackers.isEmpty
            else {
                return
            }
            fulfilledCacheReady = true
            cacheReady.fulfill()
        }
        await store.connect()

        store.selectedTorrentIDs = [1]
        await fulfillment(of: [cacheReady], timeout: 1)
        XCTAssertEqual(detailLog.count(torrentID: 1, pane: .overview), 1)

        await store.refresh()
        await fulfillment(of: [refreshedOverview], timeout: 1)

        XCTAssertEqual(detailLog.count(torrentID: 1, pane: .overview), 2)
        XCTAssertEqual(detailLog.count(torrentID: 1, pane: .files), 0)
        XCTAssertEqual(detailLog.count(torrentID: 1, pane: .peers), 1)
        XCTAssertEqual(detailLog.count(torrentID: 1, pane: .trackers), 1)
        withExtendedLifetime(cacheObservation) {}
        store.disconnect()
    }

    func testStatisticsSelectionSuppressesThenResumesDetailPrefetches() async {
        let detailLog = AppStoreDetailRequestLog()
        let prefetchGate = DetailPrefetchExpectationGate()
        let staleOverviewStarted = expectation(description: "stale overview request started")
        let replacementOverviewStarted = expectation(description: "replacement overview request started")
        let unexpectedPrefetch = expectation(description: "Statistics does not prefetch torrent detail panes")
        unexpectedPrefetch.isInverted = true
        let resumedPrefetch = expectation(description: "returning from Statistics resumes detail prefetch")
        resumedPrefetch.expectedFulfillmentCount = 2
        let releaseOverview = DispatchSemaphore(value: 0)
        defer { releaseOverview.signal() }
        AppStoreMockURLProtocol.requestHandler = { request in
            let body = try request.decodedActionBody()
            if let detailRequest = appStoreDetailRequest(from: body) {
                let paneRequestCount = detailLog.record(detailRequest)
                if detailRequest.pane == .overview {
                    if paneRequestCount == 1 {
                        staleOverviewStarted.fulfill()
                        _ = releaseOverview.wait(timeout: .now() + 2)
                    } else if paneRequestCount == 2 {
                        replacementOverviewStarted.fulfill()
                    }
                } else if prefetchGate.isEnabled {
                    resumedPrefetch.fulfill()
                } else {
                    unexpectedPrefetch.fulfill()
                }
                return appStoreDetailResponse(torrentID: detailRequest.torrentID)
            }
            return appStoreResponse(for: body)
        }
        let store = makeStore(selectionDebounceDuration: .zero)
        await store.connect()

        store.selectedTorrentIDs = [1]
        await fulfillment(of: [staleOverviewStarted], timeout: 1)
        store.selectedTorrentDetailPane = .statistics
        releaseOverview.signal()
        await fulfillment(of: [unexpectedPrefetch], timeout: 0.1)

        XCTAssertEqual(detailLog.requests.count, 1)
        XCTAssertEqual(detailLog.count(torrentID: 1, pane: .overview), 1)
        XCTAssertEqual(detailLog.count(torrentID: 1, pane: .trackers), 0)
        XCTAssertEqual(detailLog.count(torrentID: 1, pane: .peers), 0)
        XCTAssertEqual(detailLog.count(torrentID: 1, pane: .files), 0)

        prefetchGate.enable()
        store.selectedTorrentDetailPane = .overview
        await fulfillment(of: [replacementOverviewStarted], timeout: 1)
        await fulfillment(of: [resumedPrefetch], timeout: 1)

        XCTAssertEqual(detailLog.requests.count, 4)
        XCTAssertEqual(detailLog.count(torrentID: 1, pane: .overview), 2)
        XCTAssertEqual(detailLog.count(torrentID: 1, pane: .trackers), 1)
        XCTAssertEqual(detailLog.count(torrentID: 1, pane: .peers), 1)
        XCTAssertEqual(detailLog.count(torrentID: 1, pane: .files), 0)
        store.disconnect()
    }

    private func makeStore(selectionDebounceDuration: Duration = .milliseconds(100)) -> AppStore {
        let profileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("profiles.json")
        let session = makeAppStoreMockSession()
        return AppStore(
            profileStore: makePersistedConnectionProfileStore(
                fileURL: profileURL,
                passwordStore: DetailCacheTestPasswordStore()
            ),
            userDefaults: UserDefaults(suiteName: UUID().uuidString)!,
            downloadCompletionNotifier: DetailCacheTestNotifier(),
            detailRefreshPolicy: TorrentDetailRefreshPolicy(prefetchPolicy: .standard),
            selectionDebounceDuration: selectionDebounceDuration,
            clientFactory: { profile in
                TransmissionRPCClient(profile: profile, urlSession: session)
            }
        )
    }
}

private struct AppStoreRecordedDetailRequest: Equatable {
    var torrentID: Int
    var pane: TorrentDetailPane
}

private final class AppStoreDetailRequestLog {
    private let lock = NSLock()
    private var recordedRequests: [AppStoreRecordedDetailRequest] = []

    var requests: [AppStoreRecordedDetailRequest] {
        lock.withLock { recordedRequests }
    }

    @discardableResult
    func record(_ request: AppStoreRecordedDetailRequest) -> Int {
        lock.withLock {
            recordedRequests.append(request)
            return recordedRequests.filter {
                $0.torrentID == request.torrentID && $0.pane == request.pane
            }.count
        }
    }

    func count(torrentID: Int, pane: TorrentDetailPane) -> Int {
        lock.withLock {
            recordedRequests.filter { $0.torrentID == torrentID && $0.pane == pane }.count
        }
    }
}

private final class DetailPrefetchExpectationGate {
    private let lock = NSLock()
    private var enabled = false

    var isEnabled: Bool {
        lock.withLock { enabled }
    }

    func enable() {
        lock.withLock {
            enabled = true
        }
    }
}

private func appStoreDetailRequest(from request: RPCRequest) -> AppStoreRecordedDetailRequest? {
    guard
        request.method == "torrent-get",
        let selector = request.arguments["ids"]?.arrayValue?.first,
        let torrentID = selector.intValue ?? selector.stringValue.flatMap({ Int($0.prefix(1)) })
    else {
        return nil
    }

    let fields = Set(request.arguments["fields"]?.arrayValue?.compactMap(\.stringValue) ?? [])
    let pane: TorrentDetailPane
    if fields.contains("files") {
        pane = .files
    } else if fields.contains("peers") {
        pane = .peers
    } else if fields.contains("comment") || fields.contains("pieceCount") {
        pane = .overview
    } else {
        pane = .trackers
    }
    return AppStoreRecordedDetailRequest(torrentID: torrentID, pane: pane)
}

private func appStoreResponse(for request: RPCRequest) -> (HTTPURLResponse, Data) {
    guard request.method == "torrent-get" else {
        return appStoreRPCResponse(for: request.method)
    }
    return rpcTestResponse(
        body: #"{"result":"success","arguments":{"torrents":[{"id":1,"name":"One","status":0,"percentDone":0,"totalSize":100,"sizeWhenDone":100,"leftUntilDone":50,"hashString":"1111111111111111111111111111111111111111","downloadDir":"/downloads"},{"id":2,"name":"Two","status":0,"percentDone":0,"totalSize":200,"sizeWhenDone":200,"leftUntilDone":100,"hashString":"2222222222222222222222222222222222222222","downloadDir":"/downloads"},{"id":3,"name":"Three","status":0,"percentDone":0,"totalSize":300,"sizeWhenDone":300,"leftUntilDone":150,"hashString":"3333333333333333333333333333333333333333","downloadDir":"/downloads"}]}}"#
    )
}

private func appStoreDetailResponse(torrentID: Int) -> (HTTPURLResponse, Data) {
    let hash = String(repeating: String(torrentID), count: 40)
    return rpcTestResponse(
        body: #"{"result":"success","arguments":{"torrents":[{"id":\#(torrentID),"hashString":"\#(hash)","comment":"detail-\#(torrentID)","files":[{"name":"folder/file.bin","length":100,"bytesCompleted":50}],"fileStats":[{"bytesCompleted":50,"wanted":true,"priority":0}],"peers":[{"address":"10.0.0.\#(torrentID)","port":51413,"clientName":"Test Peer"}],"trackers":[{"id":1,"announce":"https://tracker.example/announce"}],"trackerStats":[{"id":1,"host":"tracker.example","hasAnnounced":true,"lastAnnounceSucceeded":true}]}]}}"#
    )
}

private final class DetailCacheTestPasswordStore: ConnectionPasswordStoring {
    func password(for profileID: ConnectionProfile.ID) throws -> String? { nil }
    func setPassword(_ password: String, for profileID: ConnectionProfile.ID) throws {}
    func removePassword(for profileID: ConnectionProfile.ID) throws {}
}

private final class DetailCacheTestNotifier: DownloadCompletionNotifying {
    func notifyDownloadCompleted(torrentName: String) {}
}
