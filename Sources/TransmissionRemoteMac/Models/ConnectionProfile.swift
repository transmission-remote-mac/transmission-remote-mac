// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation

struct ConnectionProfile: Identifiable, Hashable, Codable {
    static let defaultPort = 9091
    static let defaultRPCPath = "/transmission/rpc"
    static let defaultRequestTimeoutSeconds = 30
    static let requestTimeoutSecondsRange = 1...300

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case scheme
        case host
        case port
        case rpcPath
        case username
        case pathMappings
        case askPasswordAtConnect
        case connectOnLaunch
        case autoReconnect
        case requestTimeoutSeconds
        case transferPreferences
        case proxySettings
        case clientIdentityMetadata
    }

    private enum LegacyCodingKeys: String, CodingKey {
        case password
    }

    var id: UUID
    var name: String
    var scheme: String
    var host: String
    var port: Int
    var rpcPath: String
    var username: String
    var password: String
    var pathMappings: [PathMapping]
    var askPasswordAtConnect: Bool
    var connectOnLaunch: Bool
    var autoReconnect: Bool
    var requestTimeoutSeconds: Int
    var transferPreferences: ProfileTransferPreferences
    var proxySettings: ProxySettings
    var proxyPassword: String
    var clientIdentityMetadata: ClientIdentityMetadata?
    var clientIdentityEditState: ClientIdentityEditState?

    init(
        id: UUID = UUID(),
        name: String,
        scheme: String = "http",
        host: String,
        port: Int = Self.defaultPort,
        rpcPath: String = Self.defaultRPCPath,
        username: String = "",
        password: String = "",
        pathMappings: [PathMapping] = [],
        askPasswordAtConnect: Bool = false,
        connectOnLaunch: Bool = true,
        autoReconnect: Bool = false,
        requestTimeoutSeconds: Int = Self.defaultRequestTimeoutSeconds,
        transferPreferences: ProfileTransferPreferences = .defaults,
        proxySettings: ProxySettings = .direct,
        proxyPassword: String = "",
        clientIdentityMetadata: ClientIdentityMetadata? = nil,
        clientIdentityEditState: ClientIdentityEditState? = nil
    ) {
        self.id = id
        self.name = name
        self.scheme = scheme
        self.host = host
        self.port = port
        self.rpcPath = rpcPath
        self.username = username
        self.password = password
        self.pathMappings = pathMappings
        self.askPasswordAtConnect = askPasswordAtConnect
        self.connectOnLaunch = connectOnLaunch
        self.autoReconnect = autoReconnect
        self.requestTimeoutSeconds = requestTimeoutSeconds
        self.transferPreferences = transferPreferences
        self.proxySettings = proxySettings
        self.proxyPassword = proxyPassword
        self.clientIdentityMetadata = clientIdentityMetadata
        self.clientIdentityEditState = clientIdentityEditState
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        scheme = try container.decode(String.self, forKey: .scheme)
        host = try container.decode(String.self, forKey: .host)
        port = try container.decode(Int.self, forKey: .port)
        rpcPath = try container.decode(String.self, forKey: .rpcPath)
        username = try container.decode(String.self, forKey: .username)
        pathMappings = try container.decodeIfPresent([PathMapping].self, forKey: .pathMappings) ?? []
        let legacyContainer = try decoder.container(keyedBy: LegacyCodingKeys.self)
        password = try legacyContainer.decodeIfPresent(String.self, forKey: .password) ?? ""
        askPasswordAtConnect = try container.decodeIfPresent(Bool.self, forKey: .askPasswordAtConnect) ?? false
        connectOnLaunch = try container.decodeIfPresent(Bool.self, forKey: .connectOnLaunch) ?? true
        autoReconnect = try container.decodeIfPresent(Bool.self, forKey: .autoReconnect) ?? false
        requestTimeoutSeconds = try container.decodeIfPresent(
            Int.self,
            forKey: .requestTimeoutSeconds
        ) ?? Self.defaultRequestTimeoutSeconds
        transferPreferences = (try? container.decodeIfPresent(
            ProfileTransferPreferences.self,
            forKey: .transferPreferences
        )) ?? .defaults
        proxySettings = try container.decodeIfPresent(
            ProxySettings.self,
            forKey: .proxySettings
        ) ?? .direct
        proxyPassword = ""
        clientIdentityMetadata = try container.decodeIfPresent(
            ClientIdentityMetadata.self,
            forKey: .clientIdentityMetadata
        )
        clientIdentityEditState = nil
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(scheme, forKey: .scheme)
        try container.encode(host, forKey: .host)
        try container.encode(port, forKey: .port)
        try container.encode(rpcPath, forKey: .rpcPath)
        try container.encode(username, forKey: .username)
        try container.encode(pathMappings, forKey: .pathMappings)
        try container.encode(askPasswordAtConnect, forKey: .askPasswordAtConnect)
        try container.encode(connectOnLaunch, forKey: .connectOnLaunch)
        try container.encode(autoReconnect, forKey: .autoReconnect)
        try container.encode(requestTimeoutSeconds, forKey: .requestTimeoutSeconds)
        try container.encode(transferPreferences, forKey: .transferPreferences)
        try container.encode(proxySettings, forKey: .proxySettings)
        try container.encodeIfPresent(effectiveClientIdentityMetadata, forKey: .clientIdentityMetadata)
    }

    var endpoint: URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = port
        components.path = Self.normalizedRPCPath(rpcPath)
        return components.url!
    }

    var effectiveClientIdentityMetadata: ClientIdentityMetadata? {
        effectiveClientIdentityMetadata(using: clientIdentityEditState?.snapshot)
    }

    var hasClientIdentity: Bool {
        let state = clientIdentityEditState?.snapshot
        if state?.pendingImport != nil {
            return true
        }
        if state?.removeOnApply == true {
            return false
        }
        return effectiveClientIdentityMetadata(using: state) != nil
    }

    var clientIdentityMetadataForTransport: ClientIdentityMetadata? {
        let state = clientIdentityEditState?.snapshot
        return state?.pendingImport == nil ? effectiveClientIdentityMetadata(using: state) : nil
    }

    func requiresConnectionRestart(comparedTo other: ConnectionProfile) -> Bool {
        let state = clientIdentityEditState?.snapshot
        let otherState = other.clientIdentityEditState?.snapshot
        return id != other.id
            || scheme != other.scheme
            || host != other.host
            || port != other.port
            || rpcPath != other.rpcPath
            || username != other.username
            || password != other.password
            || askPasswordAtConnect != other.askPasswordAtConnect
            || requestTimeoutSeconds != other.requestTimeoutSeconds
            || proxySettings != other.proxySettings
            || proxyPassword != other.proxyPassword
            || otherState?.pendingImport != nil
            || otherState?.removeOnApply == true
            || effectiveClientIdentityMetadata(using: state) != other.effectiveClientIdentityMetadata(using: otherState)
    }

    func normalized() throws -> ConnectionProfile {
        try Self.validated(
            id: id,
            name: name,
            scheme: scheme,
            host: host,
            port: port,
            rpcPath: rpcPath,
            username: username,
            password: password,
            pathMappings: pathMappings,
            askPasswordAtConnect: askPasswordAtConnect,
            connectOnLaunch: connectOnLaunch,
            autoReconnect: autoReconnect,
            requestTimeoutSeconds: requestTimeoutSeconds,
            transferPreferences: transferPreferences,
            proxySettings: proxySettings,
            proxyPassword: proxyPassword,
            clientIdentityMetadata: clientIdentityMetadata,
            clientIdentityEditState: clientIdentityEditState
        )
    }

    static func validated(
        id: UUID = UUID(),
        name: String,
        scheme: String = "http",
        host: String,
        port: Int = defaultPort,
        rpcPath: String = defaultRPCPath,
        username: String = "",
        password: String = "",
        pathMappings: [PathMapping] = [],
        askPasswordAtConnect: Bool = false,
        connectOnLaunch: Bool = true,
        autoReconnect: Bool = false,
        requestTimeoutSeconds: Int = defaultRequestTimeoutSeconds,
        transferPreferences: ProfileTransferPreferences = .defaults,
        proxySettings: ProxySettings = .direct,
        proxyPassword: String = "",
        clientIdentityMetadata: ClientIdentityMetadata? = nil,
        clientIdentityEditState: ClientIdentityEditState? = nil
    ) throws -> ConnectionProfile {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else {
            throw ConnectionProfileValidationError.nameRequired
        }

        let normalizedScheme = scheme.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalizedScheme == "http" || normalizedScheme == "https" else {
            throw ConnectionProfileValidationError.invalidScheme(scheme)
        }

        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedHost.isEmpty else {
            throw ConnectionProfileValidationError.hostRequired
        }
        guard Self.isValidHost(normalizedHost) else {
            throw ConnectionProfileValidationError.invalidHost(normalizedHost)
        }

        guard (1...65_535).contains(port) else {
            throw ConnectionProfileValidationError.portOutOfRange(port)
        }

        guard requestTimeoutSecondsRange.contains(requestTimeoutSeconds) else {
            throw ConnectionProfileValidationError.requestTimeoutOutOfRange(requestTimeoutSeconds)
        }

        let normalizedRPCPath = Self.normalizedRPCPath(rpcPath)
        guard Self.isValidRPCPath(normalizedRPCPath) else {
            throw ConnectionProfileValidationError.invalidRPCPath(rpcPath)
        }

        let normalizedPathMappings = try PathMapping.normalizedMappings(pathMappings)
        let normalizedProxySettings = try proxySettings.normalized()
        let identityState = clientIdentityEditState?.snapshot
        if let pendingImport = identityState?.pendingImport, !pendingImport.isValid {
            throw ConnectionProfileValidationError.invalidClientIdentityImport
        }
        let effectiveClientIdentityMetadata = identityState?.didApply == true
            ? identityState?.appliedMetadata
            : clientIdentityMetadata
        let hasClientIdentity = identityState?.pendingImport != nil
            || (identityState?.removeOnApply != true && effectiveClientIdentityMetadata != nil)
        guard !hasClientIdentity || normalizedScheme == "https" else {
            throw ConnectionProfileValidationError.clientIdentityRequiresHTTPS
        }

        return ConnectionProfile(
            id: id,
            name: normalizedName,
            scheme: normalizedScheme,
            host: normalizedHost,
            port: port,
            rpcPath: normalizedRPCPath,
            username: username,
            password: askPasswordAtConnect ? "" : password,
            pathMappings: normalizedPathMappings,
            askPasswordAtConnect: askPasswordAtConnect,
            connectOnLaunch: connectOnLaunch,
            autoReconnect: autoReconnect,
            requestTimeoutSeconds: requestTimeoutSeconds,
            transferPreferences: transferPreferences,
            proxySettings: normalizedProxySettings,
            proxyPassword: normalizedProxySettings.authenticationEnabled ? proxyPassword : "",
            clientIdentityMetadata: clientIdentityMetadata,
            clientIdentityEditState: clientIdentityEditState
        )
    }

    static func normalizedRPCPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return defaultRPCPath }
        return trimmed.hasPrefix("/") ? trimmed : "/" + trimmed
    }

    fileprivate func effectiveClientIdentityMetadata(
        using state: ClientIdentityEditState.Snapshot?
    ) -> ClientIdentityMetadata? {
        guard let state, state.didApply else {
            return clientIdentityMetadata
        }
        return state.appliedMetadata
    }

    private static func isValidHost(_ host: String) -> Bool {
        if host.rangeOfCharacter(from: .whitespacesAndNewlines) != nil { return false }
        if host.contains("://") || host.contains("/") || host.contains("?") || host.contains("#") { return false }

        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = defaultPort
        components.path = defaultRPCPath
        return components.url != nil
    }

    private static func isValidRPCPath(_ path: String) -> Bool {
        guard path.hasPrefix("/") else { return false }
        guard !path.contains("://") else { return false }
        guard path.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return false }

        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = defaultPort
        components.path = path
        return components.url != nil
    }

    static let localDefault = ConnectionProfile(
        name: "Localhost Transmission",
        host: "127.0.0.1"
    )
}

