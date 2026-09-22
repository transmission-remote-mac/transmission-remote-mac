// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import AppKit
import SwiftUI
import XCTest
@testable import TransmissionRemoteMac

@MainActor
final class MainTableColumnVisibilityTests: XCTestCase {
    func testEveryOptionalVisibilityChangeRemountsTableAndUpdatesHeaderColumns() async throws {
        _ = NSApplication.shared
        let suiteName = "MainTableColumnVisibilityTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let profileDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: profileDirectoryURL) }
        let profileURL = profileDirectoryURL.appendingPathComponent("profiles.json")
        let store = AppStore(
            profileStore: makePersistedConnectionProfileStore(
                fileURL: profileURL,
                passwordStore: MainTableColumnVisibilityPasswordStore()
            ),
            userDefaults: defaults,
            downloadCompletionNotifier: MainTableColumnVisibilityNotifier()
        )
        let columns = store.tableColumnCustomizationController.main
        let host = NSHostingView(rootView: TorrentTableView(
            store: store,
            interactionPreferencesStore: store.interactionPreferencesController,
            tableColumnCustomizationController: columns
        ).defaultAppStorage(defaults))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_200, height: 360),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer {
            window.contentView = nil
            window.close()
        }

        for columnID in TorrentTableColumnID.allCases where !columnID.isRequired {
            let originalTable = try await mountedTable(in: host)
            let wasVisible = visibleTitles(in: originalTable).contains(columnID.title)

            var customization = columns.customization
            customization[visibility: columnID.rawValue] = wasVisible ? .hidden : .visible
            columns.update(customization)

            let updatedTable = try await mountedTable(in: host)
            XCTAssertFalse(updatedTable === originalTable, columnID.rawValue)
            XCTAssertEqual(
                visibleTitles(in: updatedTable).contains(columnID.title),
                !wasVisible,
                columnID.rawValue
            )

            customization = columns.customization
            customization[visibility: columnID.rawValue] = wasVisible ? .visible : .hidden
            columns.update(customization)

            let restoredTable = try await mountedTable(in: host)
            XCTAssertFalse(restoredTable === updatedTable, columnID.rawValue)
            XCTAssertEqual(
                visibleTitles(in: restoredTable).contains(columnID.title),
                wasVisible,
                columnID.rawValue
            )
        }
        XCTAssertEqual(columns.replacementRevision, 0)
    }

    private func mountedTable(in root: NSView) async throws -> NSTableView {
        for _ in 0..<6 {
            root.layoutSubtreeIfNeeded()
            await Task.yield()
        }
        root.layoutSubtreeIfNeeded()
        return try XCTUnwrap(firstTable(in: root), "The main view must mount its native table")
    }

    private func firstTable(in root: NSView) -> NSTableView? {
        if let table = root as? NSTableView { return table }
        return root.subviews.lazy.compactMap { self.firstTable(in: $0) }.first
    }

    private func visibleTitles(in table: NSTableView) -> [String] {
        table.tableColumns.filter { !$0.isHidden }.map { $0.headerCell.stringValue }
    }
}

private final class MainTableColumnVisibilityPasswordStore: ConnectionPasswordStoring {
    func password(for profileID: ConnectionProfile.ID) throws -> String? { nil }
    func setPassword(_ password: String, for profileID: ConnectionProfile.ID) throws {}
    func removePassword(for profileID: ConnectionProfile.ID) throws {}
}

private final class MainTableColumnVisibilityNotifier: DownloadCompletionNotifying {
    func notifyDownloadCompleted(torrentName: String) {}
}
