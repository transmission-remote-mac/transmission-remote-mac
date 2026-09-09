// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation

enum TransmissionRPCEndpointRedirectPolicy {
    private static let maximumLocationLength = 2_048

    static func repairedEndpoint(currentEndpoint: URL, location: String?) -> URL? {
        guard isHTTPURL(currentEndpoint),
              let location = normalizedLocation(location),
              let destination = URL(string: location, relativeTo: currentEndpoint)?.absoluteURL,
              isHTTPURL(destination),
              hasSameOrigin(currentEndpoint, destination),
              let components = URLComponents(url: destination, resolvingAgainstBaseURL: false),
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              let repairedPath = repairedRPCPath(from: components.percentEncodedPath) else {
            return nil
        }

        guard var repairedComponents = URLComponents(
            url: currentEndpoint,
            resolvingAgainstBaseURL: false
        ) else {
            return nil
        }
        repairedComponents.percentEncodedPath = repairedPath
        guard let repairedEndpoint = repairedComponents.url,
              repairedEndpoint != currentEndpoint else {
            return nil
        }
        return repairedEndpoint
    }

    private static func normalizedLocation(_ location: String?) -> String? {
        guard let location else { return nil }
        let trimmed = location.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.utf8.count <= maximumLocationLength,
              trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              trimmed.rangeOfCharacter(from: .controlCharacters) == nil else {
            return nil
        }
        return trimmed
    }

    private static func repairedRPCPath(from redirectedPath: String) -> String? {
        guard redirectedPath.hasPrefix("/"),
              !redirectedPath.contains("\\") else {
            return nil
        }

        let lowercasedPath = redirectedPath.lowercased()
        guard !lowercasedPath.contains("%2f"),
              !lowercasedPath.contains("%5c"),
              !lowercasedPath.contains("%2e") else {
            return nil
        }

        if redirectedPath.hasSuffix("/web/") {
            return String(redirectedPath.dropLast(4)) + "rpc"
        }
        if redirectedPath.hasSuffix("/web") {
            return String(redirectedPath.dropLast(3)) + "rpc"
        }
        return nil
    }

    private static func isHTTPURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else {
            return false
        }
        return true
    }

    private static func hasSameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && effectivePort(lhs) == effectivePort(rhs)
    }

    private static func effectivePort(_ url: URL) -> Int? {
        if let port = url.port {
            return port
        }
        switch url.scheme?.lowercased() {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }
}
