// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation
import SwiftUI
import XCTest
@testable import TransmissionRemoteMac

@MainActor
final class TableColumnCustomizationPersistenceControllerTests: XCTestCase {
    func testInitialFixtureRestoresBeforeMount() throws {
        try withUserDefaults { userDefaults in
            userDefaults.set(
                NativeTableColumnCustomizationFixtures.main,
                forKey: TorrentTableColumnPreferenceKeys.customization
            )
            let expected = try JSONDecoder().decode(
                TableColumnCustomization<TorrentSummary>.self,
                from: NativeTableColumnCustomizationFixtures.main
            )

            let controller = TableColumnCustomizationPersistenceController<TorrentSummary>(
                storageKey: TorrentTableColumnPreferenceKeys.customization,
                userDefaults: userDefaults
            )

            XCTAssertEqual(controller.customization, expected)
            XCTAssertEqual(controller.binding.wrappedValue, expected)
            XCTAssertEqual(controller.replacementRevision, 0)
            XCTAssertEqual(
                try widthsByColumnID(
                    JSONEncoder().encode(controller.customization)
                ),
                try widthsByColumnID(
                    NativeTableColumnCustomizationFixtures.main
                )
            )
        }
    }

    func testBindingUpdatePersistsAndRecreatedControllerRestoresCustomization() throws {
        try withUserDefaults { userDefaults in
            let expected = try JSONDecoder().decode(
                TableColumnCustomization<TorrentSummary>.self,
                from: NativeTableColumnCustomizationFixtures.main
            )
            let controller = TableColumnCustomizationPersistenceController<TorrentSummary>(
                storageKey: TorrentTableColumnPreferenceKeys.customization,
                userDefaults: userDefaults
            )

            controller.binding.wrappedValue = expected

            let storedData = try XCTUnwrap(
                userDefaults.data(forKey: TorrentTableColumnPreferenceKeys.customization)
            )
            XCTAssertEqual(
                try widthsByColumnID(storedData),
                try widthsByColumnID(
                    NativeTableColumnCustomizationFixtures.main
                )
            )
            let recreated = TableColumnCustomizationPersistenceController<TorrentSummary>(
                storageKey: TorrentTableColumnPreferenceKeys.customization,
                userDefaults: userDefaults
            )
            XCTAssertEqual(recreated.customization, expected)
            XCTAssertEqual(controller.replacementRevision, 0)
        }
    }

    func testWidthOnlyUpdatePersistsAndRecreatedControllerRestoresWidth() throws {
        try withUserDefaults { userDefaults in
            let resizedFixture = Data(
                String(
                    decoding: NativeTableColumnCustomizationFixtures.main,
                    as: UTF8.self
                )
                .replacingOccurrences(
                    of: #""currentWidth":553.5"#,
                    with: #""currentWidth":612.25"#
                )
                .utf8
            )
            let original = try JSONDecoder().decode(
                TableColumnCustomization<TorrentSummary>.self,
                from: NativeTableColumnCustomizationFixtures.main
            )
            let resized = try JSONDecoder().decode(
                TableColumnCustomization<TorrentSummary>.self,
                from: resizedFixture
            )
            XCTAssertNotEqual(original, resized)
            userDefaults.set(
                NativeTableColumnCustomizationFixtures.main,
                forKey: TorrentTableColumnPreferenceKeys.customization
            )
            let controller = TableColumnCustomizationPersistenceController<TorrentSummary>(
                storageKey: TorrentTableColumnPreferenceKeys.customization,
                userDefaults: userDefaults
            )

            controller.update(resized)

            let storedData = try XCTUnwrap(
                userDefaults.data(forKey: TorrentTableColumnPreferenceKeys.customization)
            )
            XCTAssertEqual(
                try requiredWidth(
                    for: TorrentTableColumnID.name.rawValue,
                    in: storedData
                ),
                612.25
            )
            let recreated = TableColumnCustomizationPersistenceController<TorrentSummary>(
                storageKey: TorrentTableColumnPreferenceKeys.customization,
                userDefaults: userDefaults
            )
            XCTAssertEqual(recreated.customization, resized)
            XCTAssertEqual(
                try requiredWidth(
                    for: TorrentTableColumnID.name.rawValue,
                    in: JSONEncoder().encode(recreated.customization)
                ),
                612.25
            )
        }
    }

