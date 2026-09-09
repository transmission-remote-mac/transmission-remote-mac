// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import AppKit
import SwiftUI
import XCTest
@testable import TransmissionRemoteMac

@MainActor
final class TorrentOverviewExpansionLayoutTests: XCTestCase {
    func testLongMagnetExpansionResizesCardAndPreservesExactSelectableValue() async throws {
        let magnet = "magnet:?xt=urn:btih:" + String(repeating: "a", count: 40)
            + String(repeating: "&tr=udp%3A%2F%2Ftracker.example%3A6969%2Fannounce", count: 24)
        try await assertExpansionCycle(row: TorrentDetailRow("Magnet link", magnet, isLongText: true))
    }

    func testLongUnbrokenPathExpansionResizesCardAndPreservesExactSelectableValue() async throws {
        let path = "/downloads/" + String(repeating: "long-unbroken-folder-segment/", count: 48) + "file.mkv"
        try await assertExpansionCycle(row: TorrentDetailRow("Full path", path, isLongText: true))
    }

    func testMultilineCommentExpansionResizesCardAndPreservesExactSelectableValue() async throws {
        let comment = (1...20).map { "Comment line \($0): original spacing  and cafe\u{301} remain unchanged." }
            .joined(separator: "\n")
        try await assertExpansionCycle(row: TorrentDetailRow("Comment", comment, isLongText: true))
    }

    func testOrdinaryThreeLineValueUsesTheSameExpansionLayout() async throws {
        let value = String(repeating: "tracker-with-an-unbroken-name.example/announce/", count: 32)
        try await assertExpansionCycle(row: TorrentDetailRow("Tracker", value))
    }

    func testShortFittingValueStaysSelectableWithoutDisclosure() async throws {
        _ = NSApplication.shared
        let state = RefreshState(value: "Short comment")
        let window = makeRefreshWindow()
        defer {
            window.contentView = nil
            window.close()
        }
        let host = NSHostingView(rootView: RefreshFixture(state: state))
        window.contentView = host
        await settleLayout(in: host)

        XCTAssertTrue(hasExactSelectableText(state.value, in: host))
        XCTAssertTrue(nativeButtons(in: host).isEmpty,
                      "Fitting values must remain ordinary selectable text, not disclosure buttons")
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(window.isKeyWindow)
    }

    func testParentRefreshPreservesExpansionButChangedRawValueCollapses() async throws {
        _ = NSApplication.shared
        let state = RefreshState(value: String(repeating: "Original comment paragraph.\n", count: 20))
        let window = makeRefreshWindow()
        defer {
            window.contentView = nil
            window.close()
        }
        let host = NSHostingView(rootView: RefreshFixture(state: state))
        window.contentView = host
        await settleLayout(in: host)
        let originalWindowFrame = window.frame
        try disclosure(in: host).performClick(nil)
        await settleLayout(in: host)

        state.revision += 1
        await settleLayout(in: host)
        _ = try disclosure(in: host)
        XCTAssertTrue(hasExactSelectableText(state.value, in: host))

        state.value = String(repeating: "Replacement comment paragraph.\n", count: 20)
        await settleLayout(in: host)
        _ = try disclosure(in: host)
        XCTAssertFalse(hasExactSelectableText(state.value, in: host),
                       "A changed overflowing value must reset to its nonselectable capped preview")
        XCTAssertEqual(window.frame, originalWindowFrame)
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(window.isKeyWindow)
    }

    func testMountedWidthChangesReevaluateOverflowWithoutChangingValue() async throws {
        _ = NSApplication.shared
        let value = String(repeating: "Width crossing text ", count: 12)
        let state = RefreshState(value: value)
        let window = makeRefreshWindow()
        defer {
            window.contentView = nil
            window.close()
        }
        let host = NSHostingView(rootView: RefreshFixture(state: state))
        window.contentView = host
        await settleLayout(in: host)
        _ = try disclosure(in: host)
        XCTAssertFalse(hasExactSelectableText(value, in: host))

        window.setContentSize(NSSize(width: 1_400, height: 600))
        let wideFrame = window.frame
        await settleLayout(in: host)
        XCTAssertTrue(nativeButtons(in: host).isEmpty, "The mounted value must lose its disclosure when it fits")
        XCTAssertTrue(hasExactSelectableText(value, in: host))
        XCTAssertEqual(window.frame, wideFrame)

        window.setContentSize(NSSize(width: 600, height: 600))
        let narrowFrame = window.frame
        await settleLayout(in: host)
        _ = try disclosure(in: host)
        XCTAssertFalse(hasExactSelectableText(value, in: host))
        XCTAssertEqual(window.frame, narrowFrame)
        XCTAssertEqual(state.value, value)
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(window.isKeyWindow)
    }

