// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import AppKit
import Foundation

/// Accepts resolved absolute filesystem paths, not editable path text.
/// Whitespace in a filename is significant and must reach the platform unchanged.
protocol LocalFileActionServicing {
    func copy(paths: [String]) throws
    func reveal(paths: [String]) throws
    func open(paths: [String]) throws
}

struct LocalFileActionService: LocalFileActionServicing {
    private let clipboardWriter: any LocalFileActionClipboardWriting
    private let workspaceOpener: any LocalFileActionWorkspaceOpening
    private let fileChecker: any LocalFileActionFileChecking

    init(
        pasteboard: NSPasteboard = .general,
        workspace: NSWorkspace = .shared,
        fileManager: FileManager = .default
    ) {
        self.init(
            clipboardWriter: NSPasteboardLocalFileActionClipboardWriter(pasteboard: pasteboard),
            workspaceOpener: NSWorkspaceLocalFileActionWorkspaceOpener(workspace: workspace),
            fileChecker: fileManager
        )
    }

    init(
        clipboardWriter: any LocalFileActionClipboardWriting,
        workspaceOpener: any LocalFileActionWorkspaceOpening,
        fileChecker: any LocalFileActionFileChecking
    ) {
        self.clipboardWriter = clipboardWriter
        self.workspaceOpener = workspaceOpener
        self.fileChecker = fileChecker
    }

    func copy(paths: [String]) throws {
        let validatedPaths = try validatedLocalPaths(paths)
        guard clipboardWriter.writePlainText(validatedPaths.joined(separator: "\n")) else {
            throw LocalFileActionError.copyFailed
        }
    }

    func reveal(paths: [String]) throws {
        let urls = try existingFileURLs(for: paths)
        workspaceOpener.reveal(urls: urls)
    }

    func open(paths: [String]) throws {
        let urls = try existingFileURLs(for: paths)
        for url in urls {
            guard workspaceOpener.open(url: url) else {
                throw LocalFileActionError.openFailed(url.path)
            }
        }
    }

    private func existingFileURLs(for paths: [String]) throws -> [URL] {
        try validatedLocalPaths(paths).map { path in
            guard fileChecker.fileExists(atPath: path) else {
                throw LocalFileActionError.pathMissing(path)
            }
            return URL(fileURLWithPath: path)
        }
    }

    private func validatedLocalPaths(_ paths: [String]) throws -> [String] {
        let nonemptyPaths = paths.filter { !$0.isEmpty }

        guard !nonemptyPaths.isEmpty else {
            throw LocalFileActionError.noPaths
        }

        if let invalidPath = nonemptyPaths.first(where: { !$0.hasPrefix("/") }) {
            throw LocalFileActionError.invalidLocalPath(invalidPath)
        }

        return nonemptyPaths
    }
}

enum LocalFileActionError: LocalizedError, Equatable {
    case noPaths
    case copyFailed
    case invalidLocalPath(String)
    case pathMissing(String)
    case openFailed(String)

    var errorDescription: String? {
        switch self {
        case .noPaths:
            "No local file path is selected"
        case .copyFailed:
            "Unable to copy local path to the clipboard"
        case .invalidLocalPath(let path):
            "Local path must be absolute: \(path)"
        case .pathMissing(let path):
            "Local path does not exist: \(path)"
        case .openFailed(let path):
            "Unable to open local path: \(path)"
        }
    }
}

protocol LocalFileActionClipboardWriting {
    func writePlainText(_ text: String) -> Bool
}

protocol LocalFileActionWorkspaceOpening {
    func reveal(urls: [URL])
    func open(url: URL) -> Bool
}

protocol LocalFileActionFileChecking {
    func fileExists(atPath path: String) -> Bool
}

extension FileManager: LocalFileActionFileChecking {}

private struct NSPasteboardLocalFileActionClipboardWriter: LocalFileActionClipboardWriting {
    let pasteboard: NSPasteboard

    func writePlainText(_ text: String) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }
}

private struct NSWorkspaceLocalFileActionWorkspaceOpener: LocalFileActionWorkspaceOpening {
    let workspace: NSWorkspace

    func reveal(urls: [URL]) {
        workspace.activateFileViewerSelecting(urls)
    }

    func open(url: URL) -> Bool {
        workspace.open(url)
    }
}
