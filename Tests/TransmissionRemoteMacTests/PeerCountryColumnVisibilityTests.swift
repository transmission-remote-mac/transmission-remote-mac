// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import AppKit
import SwiftUI
import XCTest
@testable import TransmissionRemoteMac

@MainActor
final class PeerCountryColumnVisibilityTests: XCTestCase {
    func testMountedPeersCountryFollowsSavedChoiceWithoutDatabaseOrTableRemount() async throws {
        try await withMountedPeers(countryVisibility: .automatic) { host, window, preferences, columns, defaults in
            let table = try await mountedTable(in: host)
            XCTAssertFalse(visibleTitles(in: table).contains("Country"))
            let originalColumnOrder = visibleTitles(in: table)
            let initialSort = defaults.string(forKey: SecondaryTablePreferenceKeys.peerSort)
            let originalRevision = columns.replacementRevision
            let originalFrame = window.frame

            // No database/controller is supplied: the saved opt-in, not temporary database availability, owns visibility.
            try preferences.save(PeerResolutionPreferences(resolveHostNames: false, resolveCountries: true, showCountryFlags: false))
            await settleLayout(in: host)
            let enabledTable = try await mountedTable(in: host)
            XCTAssertTrue(enabledTable === table)
            XCTAssertTrue(visibleTitles(in: enabledTable).contains("Country"))
            XCTAssertEqual(visibleTitles(in: enabledTable).filter { $0 != "Country" }, originalColumnOrder)
            XCTAssertEqual(columns.customization[visibility: SecondaryTableColumnID.Peers.country], .automatic)

            try preferences.save(.defaults)
            await settleLayout(in: host)
            let disabledTable = try await mountedTable(in: host)
            XCTAssertTrue(disabledTable === table)
            XCTAssertFalse(visibleTitles(in: disabledTable).contains("Country"))
            XCTAssertEqual(visibleTitles(in: disabledTable), originalColumnOrder)
            XCTAssertEqual(columns.replacementRevision, originalRevision)
            XCTAssertEqual(defaults.string(forKey: SecondaryTablePreferenceKeys.peerSort), initialSort)
            XCTAssertEqual(window.frame, originalFrame)
            XCTAssertFalse(window.isVisible)
            XCTAssertFalse(window.isKeyWindow)
        }
    }

    func testMountedPeersCountryPreservesExplicitUserVisibilityAcrossPreferenceChanges() async throws {
        for visibility in [Visibility.visible, .hidden] {
            try await withMountedPeers(countryVisibility: visibility) { host, window, preferences, columns, _ in
                let table = try await mountedTable(in: host)
                XCTAssertFalse(visibleTitles(in: table).contains("Country"))

                try preferences.save(PeerResolutionPreferences(resolveHostNames: false, resolveCountries: true, showCountryFlags: true))
                await settleLayout(in: host)
                let enabledTable = try await mountedTable(in: host)
                XCTAssertTrue(enabledTable === table)
                XCTAssertEqual(visibleTitles(in: enabledTable).contains("Country"), visibility == .visible)
                XCTAssertEqual(columns.customization[visibility: SecondaryTableColumnID.Peers.country], visibility)

                try preferences.save(.defaults)
                await settleLayout(in: host)
                let disabledTable = try await mountedTable(in: host)
                XCTAssertFalse(visibleTitles(in: disabledTable).contains("Country"))
                XCTAssertEqual(columns.customization[visibility: SecondaryTableColumnID.Peers.country], visibility)
                XCTAssertEqual(columns.replacementRevision, 0)
                XCTAssertFalse(window.isVisible)
                XCTAssertFalse(window.isKeyWindow)
            }
        }
    }

    private func withMountedPeers(countryVisibility: Visibility, operation: (NSView, NSWindow, PeerResolutionPreferencesStore, TableColumnCustomizationPersistenceController<TorrentPeer>, UserDefaults) async throws -> Void) async throws {
        _ = NSApplication.shared
        let suiteName = "PeerCountryColumnVisibilityTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let sort = SecondaryTableSortPreference(columnID: SecondaryTableColumnID.Peers.country, direction: .descending)
        defaults.set(sort.rawValue, forKey: SecondaryTablePreferenceKeys.peerSort)
        let preferences = PeerResolutionPreferencesStore(userDefaults: defaults)
        let columns = TableColumnCustomizationPersistenceController<TorrentPeer>(storageKey: SecondaryTablePreferenceKeys.peerColumns, userDefaults: defaults)
        if countryVisibility != .automatic {
            var customization = columns.customization
            customization[visibility: SecondaryTableColumnID.Peers.country] = countryVisibility
            columns.update(customization)
        }
        let peer = TorrentPeer(index: 0, json: [
            "address": .string("192.0.2.1"),
            "port": .int(51413),
            "clientName": .string("Fixture Client"),
            "progress": .double(1)
        ])
        let detail = TorrentDetail(id: 1, peers: [peer], peersSnapshotRevision: .init())
        let host = NSHostingView(rootView: TorrentPeersView(
            state: .loaded(detail),
            isActive: true,
            peerResolutionPreferencesStore: preferences,
            columnCustomizationController: columns
        ).defaultAppStorage(defaults))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_050, height: 320), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer {
            window.contentView = nil
            window.close()
        }
        await settleLayout(in: host)
        try await operation(host, window, preferences, columns, defaults)
    }

    private func mountedTable(in root: NSView) async throws -> NSTableView {
        await settleLayout(in: root)
        return try XCTUnwrap(firstTable(in: root), "The production Peers view must mount its native table")
    }

    private func firstTable(in root: NSView) -> NSTableView? {
        if let table = root as? NSTableView { return table }
        return root.subviews.lazy.compactMap { self.firstTable(in: $0) }.first
    }

    private func visibleTitles(in table: NSTableView) -> [String] {
        table.tableColumns.filter { !$0.isHidden }.map { $0.headerCell.stringValue }
    }

    private func settleLayout(in view: NSView) async {
        for _ in 0..<6 {
            view.layoutSubtreeIfNeeded()
            await Task.yield()
        }
        view.layoutSubtreeIfNeeded()
    }
}