    private func assertExpansionCycle(row: TorrentDetailRow) async throws {
        _ = NSApplication.shared
        for width in [CGFloat(500), CGFloat(1_100)] {
            let measurements = Measurements()
            let section = TorrentOverviewSection(
                title: "Torrent",
                systemImage: "doc",
                minimumColumnWidth: 180,
                columns: [TorrentOverviewColumn(id: "summary", rows: [TorrentDetailRow("Status", "Seeding")])],
                fullSpanRows: [row, TorrentDetailRow("Following attribute", "Still visible after expansion")]
            )
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: width, height: 600),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            defer {
                window.contentView = nil
                window.close()
            }
            let host = NSHostingView(rootView:
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        TorrentOverviewSectionView(section: section)
                            .equatable()
                            .textSelection(.enabled)
                            .background {
                                GeometryReader { geometry in
                                    Color.clear
                                        .onAppear { measurements.card = geometry.frame(in: .named("overview-fixture")) }
                                        .onChange(of: geometry.size) { _, _ in
                                            measurements.card = geometry.frame(in: .named("overview-fixture"))
                                        }
                                }
                            }
                        Text("Following section")
                            .background {
                                GeometryReader { geometry in
                                    Color.clear
                                        .onAppear { measurements.following = geometry.frame(in: .named("overview-fixture")) }
                                        .onChange(of: geometry.frame(in: .named("overview-fixture"))) { _, frame in
                                            measurements.following = frame
                                        }
                                }
                            }
                    }
                    .coordinateSpace(name: "overview-fixture")
                    .padding(12)
                }
            )
            window.contentView = host
            await settleLayout(in: host)
            let originalWindowFrame = window.frame
            let collapsedCard = measurements.card
            let collapsedFollowing = measurements.following
            XCTAssertGreaterThan(collapsedCard.height, 0)
            XCTAssertGreaterThan(collapsedFollowing.minY, collapsedCard.maxY)

            try disclosure(in: host).performClick(nil)
            await settleLayout(in: host)

            let expandedCard = measurements.card
            let expandedFollowing = measurements.following
            XCTAssertGreaterThan(expandedCard.height, collapsedCard.height + 20, "\(row.label), width \(width)")
            XCTAssertEqual(
                expandedFollowing.minY - collapsedFollowing.minY,
                expandedCard.height - collapsedCard.height,
                accuracy: 2,
                "The next section must move with the enclosing card, not be covered by expanded text"
            )
            XCTAssertEqual(window.frame, originalWindowFrame, "Expanding a detail must not resize the application window")
            XCTAssertTrue(hasExactSelectableText(row.displayValue, in: host),
                          "Selectable backing text must preserve the exact original copy string")
            try assertNativeSelectionCopy(row.displayValue, in: host, window: window)

            try disclosure(in: host).performClick(nil)
            await settleLayout(in: host)

            XCTAssertEqual(measurements.card.height, collapsedCard.height, accuracy: 2)
            XCTAssertEqual(measurements.following.minY, collapsedFollowing.minY, accuracy: 2)
            XCTAssertEqual(window.frame, originalWindowFrame)
            _ = try disclosure(in: host)
            XCTAssertFalse(hasExactSelectableText(row.displayValue, in: host))
            XCTAssertFalse(window.isVisible)
            XCTAssertFalse(window.isKeyWindow)
        }
    }

    private func disclosure(in view: NSView) throws -> NSButton {
        let buttons = nativeButtons(in: view)
        return try XCTUnwrap(
            buttons.count == 1 ? buttons.first : nil,
            "Expected exactly one native production disclosure, found \(buttons.count)"
        )
    }

    private func nativeButtons(in root: NSView) -> [NSButton] {
        root.subviews.flatMap { child in
            let descendants = nativeButtons(in: child)
            guard let button = child as? NSButton else { return descendants }
            return [button] + descendants
        }
    }

    private func hasExactSelectableText(_ expected: String, in root: NSView) -> Bool {
        if let field = root as? NSTextField, field.isSelectable, field.stringValue == expected {
            return true
        }
        if let text = root as? NSTextView, text.isSelectable, text.string == expected {
            return true
        }
        return root.subviews.contains { hasExactSelectableText(expected, in: $0) }
    }

    private func assertNativeSelectionCopy(_ expected: String, in root: NSView, window: NSWindow) throws {
        let originalKeyWindow = NSApplication.shared.keyWindow
        let pasteboard = NSPasteboard.withUniqueName()
        defer {
            window.makeFirstResponder(nil)
            pasteboard.releaseGlobally()
        }
        let field = try XCTUnwrap(selectableField(matching: expected, in: root))
        field.selectText(nil)
        let editor = try XCTUnwrap(
            field.currentEditor() as? NSTextView,
            "Native selection must work in the hidden test window without requesting focus"
        )
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(window.isKeyWindow)
        XCTAssertTrue(NSApplication.shared.keyWindow === originalKeyWindow)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: expected.utf16.count))
        XCTAssertTrue(editor.writeSelection(to: pasteboard, types: editor.writablePasteboardTypes))
        let copied = try XCTUnwrap(pasteboard.string(forType: .string))
        XCTAssertEqual(Array(copied.utf8), Array(expected.utf8))
    }

    private func selectableField(matching expected: String, in root: NSView) -> NSTextField? {
        if let field = root as? NSTextField, field.isSelectable, field.stringValue == expected {
            return field
        }
        for child in root.subviews {
            if let field = selectableField(matching: expected, in: child) { return field }
        }
        return nil
    }

    private func settleLayout(in view: NSView) async {
        for _ in 0..<6 {
            view.layoutSubtreeIfNeeded()
            await Task.yield()
        }
        view.layoutSubtreeIfNeeded()
    }

    private func makeRefreshWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        return window
    }

    private final class RefreshState: ObservableObject {
        @Published var value: String
        @Published var revision = 0

        init(value: String) {
            self.value = value
        }
    }

    private struct RefreshFixture: View {
        @ObservedObject var state: RefreshState

        var body: some View {
            ScrollView {
                TorrentOverviewSectionView(section: TorrentOverviewSection(
                    title: "Torrent",
                    systemImage: "doc",
                    columns: [TorrentOverviewColumn(
                        id: "summary",
                        rows: [TorrentDetailRow("Status", state.revision == 0 ? "Seeding" : "Paused")]
                    )],
                    fullSpanRows: [TorrentDetailRow("Comment", state.value, isLongText: true)]
                ))
                .equatable()
                .textSelection(.enabled)
                .padding(12)
            }
        }
    }

    private final class Measurements {
        var card = CGRect.zero
        var following = CGRect.zero
    }
}
