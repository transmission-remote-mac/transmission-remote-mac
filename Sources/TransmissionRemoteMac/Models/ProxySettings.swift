// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Darwin
import Foundation

enum ProxyTransport: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case direct
    case http
    case https
    case socks5

    var id: Self { self }

    var displayName: String {
        switch self {
        case .direct: "Direct"
        case .http: "HTTP"
        case .https: "HTTPS"
        case .socks5: "SOCKS 5"
        }
    }

    var defaultPort: Int {
        switch self {
        case .direct, .http: 8080
        case .https: 443
        case .socks5: 1080
        }
    }
}

struct ProxySettings: Codable, Hashable, Sendable {
    static let defaultPort = 8080
    static let direct = ProxySettings()

    var transport: ProxyTransport
    var host: String
    var port: Int
    var authenticationEnabled: Bool
    var username: String

    init(
        transport: ProxyTransport = .direct,
        host: String = "",
        port: Int = Self.defaultPort,
        authenticationEnabled: Bool = false,
        username: String = ""
    ) {
        self.transport = transport
        self.host = host
        self.port = port
        self.authenticationEnabled = authenticationEnabled
        self.username = username
    }

    func normalized() throws -> ProxySettings {
        try Self.validated(
            transport: transport,
            host: host,
            port: port,
            authenticationEnabled: authenticationEnabled,
            username: username
        )
    }

    static func validated(
        transport: ProxyTransport,
        host: String,
        port: Int,
        authenticationEnabled: Bool = false,
        username: String = ""
    ) throws -> ProxySettings {
        guard transport != .direct else { return .direct }

        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedHost.isEmpty else {
            throw ProxySettingsValidationError.hostRequired
        }
        guard let transportHost = normalizedTransportHost(normalizedHost) else {
            throw ProxySettingsValidationError.invalidHost(normalizedHost)
        }
        guard (1...65_535).contains(port) else {
            throw ProxySettingsValidationError.portOutOfRange(port)
        }

        let normalizedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !authenticationEnabled || !normalizedUsername.isEmpty else {
            throw ProxySettingsValidationError.usernameRequired
        }

        return ProxySettings(
            transport: transport,
            host: transportHost,
            port: port,
            authenticationEnabled: authenticationEnabled,
            username: authenticationEnabled ? normalizedUsername : ""
        )
    }

    private static func normalizedTransportHost(_ host: String) -> String? {
        guard host.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }
        guard !host.contains("://"),
              !host.contains("/"),
              !host.contains("\\"),
              !host.contains("@"),
              !host.contains("?"),
              !host.contains("#") else {
            return nil
        }

        if host.hasPrefix("[") || host.hasSuffix("]") {
            return normalizedIPv6Host(host)
        }

        guard !host.contains(":") else { return nil }
        guard hasValidLabelBoundaries(host) else { return nil }

        guard let components = URLComponents(string: "http://\(host):\(defaultPort)"),
              components.scheme == "http",
              components.user == nil,
              components.password == nil,
              components.port == defaultPort,
              components.path.isEmpty,
              components.query == nil,
              components.fragment == nil,
              let canonicalHost = components.url?.host(percentEncoded: false)?.lowercased(),
              isValidASCIIDNSName(canonicalHost) else {
            return nil
        }

        return canonicalHost
    }

    private static func hasValidLabelBoundaries(_ host: String) -> Bool {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        return labels.allSatisfy { label in
            guard let first = label.first, let last = label.last else { return false }
            return first != "-" && last != "-"
        }
    }

    private static func isValidASCIIDNSName(_ host: String) -> Bool {
        guard !host.isEmpty, host.utf8.count <= 253 else { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        return labels.allSatisfy { label in
            guard !label.isEmpty, label.utf8.count <= 63 else { return false }
            guard label.first != "-", label.last != "-" else { return false }
            return label.utf8.allSatisfy { byte in
                (48...57).contains(byte)
                    || (97...122).contains(byte)
                    || byte == 45
            }
        }
    }

    private static func normalizedIPv6Host(_ host: String) -> String? {
        guard host.hasPrefix("["), host.hasSuffix("]") else { return nil }
        let literal = String(host.dropFirst().dropLast())
        guard !literal.isEmpty else { return nil }

        var address = in6_addr()
        guard literal.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else { return nil }

        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let converted = withUnsafePointer(to: &address) { addressPointer in
            buffer.withUnsafeMutableBufferPointer { bufferPointer in
                inet_ntop(
                    AF_INET6,
                    UnsafeRawPointer(addressPointer),
                    bufferPointer.baseAddress,
                    socklen_t(bufferPointer.count)
                )
            }
        }
        guard converted != nil else { return nil }

        return "[\(String(cString: buffer))]"
    }
}

enum ProxySettingsValidationError: LocalizedError, Equatable {
    case hostRequired
    case invalidHost(String)
    case portOutOfRange(Int)
    case usernameRequired

    var errorDescription: String? {
        switch self {
        case .hostRequired: "Proxy host is required"
        case .invalidHost(let host): "Proxy host is invalid: \(host)"
        case .portOutOfRange(let port): "Proxy port must be between 1 and 65535: \(port)"
        case .usernameRequired: "Proxy username is required when authentication is enabled"
        }
    }
}
