// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import AppKit
import Foundation

enum MappedDestinationBrowserResult: Equatable {
    case cancelled
    case selectedDaemonPath(String)
    case failed(MappedDestinationBrowserError)
}

enum MappedDestinationBrowserError: LocalizedError, Equatable {
    case noAvailableMappedDirectory
    case pathResolution(PathMappingResolutionError)
    case pathResolutionFailed

    var errorDescription: String? {
        switch self {
        case .noAvailableMappedDirectory:
            "None of this server's mapped local folders is available on this Mac."
        case .pathResolution(let error):
            error.localizedDescription
        case .pathResolutionFailed:
            "The selected folder could not be mapped to a server path."
        }
    }
}

struct MappedDestinationBrowserState: Equatable {
    var daemonDestination: String
    var errorMessage: String?

    func applying(_ result: MappedDestinationBrowserResult) -> MappedDestinationBrowserState {
        switch result {
        case .cancelled:
            self
        case .selectedDaemonPath(let daemonPath):
            MappedDestinationBrowserState(daemonDestination: daemonPath, errorMessage: nil)
        case .failed(let error):
            MappedDestinationBrowserState(
                daemonDestination: daemonDestination,
                errorMessage: error.localizedDescription
            )
        }
    }
}

protocol MappedDestinationBrowsing {
    @MainActor
    func browse(
        currentDaemonDestination: String?,
        mappings: [PathMapping]
    ) -> MappedDestinationBrowserResult
}

protocol LocalDirectoryChoosing {
    @MainActor
    func chooseDirectory(startingAt initialDirectory: URL) -> URL?
}

protocol LocalDirectoryInspecting {
    func isExistingDirectory(_ url: URL) -> Bool
}

struct MappedDestinationBrowser: MappedDestinationBrowsing {
    private let directoryChooser: any LocalDirectoryChoosing
    private let directoryInspector: any LocalDirectoryInspecting

    init(
        directoryChooser: any LocalDirectoryChoosing = OpenPanelLocalDirectoryChooser(),
        directoryInspector: any LocalDirectoryInspecting = FileManagerLocalDirectoryInspector()
    ) {
        self.directoryChooser = directoryChooser
        self.directoryInspector = directoryInspector
    }

    @MainActor
    func browse(
        currentDaemonDestination: String?,
        mappings: [PathMapping]
    ) -> MappedDestinationBrowserResult {
        let planner = MappedDestinationBrowserPlanner(
            mappings: mappings,
            directoryInspector: directoryInspector
        )
        guard let initialDirectory = planner.initialDirectory(
            currentDaemonDestination: currentDaemonDestination
        ) else {
            return .failed(.noAvailableMappedDirectory)
        }
        guard let selectedDirectory = directoryChooser.chooseDirectory(startingAt: initialDirectory) else {
            return .cancelled
        }

        let accessedSecurityScope = selectedDirectory.startAccessingSecurityScopedResource()
        defer {
            if accessedSecurityScope {
                selectedDirectory.stopAccessingSecurityScopedResource()
            }
        }

        do {
            return .selectedDaemonPath(
                try PathMappingService(mappings: mappings)
                    .daemonPath(forLocalPath: selectedDirectory.path)
            )
        } catch let error as PathMappingResolutionError {
            return .failed(.pathResolution(error))
        } catch {
            return .failed(.pathResolutionFailed)
        }
    }
}

struct MappedDestinationBrowserPlanner {
    private let mappings: [PathMapping]
    private let directoryInspector: any LocalDirectoryInspecting

    init(
        mappings: [PathMapping],
        directoryInspector: any LocalDirectoryInspecting = FileManagerLocalDirectoryInspector()
    ) {
        self.mappings = mappings
        self.directoryInspector = directoryInspector
    }

    func initialDirectory(currentDaemonDestination: String?) -> URL? {
        let mappingService = PathMappingService(mappings: mappings)

        if
            let currentDaemonDestination,
            let mappedPath = mappingService.localPath(forDaemonPath: currentDaemonDestination),
            let mappedDirectory = standardizedAbsoluteURL(for: mappedPath),
            directoryInspector.isExistingDirectory(mappedDirectory)
        {
            return mappedDirectory
        }

        for mapping in mappings {
            guard
                let mappedRoot = mappingService.localPath(forDaemonPath: mapping.remotePathPrefix),
                let mappedDirectory = standardizedAbsoluteURL(for: mappedRoot),
                directoryInspector.isExistingDirectory(mappedDirectory)
            else {
                continue
            }
            return mappedDirectory
        }

        return nil
    }

    private func standardizedAbsoluteURL(for path: String) -> URL? {
        let expandedPath = (path as NSString).expandingTildeInPath
        guard expandedPath.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: expandedPath, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
    }
}

struct OpenPanelLocalDirectoryChooser: LocalDirectoryChoosing {
    @MainActor
    func chooseDirectory(startingAt initialDirectory: URL) -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose Download Folder"
        panel.prompt = "Choose"
        panel.directoryURL = initialDirectory
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.resolvesAliases = true
        return panel.runModal() == .OK ? panel.url : nil
    }
}

struct FileManagerLocalDirectoryInspector: LocalDirectoryInspecting {
    func isExistingDirectory(_ url: URL) -> Bool {
        var isDirectory = ObjCBool(false)
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}
