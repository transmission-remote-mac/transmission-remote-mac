// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import AppKit
import SwiftUI

/// Keep window/layout changes from resizing user-owned columns. SwiftUI's
/// customization binding remains the sole owner of widths and persistence.
struct TableColumnResizePolicyBridge: NSViewRepresentable {
    var widthsByTitle: [String: CGFloat] = [:]

    func makeNSView(context: Context) -> TableColumnResizePolicyView {
        let view = TableColumnResizePolicyView()
        view.widthsByTitle = widthsByTitle
        return view
    }

    func updateNSView(_ view: TableColumnResizePolicyView, context: Context) {
        view.update(widthsByTitle: widthsByTitle)
    }
}

final class TableColumnResizePolicyView: NSView {
    var widthsByTitle: [String: CGFloat] = [:]
    private weak var table: NSTableView?
    private var restoredColumns = Set<ObjectIdentifier>()

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        table = nil
        restoredColumns.removeAll()
        applyPolicy()
        DispatchQueue.main.async { [weak self] in self?.applyPolicy() }
    }

    override func layout() {
        super.layout()
        applyPolicy()
    }

    func update(widthsByTitle: [String: CGFloat]) {
        // Freeze the pre-mount snapshot until the native table is restored;
        // startup layout can publish adjusted widths before attachment finishes.
        if table != nil { self.widthsByTitle = widthsByTitle }
        applyPolicy()
    }

    func applyPolicy() {
        guard window != nil else { return }
        if let table, table.window === window {
            table.columnAutoresizingStyle = .noColumnAutoresizing
            restoreWidths(in: table)
            return
        }
        table = nil
        var ancestor = superview
        while let container = ancestor {
            if let found = Self.findTable(in: container) {
                table = found
                found.columnAutoresizingStyle = .noColumnAutoresizing
                restoreWidths(in: found)
                return
            }
            ancestor = container.superview
        }
    }

    private func restoreWidths(in table: NSTableView) {
        for column in table.tableColumns {
            guard let width = widthsByTitle[column.headerCell.stringValue],
                  restoredColumns.insert(ObjectIdentifier(column)).inserted else { continue }
            let previous = column.width
            guard abs(previous - width) > 0.01 else { continue }
            column.width = width
            NotificationCenter.default.post(
                name: NSTableView.columnDidResizeNotification,
                object: table,
                userInfo: ["NSTableColumn": column, "NSOldWidth": previous]
            )
        }
    }

    private static func findTable(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for child in view.subviews {
            if let table = findTable(in: child) { return table }
        }
        return nil
    }
}
