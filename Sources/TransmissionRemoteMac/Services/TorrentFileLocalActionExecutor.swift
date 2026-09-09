// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation

enum TorrentFileLocalAction: Sendable {
    case open
    case reveal
    case copyPath
}

struct TorrentFileLocalActionExecutor {
    let mapping: TorrentFileLocalActionMapping
    private let pathResolver: TorrentFileLocalPathResolver
    private let localFileActionService: any LocalFileActionServicing

    init(
        profile: ConnectionProfile,
        localFileActionService: any LocalFileActionServicing = LocalFileActionService()
    ) {
        mapping = TorrentFileLocalActionMapping(profile: profile)
        pathResolver = TorrentFileLocalPathResolver(mapping: mapping)
        self.localFileActionService = localFileActionService
    }

    func perform(_ action: TorrentFileLocalAction, downloadDirectory: String, node: TorrentFileNode) throws {
        let path = try pathResolver.localPath(downloadDirectory: downloadDirectory, node: node)
        switch action {
        case .open:
            try localFileActionService.open(paths: [path])
        case .reveal:
            try localFileActionService.reveal(paths: [path])
        case .copyPath:
            try localFileActionService.copy(paths: [path])
        }
    }

    func copyPaths(downloadDirectory: String, nodes: [TorrentFileNode]) throws {
        let paths = try pathResolver.localPaths(downloadDirectory: downloadDirectory, nodes: nodes)
        try localFileActionService.copy(paths: paths)
    }
}

/// Filesystem-only resolution shared by background capability checks and the
/// execution-time guard. It never captures AppKit workspace or clipboard objects.
struct TorrentFileLocalPathResolver {
    private let pathMappingService: PathMappingService

    init(mapping: TorrentFileLocalActionMapping) {
        pathMappingService = PathMappingService(
            mappings: mapping.pathMappings,
            host: mapping.host
        )
    }

    func validate(downloadDirectory: String, nodes: [TorrentFileNode]) throws -> Bool {
        try Task.checkCancellation()
        let rootURL = try resolvedDownloadRootURL(downloadDirectory)
        for node in nodes {
            try Task.checkCancellation()
            _ = try localPath(resolvedDownloadRootURL: rootURL, node: node)
        }
        return true
    }

    /// Pure lexical eligibility for menu construction. It deliberately cannot
    /// authorize an action: filesystem and symlink checks remain in localPath.
    static func hasSafeRelativePath(_ node: TorrentFileNode) -> Bool {
        (try? validatedRelativeComponents(for: node)) != nil
    }

    func localPaths(downloadDirectory: String, nodes: [TorrentFileNode]) throws -> [String] {
        let rootURL = try resolvedDownloadRootURL(downloadDirectory)
        return try nodes.map {
            try localPath(resolvedDownloadRootURL: rootURL, node: $0)
        }
    }

    func localPath(downloadDirectory: String, node: TorrentFileNode) throws -> String {
        try localPath(
            resolvedDownloadRootURL: resolvedDownloadRootURL(downloadDirectory),
            node: node
        )
    }

    private func resolvedDownloadRootURL(_ downloadDirectory: String) throws -> URL {
        let resolvedDownloadRoot = try pathMappingService.resolvedLocalPath(
            forDaemonPath: downloadDirectory
        )
        return Self.resolvedFileURL(for: resolvedDownloadRoot)
    }

    private func localPath(resolvedDownloadRootURL: URL, node: TorrentFileNode) throws -> String {
        let relativeComponents = try Self.validatedRelativeComponents(for: node)
        let targetURL = try relativeComponents.reduce(resolvedDownloadRootURL) { url, component in
            try Task.checkCancellation()
            return url.appendingPathComponent(component, isDirectory: false)
                .standardizedFileURL
                .resolvingSymlinksInPath()
        }

        guard Self.isSameOrDescendant(targetURL, of: resolvedDownloadRootURL) else {
            throw TorrentFileLocalActionError.outsideDownloadDirectory(targetURL.path)
        }
        return targetURL.path
    }

    private static func validatedRelativeComponents(for node: TorrentFileNode) throws -> [String] {
        let normalizedParentPath = node.path.replacingOccurrences(of: "\\", with: "/")
        let normalizedName = node.name.replacingOccurrences(of: "\\", with: "/")

        if
            normalizedName.isEmpty
                || normalizedParentPath.hasPrefix("/")
                || normalizedName.hasPrefix("/")
        {
            throw TorrentFileLocalActionError.invalidRelativePath(relativePath(for: node))
        }

        var components: [Substring] = []
        if !normalizedParentPath.isEmpty {
            components.append(
                contentsOf: normalizedParentPath.split(
                    separator: "/",
                    omittingEmptySubsequences: false
                )
            )
        }
        components.append(
            contentsOf: normalizedName.split(
                separator: "/",
                omittingEmptySubsequences: false
            )
        )

        guard
            !components.isEmpty,
            components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else {
            throw TorrentFileLocalActionError.invalidRelativePath(relativePath(for: node))
        }
        return components.map(String.init)
    }

    private static func resolvedFileURL(for path: String) -> URL {
        URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
    }

    private static func isSameOrDescendant(_ targetURL: URL, of rootURL: URL) -> Bool {
        let targetPath = targetURL.path
        let rootPath = rootURL.path
        return targetPath == rootPath
            || (rootPath == "/" ? targetPath.hasPrefix("/") : targetPath.hasPrefix(rootPath + "/"))
    }

    private static func relativePath(for node: TorrentFileNode) -> String {
        node.path.isEmpty ? node.name : "\(node.path)/\(node.name)"
    }
}

enum TorrentFileLocalActionError: LocalizedError, Equatable {
    case invalidRelativePath(String)
    case outsideDownloadDirectory(String)

    var errorDescription: String? {
        switch self {
        case .invalidRelativePath(let path):
            "Torrent file path is not a safe relative path: \(path)"
        case .outsideDownloadDirectory(let path):
            "Torrent file path resolves outside the local download folder: \(path)"
        }
    }
}
