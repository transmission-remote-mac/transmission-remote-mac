// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation
import SwiftUI

struct TableColumnCustomizationPortabilitySnapshot: Equatable, Sendable {
    var portableValue: PortableTableColumnCustomizations
    var visibleTorrentColumns: Set<TorrentTableColumnID>
    var hiddenFileColumnIDs: Set<String>
    var hiddenPeerColumnIDs: Set<String>
    var hiddenTrackerColumnIDs: Set<String>
}

enum TableColumnCustomizationPortabilityService {
    static let maximumEncodedCustomizationByteCount = 64 * 1_024

    static func persistedSnapshot(
        from userDefaults: UserDefaults,
        fallbackVisibleTorrentColumns: Set<TorrentTableColumnID>,
        fallbackSecondaryTables: SecondaryTableWorkspacePreferences
    ) throws -> TableColumnCustomizationPortabilitySnapshot {
        let fallback = try legacyPortableValue(
            visibleTorrentColumns: fallbackVisibleTorrentColumns,
            secondaryTables: fallbackSecondaryTables
        )
        return try validated(PortableTableColumnCustomizations(
            main: storedValue(
                forKey: TorrentTableColumnPreferenceKeys.customization,
                in: userDefaults,
                fallback: fallback.main,
                tableName: "main"
            ),
            files: storedValue(
                forKey: SecondaryTablePreferenceKeys.fileColumns,
                in: userDefaults,
                fallback: fallback.files,
                tableName: "Files"
            ),
            peers: storedValue(
                forKey: SecondaryTablePreferenceKeys.peerColumns,
                in: userDefaults,
                fallback: fallback.peers,
                tableName: "Peers"
            ),
            trackers: storedValue(
                forKey: SecondaryTablePreferenceKeys.trackerColumns,
                in: userDefaults,
                fallback: fallback.trackers,
                tableName: "Trackers"
            )
        ))
    }

    static func validated(
        _ portableValue: PortableTableColumnCustomizations
    ) throws -> TableColumnCustomizationPortabilitySnapshot {
        let main: TableColumnCustomization<TorrentSummary> = try decoded(
            portableValue.main,
            tableName: "main",
            requiredColumnID: TorrentTableColumnID.name.rawValue
        )
        let files: TableColumnCustomization<TorrentFileNode> = try decoded(
            portableValue.files,
            tableName: "Files",
            requiredColumnID: SecondaryTableKind.files.requiredColumnID
        )
        let peers: TableColumnCustomization<TorrentPeer> = try decoded(
            portableValue.peers,
            tableName: "Peers",
            requiredColumnID: SecondaryTableKind.peers.requiredColumnID
        )
        let trackers: TableColumnCustomization<TorrentTracker> = try decoded(
            portableValue.trackers,
            tableName: "Trackers",
            requiredColumnID: SecondaryTableKind.trackers.requiredColumnID
        )

        return TableColumnCustomizationPortabilitySnapshot(
            portableValue: portableValue,
            visibleTorrentColumns: TorrentTableColumnVisibility.resolvedColumns(in: main),
            hiddenFileColumnIDs: hiddenColumnIDs(in: files, table: .files),
            hiddenPeerColumnIDs: hiddenColumnIDs(in: peers, table: .peers),
            hiddenTrackerColumnIDs: hiddenColumnIDs(in: trackers, table: .trackers)
        )
    }

    static func legacyPortableValue(
        visibleTorrentColumns: Set<TorrentTableColumnID>,
        secondaryTables: SecondaryTableWorkspacePreferences
    ) throws -> PortableTableColumnCustomizations {
        return PortableTableColumnCustomizations(
            main: try encodedVisibilityOnly(
                TorrentTableColumnID.allCases.compactMap { column in
                    guard !column.isRequired else { return nil }
                    return (
                        column.rawValue,
                        visibleTorrentColumns.contains(column)
                    )
                },
                as: TorrentSummary.self,
                tableName: "main",
                requiredColumnID: TorrentTableColumnID.name.rawValue
            ),
            files: try encodedSecondary(
                preference: secondaryTables.files,
                table: .files,
                as: TorrentFileNode.self
            ),
            peers: try encodedSecondary(
                preference: secondaryTables.peers,
                table: .peers,
                as: TorrentPeer.self
            ),
            trackers: try encodedSecondary(
                preference: secondaryTables.trackers,
                table: .trackers,
                as: TorrentTracker.self
            )
        )
    }

    private static func storedValue(
        forKey key: String,
        in userDefaults: UserDefaults,
        fallback: PortableTableColumnCustomization,
        tableName: String
    ) throws -> PortableTableColumnCustomization {
        guard let storedValue = userDefaults.object(forKey: key) else { return fallback }
        guard let data = storedValue as? Data else {
            throw SettingsPortabilityError.invalidTableColumnCustomization(tableName)
        }
        return PortableTableColumnCustomization(encodedValue: data)
    }