    func testExternalPersistenceReplacementReloadsAllWorkspaceTables() throws {
        try withUserDefaults { userDefaults in
            let workspace = TableColumnCustomizationWorkspaceController(
                userDefaults: userDefaults
            )
            userDefaults.set(
                NativeTableColumnCustomizationFixtures.main,
                forKey: TorrentTableColumnPreferenceKeys.customization
            )
            userDefaults.set(
                NativeTableColumnCustomizationFixtures.files,
                forKey: SecondaryTablePreferenceKeys.fileColumns
            )
            userDefaults.set(
                NativeTableColumnCustomizationFixtures.peers,
                forKey: SecondaryTablePreferenceKeys.peerColumns
            )
            userDefaults.set(
                NativeTableColumnCustomizationFixtures.trackers,
                forKey: SecondaryTablePreferenceKeys.trackerColumns
            )

            workspace.reloadFromPersistence()

            XCTAssertEqual(
                workspace.main.customization,
                try JSONDecoder().decode(
                    TableColumnCustomization<TorrentSummary>.self,
                    from: NativeTableColumnCustomizationFixtures.main
                )
            )
            XCTAssertEqual(
                workspace.files.customization,
                try JSONDecoder().decode(
                    TableColumnCustomization<TorrentFileNode>.self,
                    from: NativeTableColumnCustomizationFixtures.files
                )
            )
            XCTAssertEqual(
                workspace.peers.customization,
                try JSONDecoder().decode(
                    TableColumnCustomization<TorrentPeer>.self,
                    from: NativeTableColumnCustomizationFixtures.peers
                )
            )
            XCTAssertEqual(
                workspace.trackers.customization,
                try JSONDecoder().decode(
                    TableColumnCustomization<TorrentTracker>.self,
                    from: NativeTableColumnCustomizationFixtures.trackers
                )
            )
            XCTAssertEqual(workspace.main.replacementRevision, 1)
            XCTAssertEqual(workspace.files.replacementRevision, 1)
            XCTAssertEqual(workspace.peers.replacementRevision, 1)
            XCTAssertEqual(workspace.trackers.replacementRevision, 1)
        }
    }

    func testMalformedAndOversizedStoredBytesUseDefaultWithoutOverwritingStorage() throws {
        try withUserDefaults { userDefaults in
            let invalidValues = [
                Data("not-json".utf8),
                Data(
                    repeating: 0,
                    count: TableColumnCustomizationPortabilityService
                        .maximumEncodedCustomizationByteCount + 1
                ),
            ]

            for invalidValue in invalidValues {
                userDefaults.set(
                    invalidValue,
                    forKey: TorrentTableColumnPreferenceKeys.customization
                )

                let controller = TableColumnCustomizationPersistenceController<TorrentSummary>(
                    storageKey: TorrentTableColumnPreferenceKeys.customization,
                    userDefaults: userDefaults
                )

                XCTAssertEqual(controller.customization, TableColumnCustomization())
                XCTAssertEqual(
                    userDefaults.data(forKey: TorrentTableColumnPreferenceKeys.customization),
                    invalidValue
                )
                XCTAssertEqual(controller.replacementRevision, 0)
            }
        }
    }

    func testResetRemovesPersistenceAndReplacesRuntimeCustomization() throws {
        try withUserDefaults { userDefaults in
            userDefaults.set(
                NativeTableColumnCustomizationFixtures.main,
                forKey: TorrentTableColumnPreferenceKeys.customization
            )
            let controller = TableColumnCustomizationPersistenceController<TorrentSummary>(
                storageKey: TorrentTableColumnPreferenceKeys.customization,
                userDefaults: userDefaults
            )

            controller.reset()

            XCTAssertEqual(controller.customization, TableColumnCustomization())
            XCTAssertNil(
                userDefaults.object(forKey: TorrentTableColumnPreferenceKeys.customization)
            )
            XCTAssertEqual(controller.replacementRevision, 1)
        }
    }