struct PathMapping: Hashable, Codable {
    var remotePathPrefix: String
    var localPathPrefix: String

    init(remotePathPrefix: String, localPathPrefix: String) {
        self.remotePathPrefix = remotePathPrefix
        self.localPathPrefix = localPathPrefix
    }

    func normalized() throws -> PathMapping {
        try Self.validated(remotePathPrefix: remotePathPrefix, localPathPrefix: localPathPrefix)
    }

    static func validated(remotePathPrefix: String, localPathPrefix: String) throws -> PathMapping {
        let normalizedRemotePathPrefix = normalizedRemotePath(remotePathPrefix)
        guard !normalizedRemotePathPrefix.isEmpty else {
            throw ConnectionProfileValidationError.pathMappingRemotePathRequired
        }

        let normalizedLocalPathPrefix = normalizedLocalPath(localPathPrefix)
        guard !normalizedLocalPathPrefix.isEmpty else {
            throw ConnectionProfileValidationError.pathMappingLocalPathRequired
        }
        guard normalizedLocalPathPrefix.hasPrefix("/") else {
            throw ConnectionProfileValidationError.pathMappingLocalPathMustBeAbsolute(
                normalizedLocalPathPrefix
            )
        }

        return PathMapping(
            remotePathPrefix: normalizedRemotePathPrefix,
            localPathPrefix: normalizedLocalPathPrefix
        )
    }

