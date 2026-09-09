// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Combine
import Foundation
import SwiftUI

@MainActor
final class TableColumnCustomizationPersistenceController<Row: Identifiable>: ObservableObject {
    @Published private(set) var customization: TableColumnCustomization<Row>
    @Published private(set) var replacementRevision: UInt64 = 0
    private(set) var columnWidths: [String: CGFloat] = [:]

    private let storageKey: String
    private let userDefaults: UserDefaults
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        storageKey: String,
        userDefaults: UserDefaults,
        encoder: JSONEncoder = JSONEncoder(),
        decoder: JSONDecoder = JSONDecoder()
    ) {
        self.storageKey = storageKey
        self.userDefaults = userDefaults
        self.encoder = encoder
        self.decoder = decoder
        customization = Self.load(
            storageKey: storageKey,
            userDefaults: userDefaults,
            decoder: decoder
        )
        columnWidths = (try? encoder.encode(customization)).map(TableColumnWidthSnapshot.widths) ?? [:]
    }

    var binding: Binding<TableColumnCustomization<Row>> {
        Binding(
            get: { self.customization },
            set: { self.update($0) }
        )
    }

    func binding(hidingColumnIDs: Set<String>) -> Binding<TableColumnCustomization<Row>> {
        Binding(
            get: { self.presentedCustomization(hidingColumnIDs: hidingColumnIDs) },
            set: { customization in
                guard customization != self.presentedCustomization(hidingColumnIDs: hidingColumnIDs) else {
                    return
                }
                var customization = customization
                // Presentation-only hiding must never replace the user's saved choice.
                for columnID in hidingColumnIDs {
                    customization[visibility: columnID] = self.customization[visibility: columnID]
                }
                self.update(customization)
            }
        )
    }

    func update(_ customization: TableColumnCustomization<Row>) {
        guard customization != self.customization,
              let data = try? encoder.encode(customization) else {
            return
        }
        userDefaults.set(data, forKey: storageKey)
        columnWidths = TableColumnWidthSnapshot.widths(in: data)
        self.customization = customization
    }

    func reset() {
        userDefaults.removeObject(forKey: storageKey)
        columnWidths = [:]
        customization = TableColumnCustomization()
        replacementRevision &+= 1
    }

    func reloadFromPersistence() {
        let restored = Self.load(
            storageKey: storageKey,
            userDefaults: userDefaults,
            decoder: decoder
        )
        columnWidths = (try? encoder.encode(restored)).map(TableColumnWidthSnapshot.widths) ?? [:]
        customization = restored
        replacementRevision &+= 1
    }

    private func presentedCustomization(hidingColumnIDs: Set<String>) -> TableColumnCustomization<Row> {
        var customization = self.customization
        for columnID in hidingColumnIDs {
            customization[visibility: columnID] = .hidden
        }
        return customization
    }

    private static func load(
        storageKey: String,
        userDefaults: UserDefaults,
        decoder: JSONDecoder
    ) -> TableColumnCustomization<Row> {
        guard let storedValue = userDefaults.object(forKey: storageKey) else {
            return TableColumnCustomization()
        }
        guard let data = storedValue as? Data,
              data.count <= TableColumnCustomizationPortabilityService
                .maximumEncodedCustomizationByteCount,
              let customization = try? decoder.decode(
                  TableColumnCustomization<Row>.self,
                  from: data
              ) else {
            return TableColumnCustomization()
        }
        return customization
    }
}

@MainActor
final class TableColumnCustomizationWorkspaceController: ObservableObject {
    let main: TableColumnCustomizationPersistenceController<TorrentSummary>
    let files: TableColumnCustomizationPersistenceController<TorrentFileNode>
    let peers: TableColumnCustomizationPersistenceController<TorrentPeer>
    let trackers: TableColumnCustomizationPersistenceController<TorrentTracker>

    init(userDefaults: UserDefaults) {
        main = TableColumnCustomizationPersistenceController(
            storageKey: TorrentTableColumnPreferenceKeys.customization,
            userDefaults: userDefaults
        )
        files = TableColumnCustomizationPersistenceController(
            storageKey: SecondaryTablePreferenceKeys.fileColumns,
            userDefaults: userDefaults
        )
        peers = TableColumnCustomizationPersistenceController(
            storageKey: SecondaryTablePreferenceKeys.peerColumns,
            userDefaults: userDefaults
        )
        trackers = TableColumnCustomizationPersistenceController(
            storageKey: SecondaryTablePreferenceKeys.trackerColumns,
            userDefaults: userDefaults
        )
    }

    func reloadFromPersistence() {
        main.reloadFromPersistence()
        files.reloadFromPersistence()
        peers.reloadFromPersistence()
        trackers.reloadFromPersistence()
    }
}