    func testVisibilityMaskDoesNotWriteStorageOrReplaceMountedTable() throws {
        try withWriteCountingDefaults { userDefaults in
            let key = SecondaryTablePreferenceKeys.peerColumns
            userDefaults.set(countryColumnFixture, forKey: key)
            let controller = TableColumnCustomizationPersistenceController<TorrentPeer>(storageKey: key, userDefaults: userDefaults)
            let original = controller.customization
            let widths = controller.columnWidths
            let stored = userDefaults.data(forKey: key)
            userDefaults.writeCount = 0

            let masked = controller.binding(hidingColumnIDs: [SecondaryTableColumnID.Peers.country]).wrappedValue

            XCTAssertEqual(masked[visibility: SecondaryTableColumnID.Peers.country], .hidden)
            XCTAssertEqual(controller.binding.wrappedValue, original)
            XCTAssertEqual(controller.binding(hidingColumnIDs: []).wrappedValue, original)
            XCTAssertEqual(controller.columnWidths, widths)
            XCTAssertEqual(userDefaults.data(forKey: key), stored)
            XCTAssertEqual(userDefaults.writeCount, 0)
            XCTAssertEqual(controller.replacementRevision, 0)
            XCTAssertEqual(
                try widthsByColumnID(JSONEncoder().encode(masked)),
                try widthsByColumnID(countryColumnFixture)
            )
        }
    }

    func testMaskedBindingRoundTripPreservesVisibleHiddenAndAutomaticChoices() throws {
        for visibility in [Visibility.visible, .hidden, .automatic] {
            try withWriteCountingDefaults { userDefaults in
                let key = SecondaryTablePreferenceKeys.peerColumns
                var original = try JSONDecoder().decode(TableColumnCustomization<TorrentPeer>.self, from: NativeTableColumnCustomizationFixtures.peers)
                // Leave automatic absent to cover SwiftUI's default state as well as explicit choices.
                if visibility != .automatic { original[visibility: SecondaryTableColumnID.Peers.country] = visibility }
                userDefaults.set(try JSONEncoder().encode(original), forKey: key)
                let controller = TableColumnCustomizationPersistenceController<TorrentPeer>(storageKey: key, userDefaults: userDefaults)
                let stored = userDefaults.data(forKey: key)
                userDefaults.writeCount = 0
                let maskedBinding = controller.binding(hidingColumnIDs: [SecondaryTableColumnID.Peers.country])

                maskedBinding.wrappedValue = maskedBinding.wrappedValue

                XCTAssertEqual(controller.customization[visibility: SecondaryTableColumnID.Peers.country], visibility)
                XCTAssertEqual(controller.binding(hidingColumnIDs: []).wrappedValue, original)
                XCTAssertEqual(userDefaults.data(forKey: key), stored)
                XCTAssertEqual(userDefaults.writeCount, 0)
                XCTAssertEqual(controller.replacementRevision, 0)
                let recreated = TableColumnCustomizationPersistenceController<TorrentPeer>(storageKey: key, userDefaults: userDefaults)
                XCTAssertEqual(recreated.customization, original)
            }
        }
    }