    static func normalizedMappings(_ mappings: [PathMapping]) throws -> [PathMapping] {
        let normalizedMappings = try mappings.map { try $0.normalized() }
        var remotePrefixes = Set<String>()
        for mapping in normalizedMappings {
            guard remotePrefixes.insert(mapping.remotePathPrefix).inserted else {
                throw ConnectionProfileValidationError.duplicatePathMappingRemotePath(mapping.remotePathPrefix)
            }
        }

        return normalizedMappings.sorted {
            if $0.remotePathPrefix == $1.remotePathPrefix {
                return $0.localPathPrefix.localizedStandardCompare($1.localPathPrefix) == .orderedAscending
            }
            return $0.remotePathPrefix.localizedStandardCompare($1.remotePathPrefix) == .orderedAscending
        }
    }

    static func normalizedRemotePath(_ path: String) -> String {
        normalizedPathPrefix(
            path.replacingOccurrences(of: "\\", with: "/"),
            trailingSeparator: "/"
        )
    }

    static func normalizedLocalPath(_ path: String) -> String {
        normalizedPathPrefix((path as NSString).expandingTildeInPath, trailingSeparator: "/")
    }

    private static func normalizedPathPrefix(_ path: String, trailingSeparator: Character) -> String {
        var normalized = path.trimmingCharacters(in: .whitespacesAndNewlines)
        while normalized.count > 1 && normalized.last == trailingSeparator {
            normalized.removeLast()
        }
        return normalized
    }
}

