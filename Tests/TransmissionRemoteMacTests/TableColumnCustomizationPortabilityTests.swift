// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation
import SwiftUI
import XCTest
@testable import TransmissionRemoteMac

final class TableColumnCustomizationPortabilityTests: XCTestCase {
    func testMainAndSecondaryOpaqueOrderWidthVisibilityPayloadsRoundTripByteForByte() throws {
        let portableValue = NativeTableColumnCustomizationFixtures.portableValue
        let validated = try TableColumnCustomizationPortabilityService.validated(portableValue)
        let expectedMain = try NativeTableColumnCustomizationFixtureInspector.inspect(
            portableValue.main.encodedValue
        )
        let expectedPeers = try NativeTableColumnCustomizationFixtureInspector.inspect(
            portableValue.peers.encodedValue
        )
        let suiteName = "TableColumnCustomizationPortabilityTests.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        store(portableValue, in: userDefaults)

        let restored = try TableColumnCustomizationPortabilityService.persistedSnapshot(
            from: userDefaults,
            fallbackVisibleTorrentColumns: [.name],
            fallbackSecondaryTables: .defaults
        )

        XCTAssertEqual(validated.portableValue, portableValue)
        XCTAssertEqual(restored.portableValue, portableValue)
        XCTAssertFalse(restored.visibleTorrentColumns.contains(.labels))
        XCTAssertTrue(restored.visibleTorrentColumns.contains(.size))
        XCTAssertEqual(restored.hiddenFileColumnIDs, [])
        XCTAssertEqual(restored.hiddenPeerColumnIDs, [SecondaryTableColumnID.Peers.port])
        XCTAssertEqual(
            restored.hiddenTrackerColumnIDs,
            [SecondaryTableColumnID.Trackers.downloads]
        )
        XCTAssertEqual(
            try NativeTableColumnCustomizationFixtureInspector.inspect(
                restored.portableValue.main.encodedValue
            ),
            expectedMain
        )
        XCTAssertEqual(
            try NativeTableColumnCustomizationFixtureInspector.inspect(
                restored.portableValue.peers.encodedValue
            ),
            expectedPeers
        )
        XCTAssertEqual(
            expectedMain,
            NativeTableColumnCustomizationFixtureInspection(
                orderedColumnIDs: [
                    "torrent.eta",
                    "torrent.status",
                    "torrent.name",
                    "torrent.location",
                    "torrent.peers",
                    "torrent.labels",
                    "torrent.progress",
                    "torrent.completedOn",
                    "torrent.tracker",
                    "torrent.swarm",
                    "torrent.size",
                    "torrent.seeds"
                ],
                widths: [nil, 95, 553.5, 300, nil, 114, 124, nil, 220, nil, 90, nil]
            )
        )
        XCTAssertEqual(
            expectedPeers,
            NativeTableColumnCustomizationFixtureInspection(
                orderedColumnIDs: [
                    SecondaryTableColumnID.Peers.client,
                    SecondaryTableColumnID.Peers.host
                ],
                widths: [426, 414]
            )
        )
    }

    func testValidationRejectsMalformedOversizedAndRequiredColumnPayloads() throws {
        let valid = try makePortableValue()

        var malformed = valid
        malformed.files.encodedValue = Data("not-json".utf8)
        XCTAssertThrowsError(
            try TableColumnCustomizationPortabilityService.validated(malformed)
        ) { error in
            XCTAssertEqual(
                error as? SettingsPortabilityError,
                .invalidTableColumnCustomization("Files")
            )
        }

        var oversized = valid
        oversized.peers.encodedValue = Data(
            repeating: 0,
            count: TableColumnCustomizationPortabilityService
                .maximumEncodedCustomizationByteCount + 1
        )
        XCTAssertThrowsError(
            try TableColumnCustomizationPortabilityService.validated(oversized)
        ) { error in
            XCTAssertEqual(
                error as? SettingsPortabilityError,
                .tableColumnCustomizationTooLarge("Peers")
            )
        }

        var main = TableColumnCustomization<TorrentSummary>()
        main[visibility: TorrentTableColumnID.name.rawValue] = .hidden
        var hiddenRequired = valid
        hiddenRequired.main = try encoded(main)
        XCTAssertThrowsError(
            try TableColumnCustomizationPortabilityService.validated(hiddenRequired)
        ) { error in
            XCTAssertEqual(
                error as? SettingsPortabilityError,
                .requiredTableColumnHidden("main")
            )
        }
    }