    func testMaskedBindingPersistsOtherColumnEditsWithoutLeakingForcedVisibility() throws {
        try withWriteCountingDefaults { userDefaults in
            let key = SecondaryTablePreferenceKeys.peerColumns
            userDefaults.set(countryColumnFixture, forKey: key)
            let controller = TableColumnCustomizationPersistenceController<TorrentPeer>(storageKey: key, userDefaults: userDefaults)
            let resizedFixture = Data(String(decoding: countryColumnFixture, as: UTF8.self)
                .replacingOccurrences(of: #""currentWidth":414"#, with: #""currentWidth":566"#).utf8)
            var expected = try JSONDecoder().decode(TableColumnCustomization<TorrentPeer>.self, from: resizedFixture)
            expected[visibility: SecondaryTableColumnID.Peers.client] = .hidden
            var submitted = expected
            submitted[visibility: SecondaryTableColumnID.Peers.country] = .hidden
            userDefaults.writeCount = 0

            controller.binding(hidingColumnIDs: [SecondaryTableColumnID.Peers.country]).wrappedValue = submitted

            XCTAssertEqual(controller.customization, expected)
            XCTAssertEqual(controller.customization[visibility: SecondaryTableColumnID.Peers.country], .visible)
            XCTAssertEqual(controller.columnWidths[SecondaryTableColumnID.Peers.country], 132)
            XCTAssertEqual(controller.columnWidths[SecondaryTableColumnID.Peers.host], 566)
            XCTAssertEqual(userDefaults.writeCount, 1)
            XCTAssertEqual(controller.replacementRevision, 0)
            let stored = try XCTUnwrap(userDefaults.data(forKey: key))
            XCTAssertEqual(
                try widthsByColumnID(stored),
                try widthsByColumnID(resizedFixture)
            )
            let recreated = TableColumnCustomizationPersistenceController<TorrentPeer>(storageKey: key, userDefaults: userDefaults)
            XCTAssertEqual(recreated.customization, expected)
        }
    }

    func testEmptyCustomizationMaskEchoDoesNotCreateStorageAndOtherEditsKeepAutomaticCountry() throws {
        try withWriteCountingDefaults { userDefaults in
            let key = SecondaryTablePreferenceKeys.peerColumns
            let controller = TableColumnCustomizationPersistenceController<TorrentPeer>(storageKey: key, userDefaults: userDefaults)
            let masked = controller.binding(hidingColumnIDs: [SecondaryTableColumnID.Peers.country])
            userDefaults.writeCount = 0

            masked.wrappedValue = masked.wrappedValue

            XCTAssertNil(userDefaults.object(forKey: key))
            XCTAssertEqual(userDefaults.writeCount, 0)
            XCTAssertEqual(controller.customization, TableColumnCustomization())
            var edited = masked.wrappedValue
            edited[visibility: SecondaryTableColumnID.Peers.client] = .hidden
            masked.wrappedValue = edited

            XCTAssertEqual(userDefaults.writeCount, 1)
            XCTAssertEqual(controller.customization[visibility: SecondaryTableColumnID.Peers.country], .automatic)
            XCTAssertEqual(controller.customization[visibility: SecondaryTableColumnID.Peers.client], .hidden)
            XCTAssertEqual(controller.replacementRevision, 0)
            let recreated = TableColumnCustomizationPersistenceController<TorrentPeer>(storageKey: key, userDefaults: userDefaults)
            XCTAssertEqual(recreated.customization[visibility: SecondaryTableColumnID.Peers.country], .automatic)
            XCTAssertEqual(recreated.customization[visibility: SecondaryTableColumnID.Peers.client], .hidden)
        }
    }

    private var countryColumnFixture: Data {
        Data(#"{"perColumnState":[{"base":{"explicit":{"_0":"torrentDetail.peers.country"}}},{"currentWidth":132,"visibility":{"visible":{}}},{"base":{"explicit":{"_0":"torrentDetail.peers.client"}}},{"currentWidth":426,"visibility":{"automatic":{}}},{"base":{"explicit":{"_0":"torrentDetail.peers.host"}}},{"currentWidth":414,"visibility":{"automatic":{}}}]}"#.utf8)
    }

    private func withWriteCountingDefaults(_ operation: (ColumnMaskWriteCountingDefaults) throws -> Void) throws {
        let suiteName = "TableColumnMaskTests.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(ColumnMaskWriteCountingDefaults(suiteName: suiteName))
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        try operation(userDefaults)
    }

    private func withUserDefaults(
        _ operation: (UserDefaults) throws -> Void
    ) throws {
        let suiteName = "TableColumnCustomizationPersistenceControllerTests.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        try operation(userDefaults)
    }

    private func widthsByColumnID(_ data: Data) throws -> [String: Double?] {
        let inspection = try NativeTableColumnCustomizationFixtureInspector.inspect(data)
        return Dictionary(
            uniqueKeysWithValues: zip(
                inspection.orderedColumnIDs,
                inspection.widths
            )
        )
    }

    private func requiredWidth(for columnID: String, in data: Data) throws -> Double {
        let encodedWidth = try XCTUnwrap(widthsByColumnID(data)[columnID])
        return try XCTUnwrap(encodedWidth)
    }
}

private final class ColumnMaskWriteCountingDefaults: UserDefaults {
    var writeCount = 0

    override func set(_ value: Any?, forKey defaultName: String) {
        writeCount += 1
        super.set(value, forKey: defaultName)
    }
}