struct ConnectionProfileDraft: Equatable {
    var id: UUID {
        didSet {
            guard id != oldValue else { return }
            clientIdentityMetadata = nil
            pendingClientIdentityImport = nil
            removeClientIdentityOnApply = false
        }
    }
    var name: String
    var scheme: String
    var host: String
    var port: String
    var rpcPath: String
    var username: String
    var password: String
    var pathMappings: [PathMappingDraft]
    var askPasswordAtConnect: Bool
    var connectOnLaunch: Bool
    var autoReconnect: Bool
    var requestTimeoutSeconds: String
    var transferPreferences: ProfileTransferPreferences
    var proxySettings: ProxySettings
    var proxyPassword: String
    var clientIdentityMetadata: ClientIdentityMetadata?
    var pendingClientIdentityImport: PendingClientIdentityImport?
    var removeClientIdentityOnApply: Bool

    init(profile: ConnectionProfile = .localDefault) {
        id = profile.id
        name = profile.name
        scheme = profile.scheme
        host = profile.host
        port = String(profile.port)
        rpcPath = profile.rpcPath
        username = profile.username
        password = profile.password
        pathMappings = profile.pathMappings.map { PathMappingDraft(pathMapping: $0) }
        askPasswordAtConnect = profile.askPasswordAtConnect
        connectOnLaunch = profile.connectOnLaunch
        autoReconnect = profile.autoReconnect
        requestTimeoutSeconds = String(profile.requestTimeoutSeconds)
        transferPreferences = profile.transferPreferences
        proxySettings = profile.proxySettings
        proxyPassword = profile.proxyPassword
        let identityState = profile.clientIdentityEditState?.snapshot
        clientIdentityMetadata = profile.effectiveClientIdentityMetadata(using: identityState)
        pendingClientIdentityImport = identityState?.pendingImport
        removeClientIdentityOnApply = identityState?.removeOnApply ?? false
    }

    mutating func reset(to profile: ConnectionProfile) {
        self = ConnectionProfileDraft(profile: profile)
    }