    private static func decoded<Row: Identifiable>(
        _ portableValue: PortableTableColumnCustomization,
        tableName: String,
        requiredColumnID: String
    ) throws -> TableColumnCustomization<Row> {
        guard portableValue.encodedValue.count <= maximumEncodedCustomizationByteCount else {
            throw SettingsPortabilityError.tableColumnCustomizationTooLarge(tableName)
        }
        let customization: TableColumnCustomization<Row>
        do {
            customization = try JSONDecoder().decode(
                TableColumnCustomization<Row>.self,
                from: portableValue.encodedValue
            )
        } catch {
            throw SettingsPortabilityError.invalidTableColumnCustomization(tableName)
        }
        guard customization[visibility: requiredColumnID] != .hidden else {
            throw SettingsPortabilityError.requiredTableColumnHidden(tableName)
        }
        return customization
    }

    private static func hiddenColumnIDs<Row: Identifiable>(
        in customization: TableColumnCustomization<Row>,
        table: SecondaryTableKind
    ) -> Set<String> {
        Set(table.columnIDs.filter { columnID in
            guard columnID != table.requiredColumnID else { return false }
            switch customization[visibility: columnID] {
            case .visible:
                return false
            case .hidden:
                return true
            default:
                return table.defaultHiddenColumnIDs.contains(columnID)
            }
        })
    }

    private static func encodedSecondary<Row: Identifiable>(
        preference: SecondaryTableLayoutPreference,
        table: SecondaryTableKind,
        as rowType: Row.Type
    ) throws -> PortableTableColumnCustomization {
        let hiddenColumnIDs = preference.normalized(for: table).hiddenColumnIDs
        let tableName = switch table {
        case .files: "Files"
        case .peers: "Peers"
        case .trackers: "Trackers"
        }
        return try encodedVisibilityOnly(
            table.columnIDs.compactMap { columnID in
                guard columnID != table.requiredColumnID else { return nil }
                return (columnID, !hiddenColumnIDs.contains(columnID))
            },
            as: rowType,
            tableName: tableName,
            requiredColumnID: table.requiredColumnID
        )
    }

    private static func encodedVisibilityOnly<Row: Identifiable>(
        _ entries: [(id: String, isVisible: Bool)],
        as _: Row.Type,
        tableName: String,
        requiredColumnID: String
    ) throws -> PortableTableColumnCustomization {
        // SwiftUI's public customization encoder writes visibility state in
        // randomized hash order. Legacy visibility-only migration needs stable
        // bytes, so emit the minimal native envelope in catalog order, then
        // immediately prove that the current public decoder preserves it.
        let envelope = DeterministicTableVisibilityEnvelope(entries: entries)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(envelope)
        guard let customization = try? JSONDecoder().decode(
            TableColumnCustomization<Row>.self,
            from: data
        ),
        customization[visibility: requiredColumnID] != .hidden,
        entries.allSatisfy({ entry in
            customization[visibility: entry.id]
                == (entry.isVisible ? .visible : .hidden)
        }) else {
            throw SettingsPortabilityError.invalidTableColumnCustomization(tableName)
        }
        return PortableTableColumnCustomization(encodedValue: data)
    }
}

private struct DeterministicTableVisibilityEnvelope: Encodable {
    var perColumnState: [DeterministicTableColumnState]

    init(entries: [(id: String, isVisible: Bool)]) {
        perColumnState = entries.flatMap { entry in
            [
                DeterministicTableColumnState(
                    base: DeterministicTableColumnBase(
                        explicit: DeterministicTableColumnID(value: entry.id)
                    )
                ),
                DeterministicTableColumnState(
                    visibility: DeterministicTableColumnVisibility(
                        isVisible: entry.isVisible
                    )
                ),
            ]
        }
    }
}

private struct DeterministicTableColumnState: Encodable {
    var base: DeterministicTableColumnBase?
    var visibility: DeterministicTableColumnVisibility?

    init(
        base: DeterministicTableColumnBase? = nil,
        visibility: DeterministicTableColumnVisibility? = nil
    ) {
        self.base = base
        self.visibility = visibility
    }
}

private struct DeterministicTableColumnBase: Encodable {
    var explicit: DeterministicTableColumnID
}

private struct DeterministicTableColumnID: Encodable {
    var value: String

    private enum CodingKeys: String, CodingKey {
        case value = "_0"
    }
}

private struct DeterministicTableColumnVisibility: Encodable {
    private enum Value {
        case visible
        case hidden
    }

    private let value: Value

    init(isVisible: Bool) {
        value = isVisible ? .visible : .hidden
    }

    private enum CodingKeys: String, CodingKey {
        case visible
        case hidden
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch value {
        case .visible:
            try container.encode(DeterministicTableColumnVisibilityValue(), forKey: .visible)
        case .hidden:
            try container.encode(DeterministicTableColumnVisibilityValue(), forKey: .hidden)
        }
    }
}

private struct DeterministicTableColumnVisibilityValue: Encodable {}
