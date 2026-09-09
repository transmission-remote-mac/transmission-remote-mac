// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation
import XCTest
@testable import TransmissionRemoteMac

@MainActor
final class AppStoreDetailVisibilityTests: XCTestCase {
    override func tearDown() {
        AppStoreMockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testDetailVisibilityDefaultsToShownAndPersistsChanges() {
        let suiteName = UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let initialStore = makeStore(userDefaults: defaults)
        XCTAssertTrue(initialStore.isTorrentDetailVisible)

        initialStore.isTorrentDetailVisible = false
        XCTAssertFalse(makeStore(userDefaults: defaults).isTorrentDetailVisible)

        initialStore.isTorrentDetailVisible = true
        XCTAssertTrue(makeStore(userDefaults: defaults).isTorrentDetailVisible)
    }

    func testHiddenSelectionDoesNotRequestDetailsAndShowingTargetsCurrentSelection() async {
        let suiteName = UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let detailLog = DetailVisibilityRequestLog()
        let currentSelectionRequested = expectation(description: "current hidden selection requested after showing details")
        AppStoreMockURLProtocol.requestHandler = { request in
            let action = try request.decodedActionBody()
            if let torrentID = detailTorrentID(from: action) {
                detailLog.record(torrentID)
                if torrentID == 2 {
                    currentSelectionRequested.fulfill()
                }
                return detailVisibilityDetailResponse(torrentID: torrentID)
            }
            return detailVisibilityResponse(for: action)
        }
        let store = makeStore(
            userDefaults: defaults,
            selectionDebounceDuration: .zero
        )
        store.isTorrentDetailVisible = false
        await store.connect()

        store.selectedTorrentIDs = [1]
        store.selectedTorrentIDs = [2]
        await Task.yield()
        await Task.yield()
        XCTAssertTrue(detailLog.torrentIDs.isEmpty)

        store.isTorrentDetailVisible = true
        await fulfillment(of: [currentSelectionRequested], timeout: 1)

        XCTAssertEqual(detailLog.torrentIDs.first, 2)
        XCTAssertFalse(detailLog.torrentIDs.contains(1))
        store.disconnect()
    }

    func testDetailNavigationSelectsPaneAndRevealsInfoPane() {
        let suiteName = UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = makeStore(userDefaults: defaults)
        store.isTorrentDetailVisible = false

        store.showTorrentDetailPane(.peers)

        XCTAssertEqual(store.selectedTorrentDetailPane, .peers)
        XCTAssertTrue(store.isTorrentDetailVisible)
    }

    func testStatusNavigationReplacesOnlyStatusSelection() {
        let suiteName = UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = makeStore(userDefaults: defaults)
        store.torrentFilters = TorrentFilters(
            statuses: [.downloading, .waiting],
            paths: ["/downloads"],
            trackers: ["tracker.example"],
            labels: ["linux"]
        )

        store.selectStatusFilter(.active)

        XCTAssertEqual(store.torrentFilters.statuses, [.active])
        XCTAssertEqual(store.torrentFilters.paths, ["/downloads"])
        XCTAssertEqual(store.torrentFilters.trackers, ["tracker.example"])
        XCTAssertEqual(store.torrentFilters.labels, ["linux"])

        store.selectStatusFilter(.all)
        XCTAssertTrue(store.torrentFilters.statuses.isEmpty)
        XCTAssertEqual(store.torrentFilters.paths, ["/downloads"])
    }

    private func makeStore(
        userDefaults: UserDefaults,
        selectionDebounceDuration: Duration = .milliseconds(100)
    ) -> AppStore {
        let profileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("profiles.json")
        let session = makeAppStoreMockSession()
        return AppStore(
            profileStore: makePersistedConnectionProfileStore(
                fileURL: profileURL,
                passwordStore: DetailVisibilityTestPasswordStore()
            ),
            userDefaults: userDefaults,
            downloadCompletionNotifier: DetailVisibilityTestNotifier(),
            selectionDebounceDuration: selectionDebounceDuration,
            clientFactory: { profile in
                TransmissionRPCClient(profile: profile, urlSession: session)
            }
        )
    }
}

private final class DetailVisibilityRequestLog {
    private let lock = NSLock()
    private var recordedTorrentIDs: [Int] = []

    var torrentIDs: [Int] {
        lock.withLock { recordedTorrentIDs }
    }

    func record(_ torrentID: Int) {
        lock.withLock {
            recordedTorrentIDs.append(torrentID)
        }
    }
}

private func detailTorrentID(from request: RPCRequest) -> Int? {
    guard request.method == "torrent-get" else { return nil }
    guard let selector = request.arguments["ids"]?.arrayValue?.first else { return nil }
    return selector.intValue ?? [1, 2, 3].first {
        String(repeating: String($0), count: 40) == selector.stringValue
    }
}

private func detailVisibilityResponse(for request: RPCRequest) -> (HTTPURLResponse, Data) {
    guard request.method == "torrent-get" else {
        return appStoreRPCResponse(for: request.method)
    }
    return rpcTestResponse(
        body: #"{"result":"success","arguments":{"torrents":[{"id":1,"name":"One","status":0,"percentDone":0,"totalSize":100,"sizeWhenDone":100,"leftUntilDone":50,"hashString":"1111111111111111111111111111111111111111","downloadDir":"/downloads"},{"id":2,"name":"Two","status":0,"percentDone":0,"totalSize":200,"sizeWhenDone":200,"leftUntilDone":100,"hashString":"2222222222222222222222222222222222222222","downloadDir":"/downloads"}]}}"#
    )
}

private func detailVisibilityDetailResponse(torrentID: Int) -> (HTTPURLResponse, Data) {
    let hash = String(repeating: String(torrentID), count: 40)
    return rpcTestResponse(
        body: #"{"result":"success","arguments":{"torrents":[{"id":\#(torrentID),"hashString":"\#(hash)","comment":"detail-\#(torrentID)"}]}}"#
    )
}

private final class DetailVisibilityTestPasswordStore: ConnectionPasswordStoring {
    func password(for profileID: ConnectionProfile.ID) throws -> String? { nil }
    func setPassword(_ password: String, for profileID: ConnectionProfile.ID) throws {}
    func removePassword(for profileID: ConnectionProfile.ID) throws {}
}

private final class DetailVisibilityTestNotifier: DownloadCompletionNotifying {
    func notifyDownloadCompleted(torrentName: String) {}
}
