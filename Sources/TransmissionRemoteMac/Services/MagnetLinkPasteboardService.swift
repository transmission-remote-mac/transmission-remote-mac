// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import AppKit
import Foundation

struct TorrentMagnetLink: Equatable, Sendable {
    let hashString: String
    let magnetLink: String
}

protocol MagnetLinkPasteboardWriting {
    func writePlainText(_ text: String) -> Bool
}

struct MagnetLinkPasteboardService {
    private let pasteboardWriter: any MagnetLinkPasteboardWriting

    init(pasteboard: NSPasteboard = .general) {
        pasteboardWriter = NSPasteboardMagnetLinkWriter(pasteboard: pasteboard)
    }

    init(pasteboardWriter: any MagnetLinkPasteboardWriting) {
        self.pasteboardWriter = pasteboardWriter
    }

    func copy(_ magnetLinks: [TorrentMagnetLink]) throws {
        guard !magnetLinks.isEmpty else {
            throw MagnetLinkPasteboardError.noMagnetLinks
        }
        let text = magnetLinks.map(\.magnetLink).joined(separator: "\n")
        guard pasteboardWriter.writePlainText(text) else {
            throw MagnetLinkPasteboardError.writeFailed
        }
    }
}

enum MagnetLinkPasteboardError: LocalizedError, Equatable {
    case noMagnetLinks
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .noMagnetLinks:
            "No magnet links are selected"
        case .writeFailed:
            "Unable to copy magnet links to the clipboard"
        }
    }
}

private struct NSPasteboardMagnetLinkWriter: MagnetLinkPasteboardWriting {
    let pasteboard: NSPasteboard

    func writePlainText(_ text: String) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }
}
