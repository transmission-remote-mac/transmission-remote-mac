// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import XCTest
@testable import TransmissionRemoteMac

final class FilterEngineTests: XCTestCase {
    private let engine = TorrentFilterEngine()

    func testEmptyFiltersMatchAllTorrents() {
        let torrents = fixtures()

        XCTAssertEqual(engine.filter(torrents, using: .empty).map(\.id), [1, 2, 3, 4, 5])
    }

    func testStatusFiltersMatchTransguiStatusRows() {
        let torrents = fixtures()

        XCTAssertEqual(ids(matching: [.all], in: torrents), [1, 2, 3, 4, 5])
        XCTAssertEqual(ids(matching: [.downloading], in: torrents), [1])
        XCTAssertEqual(ids(matching: [.done], in: torrents), [2, 4])
        XCTAssertEqual(ids(matching: [.active], in: torrents), [1, 2])
        XCTAssertEqual(ids(matching: [.inactive], in: torrents), [3])
        XCTAssertEqual(ids(matching: [.stopped], in: torrents), [4, 5])
        XCTAssertEqual(ids(matching: [.error], in: torrents), [5])
        XCTAssertEqual(ids(matching: [.waiting], in: torrents), [3])
    }

    func testMultipleStatusFiltersAreOrWithinStatusCategory() {
        let torrents = fixtures()
        let filters = TorrentFilters(statuses: [.downloading, .waiting])

        XCTAssertEqual(engine.filter(torrents, using: filters).map(\.id), [1, 3])
    }

    func testFilterCategoriesCombineWithAnd() {
        let torrents = fixtures()
        let filters = TorrentFilters(
            statuses: [.downloading, .done],
            paths: ["/downloads/linux"],
            trackers: ["tracker-one.example"]
        )

        XCTAssertEqual(engine.filter(torrents, using: filters).map(\.id), [1])
    }

    func testPathAndTrackerFiltersUseExactValues() {
        let torrents = fixtures()
        let exactPath = TorrentFilters(paths: ["/downloads/linux"])
        let partialPath = TorrentFilters(paths: ["/downloads"])
        let exactTracker = TorrentFilters(trackers: ["tracker-one.example"])
        let partialTracker = TorrentFilters(trackers: ["tracker-one"])

        XCTAssertEqual(engine.filter(torrents, using: exactPath).map(\.id), [1, 4])
        XCTAssertEqual(engine.filter(torrents, using: partialPath).map(\.id), [])
        XCTAssertEqual(engine.filter(torrents, using: exactTracker).map(\.id), [1, 3])
        XCTAssertEqual(engine.filter(torrents, using: partialTracker).map(\.id), [])
    }

    func testLabelFilterUsesSubstringAgainstDisplayString() {
        let torrents = fixtures()
        let filters = TorrentFilters(labels: ["ux, is"])

        XCTAssertEqual(engine.filter(torrents, using: filters).map(\.id), [1, 4])
    }

    func testSearchTextMatchesUsefulFieldsSeparately() {
        let torrents = fixtures()

        XCTAssertEqual(engine.filter(torrents, using: TorrentFilters(searchText: "fedora")).map(\.id), [1])
        XCTAssertEqual(engine.filter(torrents, using: TorrentFilters(searchText: "tracker-two")).map(\.id), [2, 5])
        XCTAssertEqual(engine.filter(torrents, using: TorrentFilters(searchText: "stalled")).map(\.id), [5])
        XCTAssertEqual(engine.filter(torrents, using: TorrentFilters(searchText: "tv")).map(\.id), [3])
    }