    func testLegacyVisibilityFallbackBuildsTypedNativeCustomizationsForEveryTable() throws {
        let portableValue = try TableColumnCustomizationPortabilityService.legacyPortableValue(
            visibleTorrentColumns: [.name, .done, .uploaded],
            secondaryTables: SecondaryTableWorkspacePreferences(
                files: SecondaryTableLayoutPreference(
                    hiddenColumnIDs: [SecondaryTableColumnID.Files.priority],
                    sortPreference: SecondaryTableDefaults.fileSort
                ),
                peers: SecondaryTableLayoutPreference(
                    hiddenColumnIDs: [SecondaryTableColumnID.Peers.client],
                    sortPreference: SecondaryTableDefaults.peerSort
                ),
                trackers: SecondaryTableLayoutPreference(
                    hiddenColumnIDs: [SecondaryTableColumnID.Trackers.status],
                    sortPreference: SecondaryTableDefaults.trackerSort
                )
            )
        )

        let main = try JSONDecoder().decode(
            TableColumnCustomization<TorrentSummary>.self,
            from: portableValue.main.encodedValue
        )
        let files = try JSONDecoder().decode(
            TableColumnCustomization<TorrentFileNode>.self,
            from: portableValue.files.encodedValue
        )
        let peers = try JSONDecoder().decode(
            TableColumnCustomization<TorrentPeer>.self,
            from: portableValue.peers.encodedValue
        )
        let trackers = try JSONDecoder().decode(
            TableColumnCustomization<TorrentTracker>.self,
            from: portableValue.trackers.encodedValue
        )

        XCTAssertEqual(
            TorrentTableColumnVisibility.resolvedColumns(in: main),
            [.name, .done, .uploaded]
        )
        XCTAssertEqual(
            files[visibility: SecondaryTableColumnID.Files.priority],
            .hidden
        )
        XCTAssertEqual(
            peers[visibility: SecondaryTableColumnID.Peers.client],
            .hidden
        )
        XCTAssertEqual(
            trackers[visibility: SecondaryTableColumnID.Trackers.status],
            .hidden
        )
        XCTAssertNotEqual(
            main[visibility: TorrentTableColumnID.name.rawValue],
            .hidden
        )
        XCTAssertNotEqual(
            files[visibility: SecondaryTableColumnID.Files.name],
            .hidden
        )
        XCTAssertNotEqual(
            peers[visibility: SecondaryTableColumnID.Peers.host],
            .hidden
        )
        XCTAssertNotEqual(
            trackers[visibility: SecondaryTableColumnID.Trackers.tracker],
            .hidden
        )

        XCTAssertEqual(
            try TableColumnCustomizationPortabilityService.validated(portableValue)
                .portableValue,
            portableValue
        )

        for index in 0 ..< 50 {
            _ = Data(repeating: UInt8(index), count: index * 257)
            XCTAssertEqual(
                try TableColumnCustomizationPortabilityService.legacyPortableValue(
                    visibleTorrentColumns: [.name, .done, .uploaded],
                    secondaryTables: SecondaryTableWorkspacePreferences(
                        files: SecondaryTableLayoutPreference(
                            hiddenColumnIDs: [SecondaryTableColumnID.Files.priority],
                            sortPreference: SecondaryTableDefaults.fileSort
                        ),
                        peers: SecondaryTableLayoutPreference(
                            hiddenColumnIDs: [SecondaryTableColumnID.Peers.client],
                            sortPreference: SecondaryTableDefaults.peerSort
                        ),
                        trackers: SecondaryTableLayoutPreference(
                            hiddenColumnIDs: [SecondaryTableColumnID.Trackers.status],
                            sortPreference: SecondaryTableDefaults.trackerSort
                        )
                    )
                ),
                portableValue
            )
        }

        XCTAssertEqual(
            try NativeTableColumnCustomizationFixtureInspector.inspect(
                portableValue.main.encodedValue
            ).orderedColumnIDs,
            TorrentTableColumnID.allCases
                .filter { !$0.isRequired }
                .map(\.rawValue)
        )
    }

    private func makePortableValue() throws -> PortableTableColumnCustomizations {
        var main = TableColumnCustomization<TorrentSummary>()
        main[visibility: TorrentTableColumnID.labels.rawValue] = .hidden
        main[visibility: TorrentTableColumnID.uploaded.rawValue] = .visible

        var files = TableColumnCustomization<TorrentFileNode>()
        files[visibility: SecondaryTableColumnID.Files.priority] = .hidden

        var peers = TableColumnCustomization<TorrentPeer>()
        peers[visibility: SecondaryTableColumnID.Peers.port] = .visible
        peers[visibility: SecondaryTableColumnID.Peers.client] = .hidden

        var trackers = TableColumnCustomization<TorrentTracker>()
        trackers[visibility: SecondaryTableColumnID.Trackers.downloads] = .hidden

        return PortableTableColumnCustomizations(
            main: try encoded(main),
            files: try encoded(files),
            peers: try encoded(peers),
            trackers: try encoded(trackers)
        )
    }

    private func encoded<Row: Identifiable>(
        _ customization: TableColumnCustomization<Row>
    ) throws -> PortableTableColumnCustomization {
        PortableTableColumnCustomization(
            encodedValue: try JSONEncoder().encode(customization)
        )
    }

