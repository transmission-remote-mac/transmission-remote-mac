// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation

/// Mapping roots are editable configuration; daemon and selected filesystem
/// paths retain significant whitespace in their components.
struct PathMappingService {
    private let mappingsByMatchPriority: [PathMapping]
    private let allowsUnmappedAbsolutePaths: Bool

    init(mappings: [PathMapping]) {
        self.init(
            mappings: mappings,
            allowsUnmappedAbsolutePaths: mappings.isEmpty
        )
    }

    init(profile: ConnectionProfile) {
        self.init(mappings: profile.pathMappings, host: profile.host)
    }

    init(mappings: [PathMapping], host: String) {
        self.init(
            mappings: mappings,
            allowsUnmappedAbsolutePaths: Self.isLoopbackHost(host)
        )
    }

    func localPath(forDaemonPath daemonPath: String) -> String? {
        let normalizedDaemonPath = daemonPath.replacingOccurrences(of: "\\", with: "/")
        guard !normalizedDaemonPath.isEmpty else { return nil }

        for mapping in mappingsByMatchPriority {
            let remotePrefix = PathMapping.normalizedRemotePath(mapping.remotePathPrefix)
            guard let suffix = suffix(after: remotePrefix, in: normalizedDaemonPath) else { continue }

            let localPrefix = PathMapping.normalizedLocalPath(mapping.localPathPrefix)
            guard !localPrefix.isEmpty else { return nil }
            guard
                let standardizedPrefix = standardizedAbsolutePath(localPrefix),
                let standardizedPath = standardizedAbsolutePath(appending(suffix: suffix, to: localPrefix)),
                isSameOrDescendant(standardizedPath, of: standardizedPrefix)
            else {
                return nil
            }
            return standardizedPath
        }

        return nil
    }

    func resolvedLocalPath(forDaemonPath daemonPath: String) throws -> String {
        if let mappedPath = localPath(forDaemonPath: daemonPath) {
            return mappedPath
        }

        let fallbackPath = daemonPath
        guard !fallbackPath.isEmpty else {
            throw PathMappingResolutionError.emptyDaemonPath
        }

        if fallbackPath.hasPrefix("/"), allowsUnmappedAbsolutePaths {
            return standardizedAbsolutePath(fallbackPath) ?? fallbackPath
        }

        if (fallbackPath == "~" || fallbackPath.hasPrefix("~/")), allowsUnmappedAbsolutePaths {
            let expandedPath = (fallbackPath as NSString).expandingTildeInPath
            return standardizedAbsolutePath(expandedPath) ?? expandedPath
        }

        throw PathMappingResolutionError.noMappingForNonLocalPath(daemonPath)
    }

    func daemonPath(forLocalPath localPath: String) throws -> String {
        guard !localPath.isEmpty else {
            throw PathMappingResolutionError.emptyLocalPath
        }
        guard let standardizedLocalPath = standardizedAbsolutePath(localPath) else {
            throw PathMappingResolutionError.localPathMustBeAbsolute(localPath)
        }

        let matches = mappingsByMatchPriority.compactMap { mapping -> ReverseMappingMatch? in
            let localPrefix = PathMapping.normalizedLocalPath(mapping.localPathPrefix)
            guard
                !localPrefix.isEmpty,
                let standardizedPrefix = standardizedAbsolutePath(localPrefix),
                let relativeComponents = relativeComponents(
                    of: standardizedLocalPath,
                    beneath: standardizedPrefix
                )
            else {
                return nil
            }

            let remotePrefix = PathMapping.normalizedRemotePath(mapping.remotePathPrefix)
            guard !remotePrefix.isEmpty else { return nil }

            return ReverseMappingMatch(
                localPrefixComponentCount: pathComponents(of: standardizedPrefix).count,
                daemonPath: appendingDaemonPath(
                    components: relativeComponents,
                    to: remotePrefix
                )
            )
        }

        guard let greatestSpecificity = matches.map(\.localPrefixComponentCount).max() else {
            throw PathMappingResolutionError.noMappingForLocalPath(localPath)
        }

        let daemonPaths = Array(
            Set(
                matches
                    .filter { $0.localPrefixComponentCount == greatestSpecificity }
                    .map(\.daemonPath)
            )
        ).sorted()

        guard daemonPaths.count == 1, let daemonPath = daemonPaths.first else {
            throw PathMappingResolutionError.ambiguousLocalPath(
                localPath,
                daemonPaths: daemonPaths
            )
        }
        return daemonPath
    }

