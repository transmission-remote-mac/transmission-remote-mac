// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import AppKit

@MainActor
protocol TorrentOperationPrompting {
    func requestLocation(
        defaultLocation: String,
        moveData: Bool,
        suggestions: [String]
    ) -> String?

    func requestRename(currentName: String) -> String?
}

@MainActor
struct NativeTorrentOperationPrompter: TorrentOperationPrompting {
    func requestLocation(
        defaultLocation: String,
        moveData: Bool,
        suggestions: [String]
    ) -> String? {
        requestText(
            title: moveData ? "Move Data" : "Set Location",
            message: moveData
                ? "Enter the daemon-visible destination folder. Transmission will move the selected torrent data there."
                : "Enter the daemon-visible folder that already contains the selected torrent data.",
            placeholder: "Daemon-visible folder",
            initialValue: defaultLocation,
            confirmTitle: moveData ? "Move" : "Set",
            suggestions: suggestions
        )
    }

    func requestRename(currentName: String) -> String? {
        requestText(
            title: "Rename Torrent",
            message: "Enter the new torrent name. This uses Transmission RPC torrent-rename-path.",
            placeholder: "New name",
            initialValue: currentName,
            confirmTitle: "Rename",
            suggestions: []
        )
    }

    private func requestText(
        title: String,
        message: String,
        placeholder: String,
        initialValue: String,
        confirmTitle: String,
        suggestions: [String]
    ) -> String? {
        NSApplication.shared.activate(ignoringOtherApps: true)

        let textField: NSTextField
        if suggestions.isEmpty {
            textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 420, height: 24))
        } else {
            let comboBox = NSComboBox(frame: NSRect(x: 0, y: 0, width: 420, height: 26))
            comboBox.addItems(withObjectValues: suggestions)
            comboBox.completes = true
            textField = comboBox
        }
        textField.placeholderString = placeholder
        textField.stringValue = initialValue

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.accessoryView = textField
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return textField.stringValue
    }
}