    func testDynamicCountsAreDerivedFromTorrentSummaries() {
        let counts = engine.counts(for: fixtures())

        XCTAssertEqual(counts.statuses[.all], 5)
        XCTAssertEqual(counts.statuses[.downloading], 1)
        XCTAssertEqual(counts.statuses[.done], 2)
        XCTAssertEqual(counts.statuses[.active], 2)
        XCTAssertEqual(counts.statuses[.inactive], 1)
        XCTAssertEqual(counts.statuses[.stopped], 2)
        XCTAssertEqual(counts.statuses[.error], 1)
        XCTAssertEqual(counts.statuses[.waiting], 1)
        XCTAssertEqual(counts.paths, [
            TorrentFilterCount(value: "/downloads/linux", count: 2),
            TorrentFilterCount(value: "/downloads/tv", count: 1),
            TorrentFilterCount(value: "/media/movies", count: 2)
        ])
        XCTAssertEqual(counts.trackers, [
            TorrentFilterCount(value: "tracker-one.example", count: 2),
            TorrentFilterCount(value: "tracker-three.example", count: 1),
            TorrentFilterCount(value: "tracker-two.example", count: 2)
        ])
        XCTAssertEqual(counts.labels, [
            TorrentFilterCount(value: "errored", count: 1),
            TorrentFilterCount(value: "iso", count: 2),
            TorrentFilterCount(value: "linux", count: 3),
            TorrentFilterCount(value: "movie", count: 1),
            TorrentFilterCount(value: "tv", count: 1)
        ])
    }

    private func ids(matching statuses: Set<TorrentFilterStatus>, in torrents: [TorrentSummary]) -> [Int] {
        engine.filter(torrents, using: TorrentFilters(statuses: statuses)).map(\.id)
    }

    private func fixtures() -> [TorrentSummary] {
        [
            torrent(
                id: 1,
                name: "Fedora Workstation",
                status: .downloading,
                percentDone: 0.5,
                leftUntilDone: 500,
                rateDownload: 1200,
                path: "/downloads/linux",
                labels: ["linux", "iso"],
                tracker: "tracker-one.example"
            ),
            torrent(
                id: 2,
                name: "Ubuntu Server",
                status: .seeding,
                percentDone: 1,
                leftUntilDone: 0,
                rateUpload: 300,
                path: "/media/movies",
                labels: ["linux"],
                tracker: "tracker-two.example"
            ),
            torrent(
                id: 3,
                name: "Episode 01",
                status: .downloadWait,
                percentDone: 0.2,
                leftUntilDone: 800,
                path: "/downloads/tv",
                labels: ["tv"],
                tracker: "tracker-one.example"
            ),
            torrent(
                id: 4,
                name: "Arch ISO",
                status: .stopped,
                percentDone: 1,
                leftUntilDone: 0,
                path: "/downloads/linux",
                labels: ["linux", "iso"],
                tracker: "tracker-three.example"
            ),
            torrent(
                id: 5,
                name: "Broken archive",
                status: .stopped,
                errorString: "Tracker stalled",
                percentDone: 0.4,
                leftUntilDone: 600,
                path: "/media/movies",
                labels: ["movie", "errored"],
                tracker: "tracker-two.example"
            )
        ]
    }

    private func torrent(
        id: Int,
        name: String,
        status: TorrentStatus,
        errorString: String = "",
        percentDone: Double,
        leftUntilDone: Int64,
        rateDownload: Int64 = 0,
        rateUpload: Int64 = 0,
        path: String,
        labels: [String],
        tracker: String
    ) -> TorrentSummary {
        TorrentSummary(json: [
            "id": .int(id),
            "name": .string(name),
            "status": .int(status.rawValue),
            "errorString": .string(errorString),
            "percentDone": .double(percentDone),
            "totalSize": .int(1000),
            "sizeWhenDone": .int(1000),
            "leftUntilDone": .int(Int(leftUntilDone)),
            "rateDownload": .int(Int(rateDownload)),
            "rateUpload": .int(Int(rateUpload)),
            "eta": .int(-1),
            "uploadRatio": .double(0),
            "downloadDir": .string(path),
            "labels": .array(labels.map(JSONValue.string)),
            "trackerStats": .array([.object(["host": .string(tracker)])])
        ])
    }
}