    func validatedProfile() throws -> ConnectionProfile {
        let trimmedPort = port.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsedPort = Int(trimmedPort) else {
            throw ConnectionProfileValidationError.invalidPort(port)
        }
        let trimmedRequestTimeout = requestTimeoutSeconds.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsedRequestTimeout = Int(trimmedRequestTimeout) else {
            throw ConnectionProfileValidationError.invalidRequestTimeout(requestTimeoutSeconds)
        }
        let clientIdentityEditState: ClientIdentityEditState?
        if pendingClientIdentityImport != nil || removeClientIdentityOnApply {
            clientIdentityEditState = ClientIdentityEditState(
                pendingImport: pendingClientIdentityImport,
                removeOnApply: removeClientIdentityOnApply
            )
        } else {
            clientIdentityEditState = nil
        }

        return try ConnectionProfile.validated(
            id: id,
            name: name,
            scheme: scheme,
            host: host,
            port: parsedPort,
            rpcPath: rpcPath,
            username: username,
            password: password,
            pathMappings: pathMappings.map(\.pathMapping),
            askPasswordAtConnect: askPasswordAtConnect,
            connectOnLaunch: connectOnLaunch,
            autoReconnect: autoReconnect,
            requestTimeoutSeconds: parsedRequestTimeout,
            transferPreferences: transferPreferences,
            proxySettings: proxySettings,
            proxyPassword: proxyPassword,
            clientIdentityMetadata: clientIdentityMetadata,
            clientIdentityEditState: clientIdentityEditState
        )
    }

    mutating func stageClientIdentityImport(fileName: String, data: Data) {
        pendingClientIdentityImport = PendingClientIdentityImport(
            sourceFileName: fileName,
            pkcs12Data: data
        )
        removeClientIdentityOnApply = false
    }

    mutating func cancelPendingClientIdentityImport() {
        pendingClientIdentityImport = nil
    }

    mutating func removeClientIdentity() {
        pendingClientIdentityImport = nil
        removeClientIdentityOnApply = clientIdentityMetadata != nil
    }

    mutating func restoreClientIdentity() {
        removeClientIdentityOnApply = false
    }
}

struct PathMappingDraft: Equatable, Identifiable {
    let id: UUID
    var remotePathPrefix: String
    var localPathPrefix: String

    init(
        id: UUID = UUID(),
        remotePathPrefix: String = "",
        localPathPrefix: String = ""
    ) {
        self.id = id
        self.remotePathPrefix = remotePathPrefix
        self.localPathPrefix = localPathPrefix
    }

    init(pathMapping: PathMapping) {
        id = UUID()
        remotePathPrefix = pathMapping.remotePathPrefix
        localPathPrefix = pathMapping.localPathPrefix
    }

    var pathMapping: PathMapping {
        PathMapping(remotePathPrefix: remotePathPrefix, localPathPrefix: localPathPrefix)
    }
}

enum ConnectionProfileValidationError: LocalizedError, Equatable {
    case nameRequired
    case invalidScheme(String)
    case hostRequired
    case invalidHost(String)
    case invalidPort(String)
    case portOutOfRange(Int)
    case invalidRequestTimeout(String)
    case requestTimeoutOutOfRange(Int)
    case invalidRPCPath(String)
    case pathMappingRemotePathRequired
    case pathMappingLocalPathRequired
    case pathMappingLocalPathMustBeAbsolute(String)
    case duplicatePathMappingRemotePath(String)
    case clientIdentityRequiresHTTPS
    case invalidClientIdentityImport

    var errorDescription: String? {
        switch self {
        case .nameRequired: "Connection name is required"
        case .invalidScheme: "Connection scheme must be http or https"
        case .hostRequired: "Connection host is required"
        case .invalidHost(let host): "Connection host is invalid: \(host)"
        case .invalidPort(let port): "Connection port is invalid: \(port)"
        case .portOutOfRange(let port): "Connection port must be between 1 and 65535: \(port)"
        case .invalidRequestTimeout(let timeout): "Request timeout is invalid: \(timeout)"
        case .requestTimeoutOutOfRange(let timeout):
            "Request timeout must be between 1 and 300 seconds: \(timeout)"
        case .invalidRPCPath(let path): "RPC path is invalid: \(path)"
        case .pathMappingRemotePathRequired: "Path mapping remote path is required"
        case .pathMappingLocalPathRequired: "Path mapping local path is required"
        case .pathMappingLocalPathMustBeAbsolute(let path):
            "Path mapping local path must be absolute: \(path)"
        case .duplicatePathMappingRemotePath(let path): "Path mapping remote path is duplicated: \(path)"
        case .clientIdentityRequiresHTTPS: "Client certificate authentication requires an HTTPS server"
        case .invalidClientIdentityImport: "The selected PKCS#12 client identity is empty or too large"
        }
    }
}