    private func store(
        _ portableValue: PortableTableColumnCustomizations,
        in userDefaults: UserDefaults
    ) {
        userDefaults.set(
            portableValue.main.encodedValue,
            forKey: TorrentTableColumnPreferenceKeys.customization
        )
        userDefaults.set(
            portableValue.files.encodedValue,
            forKey: SecondaryTablePreferenceKeys.fileColumns
        )
        userDefaults.set(
            portableValue.peers.encodedValue,
            forKey: SecondaryTablePreferenceKeys.peerColumns
        )
        userDefaults.set(
            portableValue.trackers.encodedValue,
            forKey: SecondaryTablePreferenceKeys.trackerColumns
        )
    }
}

/// Captured from native `TableColumnCustomization` encoding after column moves and resizes.
/// Production treats these bytes as opaque; only tests inspect SwiftUI's private JSON shape.
enum NativeTableColumnCustomizationFixtures {
    static let main = Data(#"{"perColumnState":[{"base":{"explicit":{"_0":"torrent.eta"}}},{"visibility":{"hidden":{}}},{"base":{"explicit":{"_0":"torrent.status"}}},{"visibility":{"automatic":{}},"currentWidth":95},{"base":{"explicit":{"_0":"torrent.name"}}},{"visibility":{"automatic":{}},"currentWidth":553.5},{"base":{"explicit":{"_0":"torrent.location"}}},{"visibility":{"hidden":{}},"currentWidth":300},{"base":{"explicit":{"_0":"torrent.peers"}}},{"visibility":{"hidden":{}}},{"base":{"explicit":{"_0":"torrent.labels"}}},{"visibility":{"hidden":{}},"currentWidth":114},{"base":{"explicit":{"_0":"torrent.progress"}}},{"visibility":{"automatic":{}},"currentWidth":124},{"base":{"explicit":{"_0":"torrent.completedOn"}}},{"visibility":{"visible":{}}},{"base":{"explicit":{"_0":"torrent.tracker"}}},{"visibility":{"hidden":{}},"currentWidth":220},{"base":{"explicit":{"_0":"torrent.swarm"}}},{"visibility":{"hidden":{}}},{"base":{"explicit":{"_0":"torrent.size"}}},{"visibility":{"automatic":{}},"currentWidth":90},{"base":{"explicit":{"_0":"torrent.seeds"}}},{"visibility":{"hidden":{}}}]}"#.utf8)
    static let files = Data(#"{"perColumnState":[{"base":{"explicit":{"_0":"torrentDetail.files.name"}}},{"visibility":{"automatic":{}},"currentWidth":937}]}"#.utf8)
    static let peers = Data(#"{"perColumnState":[{"base":{"explicit":{"_0":"torrentDetail.peers.client"}}},{"currentWidth":426,"visibility":{"automatic":{}}},{"base":{"explicit":{"_0":"torrentDetail.peers.host"}}},{"currentWidth":414,"visibility":{"automatic":{}}}]}"#.utf8)
    static let trackers = Data(#"{"perColumnState":[{"base":{"explicit":{"_0":"torrentDetail.trackers.tracker"}}},{"currentWidth":996,"visibility":{"automatic":{}}}]}"#.utf8)

    static let portableValue = PortableTableColumnCustomizations(
        main: PortableTableColumnCustomization(encodedValue: main),
        files: PortableTableColumnCustomization(encodedValue: files),
        peers: PortableTableColumnCustomization(encodedValue: peers),
        trackers: PortableTableColumnCustomization(encodedValue: trackers)
    )
}

struct NativeTableColumnCustomizationFixtureInspection: Equatable {
    var orderedColumnIDs: [String]
    var widths: [Double?]
}

enum NativeTableColumnCustomizationFixtureInspector {
    static func inspect(_ data: Data) throws -> NativeTableColumnCustomizationFixtureInspection {
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        var orderedColumnIDs: [String] = []
        var widths: [Double?] = []

        for (index, state) in payload.perColumnState.enumerated() {
            guard let columnID = state.base?.explicit.value else { continue }
            orderedColumnIDs.append(columnID)
            widths.append(
                payload.perColumnState.indices.contains(index + 1)
                    ? payload.perColumnState[index + 1].currentWidth
                    : nil
            )
        }

        return NativeTableColumnCustomizationFixtureInspection(
            orderedColumnIDs: orderedColumnIDs,
            widths: widths
        )
    }

    private struct Payload: Decodable {
        var perColumnState: [ColumnState]
    }

    private struct ColumnState: Decodable {
        var base: Base?
        var currentWidth: Double?
    }

    private struct Base: Decodable {
        var explicit: Explicit
    }

    private struct Explicit: Decodable {
        var value: String

        private enum CodingKeys: String, CodingKey {
            case value = "_0"
        }
    }
}