    private init(mappings: [PathMapping], allowsUnmappedAbsolutePaths: Bool) {
        mappingsByMatchPriority = mappings.sorted {
            if $0.remotePathPrefix.count == $1.remotePathPrefix.count {
                return $0.remotePathPrefix.localizedStandardCompare($1.remotePathPrefix) == .orderedAscending
            }
            return $0.remotePathPrefix.count > $1.remotePathPrefix.count
        }
        self.allowsUnmappedAbsolutePaths = allowsUnmappedAbsolutePaths
    }

    private func suffix(after remotePrefix: String, in daemonPath: String) -> String? {
        if remotePrefix == daemonPath {
            return ""
        }

        if remotePrefix == "/", daemonPath.hasPrefix("/") {
            return String(daemonPath.dropFirst())
        }

        let prefixWithSeparator = remotePrefix + "/"
        guard daemonPath.hasPrefix(prefixWithSeparator) else { return nil }
        return String(daemonPath.dropFirst(prefixWithSeparator.count))
    }

    private func appending(suffix: String, to localPrefix: String) -> String {
        guard !suffix.isEmpty else { return localPrefix }
        if localPrefix == "/" {
            return "/" + suffix
        }
        return localPrefix + "/" + suffix
    }

    private func appendingDaemonPath(components: [String], to remotePrefix: String) -> String {
        guard !components.isEmpty else { return remotePrefix }
        let suffix = components.joined(separator: "/")
        return remotePrefix == "/" ? "/" + suffix : remotePrefix + "/" + suffix
    }

    private func standardizedAbsolutePath(_ path: String) -> String? {
        let expandedPath = (path as NSString).expandingTildeInPath
        guard expandedPath.hasPrefix("/") else { return nil }
        let standardizedURL = URL(fileURLWithPath: expandedPath).standardizedFileURL
        var existingAncestor = standardizedURL
        var missingComponents: [String] = []

        while existingAncestor.path != "/",
              !FileManager.default.fileExists(atPath: existingAncestor.path) {
            missingComponents.insert(existingAncestor.lastPathComponent, at: 0)
            existingAncestor.deleteLastPathComponent()
        }

        let resolvedAncestor = existingAncestor.resolvingSymlinksInPath()
        return missingComponents.reduce(resolvedAncestor) { partialURL, component in
            partialURL.appendingPathComponent(component)
        }.standardizedFileURL.path
    }

    private func isSameOrDescendant(_ path: String, of prefix: String) -> Bool {
        path == prefix || (prefix == "/" ? path.hasPrefix("/") : path.hasPrefix(prefix + "/"))
    }

    private func relativeComponents(of path: String, beneath prefix: String) -> [String]? {
        let selectedComponents = pathComponents(of: path)
        let rootComponents = pathComponents(of: prefix)
        guard
            selectedComponents.count >= rootComponents.count,
            Array(selectedComponents.prefix(rootComponents.count)) == rootComponents
        else {
            return nil
        }
        return Array(selectedComponents.dropFirst(rootComponents.count))
    }

    private func pathComponents(of path: String) -> [String] {
        URL(fileURLWithPath: path).standardizedFileURL.pathComponents
    }

    private static func isLoopbackHost(_ host: String) -> Bool {
        ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host.lowercased())
    }
}

private struct ReverseMappingMatch {
    let localPrefixComponentCount: Int
    let daemonPath: String
}

enum PathMappingResolutionError: LocalizedError, Equatable {
    case emptyDaemonPath
    case noMappingForNonLocalPath(String)
    case emptyLocalPath
    case localPathMustBeAbsolute(String)
    case noMappingForLocalPath(String)
    case ambiguousLocalPath(String, daemonPaths: [String])

    var errorDescription: String? {
        switch self {
        case .emptyDaemonPath:
            "Torrent path is empty"
        case .noMappingForNonLocalPath(let path):
            "No local path mapping matches \(path). Add a server path mapping first."
        case .emptyLocalPath:
            "Selected local path is empty"
        case .localPathMustBeAbsolute(let path):
            "Selected local path must be absolute: \(path)"
        case .noMappingForLocalPath(let path):
            "No server path mapping contains \(path). Choose a folder inside a mapped local path."
        case .ambiguousLocalPath(let path, let daemonPaths):
            "Multiple server path mappings match \(path): \(daemonPaths.joined(separator: ", "))."
        }
    }
}
