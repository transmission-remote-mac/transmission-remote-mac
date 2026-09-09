// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation

enum TransmissionRPCError: LocalizedError {
    case invalidResponse
    case httpStatus(Int, String)
    case rpcFailure(String)
    case rpcFailureWithArguments(String, RPCArguments)
    case missingSessionID
    case sessionIDRejected
    case missingArguments
    case invalidArguments
    case connectionFailed(String)
    case malformedJSON
    case unsupportedRPCVersion(feature: String, required: Int, actual: Int)
    case torrentNotFound(Int)
    case missingMagnetLinks([String])

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "Invalid server response"
        case .httpStatus(let status, let message): Self.httpStatusDescription(status: status, message: message)
        case .rpcFailure(let message): "Transmission RPC failed: \(Self.normalizedMessage(message, fallback: "Unknown error."))"
        case .rpcFailureWithArguments(let message, _):
            "Transmission RPC failed: \(Self.normalizedMessage(message, fallback: "Unknown error."))"
        case .missingSessionID: "Transmission session id was not returned"
        case .sessionIDRejected: "Transmission rejected the session id after retry"
        case .missingArguments: "RPC arguments object was not returned"
        case .invalidArguments: "RPC arguments value was not an object"
        case .connectionFailed(let message): "Could not connect to Transmission: \(message)"
        case .malformedJSON: "Invalid server response: malformed JSON"
        case .unsupportedRPCVersion(let feature, let required, let actual):
            "\(feature) requires Transmission RPC \(required) or newer. Server RPC version is \(actual)."
        case .torrentNotFound(let id): "Torrent \(id) is no longer available."
        case .missingMagnetLinks(let hashes):
            hashes.count == 1
                ? "Transmission did not return a magnet link for the selected torrent."
                : "Transmission did not return magnet links for \(hashes.count) selected torrents."
        }
    }

    private static func httpStatusDescription(status: Int, message: String) -> String {
        let detail = normalizedMessage(message, fallback: "")
        let prefix = switch status {
        case 401:
            "Authentication failed (HTTP 401)"
        case 403:
            "Access denied by Transmission (HTTP 403)"
        case 407:
            "Proxy authentication failed (HTTP 407)"
        case 404:
            "Transmission RPC endpoint not found (HTTP 404)"
        default:
            "HTTP \(status)"
        }
        return detail.isEmpty ? prefix : "\(prefix): \(detail)"
    }

    private static func normalizedMessage(_ message: String, fallback: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }
}

actor TransmissionRPCClient {
    enum BandwidthPriority: Int, Sendable {
        case low = -1
        case normal = 0
        case high = 1
    }

    private enum RecentlyActiveSupport: Equatable {
        case unknown
        case supported
        case unsupported
    }

    private let profile: ConnectionProfile
    private let urlSession: URLSession
    private let diagnostics: RPCDiagnostics
    private let clientIdentityCredentialResolver: any ClientIdentityCredentialResolving
    private var endpoint: URL
    private var sessionID: String?
    private var rpcVersion = 0
    private var wireProtocol: RPCWireProtocol = .legacy
    private var nextRequestID = 1
    private var recentlyActiveSupport: RecentlyActiveSupport = .unknown

    init(
        profile: ConnectionProfile,
        urlSession: URLSession? = nil,
        diagnostics: RPCDiagnostics = .shared,
        clientIdentityCredentialResolver: any ClientIdentityCredentialResolving = KeychainClientIdentityCredentialResolver()
    ) {
        self.profile = profile
        self.urlSession = urlSession ?? ConnectionProfileURLSessionTransport.makeSession(for: profile)
        self.diagnostics = diagnostics
        self.clientIdentityCredentialResolver = clientIdentityCredentialResolver
        endpoint = profile.endpoint
    }

    func connect() async throws -> Int {
        let session = try await getSession()
        return session.rpcVersion
    }

    func getSession() async throws -> SessionInfo {
        let arguments = try await send(RPCRequest(method: "session-get"))
        let session = SessionInfo(arguments: arguments)
        rpcVersion = session.rpcVersion
        return session
    }

    func getSessionStats() async throws -> SessionStats {
        SessionStats(arguments: try await send(RPCRequest(method: "session-stats")))
    }

    func freeSpace(path: String, rpcVersion overrideRPCVersion: Int? = nil) async throws -> Int64 {
        let activeRPCVersion = overrideRPCVersion ?? rpcVersion
        guard activeRPCVersion >= 15 else {
            throw TransmissionRPCError.unsupportedRPCVersion(
                feature: "Free space probe",
                required: 15,
                actual: activeRPCVersion
            )
        }
        guard let path = Self.normalizedActionText(path) else {
            throw TransmissionRPCError.invalidArguments
        }

        let arguments = try await send(RPCRequest(method: "free-space", arguments: [
            "path": .string(path)
        ]))
        guard let sizeBytes = arguments["size-bytes"]?.int64Value else {
            throw TransmissionRPCError.invalidArguments
        }
        return sizeBytes
    }

    func testPort(
        _ requestedProtocol: PortTestIPProtocol,
        rpcVersion overrideRPCVersion: Int? = nil
    ) async throws -> PortTestResult {
        let activeRPCVersion = overrideRPCVersion ?? rpcVersion
        guard requestedProtocol.isSupported(rpcVersion: activeRPCVersion) else {
            let requiredVersion = requestedProtocol == .automatic ? 5 : 18
            throw TransmissionRPCError.unsupportedRPCVersion(
                feature: requestedProtocol == .automatic ? "Port test" : "Protocol-specific port test",
                required: requiredVersion,
                actual: activeRPCVersion
            )
        }

        var requestArguments: RPCArguments = [:]
        if let protocolArgument = requestedProtocol.rpcArgumentValue {
            requestArguments["ip-protocol"] = .string(protocolArgument)
        }
        let response = try await send(
            RPCRequest(method: "port-test", arguments: requestArguments)
        )
        return try PortTestResult(requestedProtocol: requestedProtocol, arguments: response)
    }

    func updateBlocklist(rpcVersion overrideRPCVersion: Int? = nil) async throws -> BlocklistUpdateResult {
        let activeRPCVersion = overrideRPCVersion ?? rpcVersion
        guard activeRPCVersion >= 5 else {
            throw TransmissionRPCError.unsupportedRPCVersion(
                feature: "Blocklist update",
                required: 5,
                actual: activeRPCVersion
            )
        }
        let response = try await send(
            RPCRequest(method: "blocklist-update"),
            timeoutInterval: 180
        )
        return try BlocklistUpdateResult(arguments: response)
    }

    func setDaemonOptions(_ update: DaemonOptionsUpdate, rpcVersion overrideRPCVersion: Int? = nil) async throws {
        let arguments = update.arguments(rpcVersion: overrideRPCVersion ?? rpcVersion)
        guard !arguments.isEmpty else { return }
        try await send(RPCRequest(method: "session-set", arguments: arguments), returnArguments: false)
    }

    func setAlternateSpeedEnabled(
        _ isEnabled: Bool,
        rpcVersion overrideRPCVersion: Int? = nil
    ) async throws {
        let activeRPCVersion = overrideRPCVersion ?? rpcVersion
        guard activeRPCVersion >= 5 else {
            throw TransmissionRPCError.unsupportedRPCVersion(
                feature: "Alternate speed",
                required: 5,
                actual: activeRPCVersion
            )
        }
        try await send(
            RPCRequest(method: "session-set", arguments: ["alt-speed-enabled": .bool(isEnabled)]),
            returnArguments: false
        )
    }

    func setSpeedLimit(
        direction: SessionSpeedLimitDirection,
        enabled: Bool,
        limitKBps: Int?
    ) async throws {
        var arguments: RPCArguments = [direction.enabledKey: .bool(enabled)]
        if rpcVersion >= 5 {
            arguments["alt-speed-enabled"] = .bool(false)
        }
        if enabled, let limitKBps {
            arguments[direction.limitKey] = .int(limitKBps)
        }
        try await send(RPCRequest(method: "session-set", arguments: arguments), returnArguments: false)
    }

    func getTorrents(
        mode: TorrentListFetchMode = .fullSnapshot,
        fieldPlan: TorrentListFieldPlan? = nil
    ) async throws -> TorrentGetResponse {
        let fieldPlan = fieldPlan ?? defaultTorrentListFieldPlan
        let fields = switch mode {
        case .fullSnapshot:
            fieldPlan.fullFields
        case .recentlyActive:
            fieldPlan.deltaFields
        case .targeted(_):
            fieldPlan.bootstrapFields
        }
        var arguments: RPCArguments = [
            "fields": .array(fields.map(JSONValue.string))
        ]
        switch mode {
        case .fullSnapshot:
            break
        case .recentlyActive:
            arguments["ids"] = .string("recently-active")
        case .targeted(let ids):
            arguments["ids"] = .array(Self.normalizedTorrentIDs(ids).map(JSONValue.int))
        }
        if rpcVersion >= 16 {
            arguments["format"] = .string("table")
        }
        return try TorrentGetResponse(
            validating: await send(RPCRequest(method: "torrent-get", arguments: arguments))
        )
    }

    func fetchTorrentList(
        mode requestedMode: TorrentListFetchMode,
        fieldPlan: TorrentListFieldPlan? = nil
    ) async throws -> TorrentListUpdate {
        let fieldPlan = fieldPlan ?? defaultTorrentListFieldPlan
        guard requestedMode == .recentlyActive else {
            return try await fetchTorrentListUpdate(mode: requestedMode, fieldPlan: fieldPlan)
        }
        guard recentlyActiveSupport != .unsupported else {
            return try await fetchTorrentListUpdate(mode: .fullSnapshot, fieldPlan: fieldPlan)
        }

        do {
            let update = try await fetchTorrentListUpdate(mode: .recentlyActive, fieldPlan: fieldPlan)
            recentlyActiveSupport = .supported
            return update
        } catch let error as TransmissionRPCError where Self.isRecentlyActiveRejection(error) {
            let fullSnapshot = try await fetchTorrentListUpdate(mode: .fullSnapshot, fieldPlan: fieldPlan)
            recentlyActiveSupport = .unsupported
            return fullSnapshot
        }
    }

    private func fetchTorrentListUpdate(
        mode: TorrentListFetchMode,
        fieldPlan: TorrentListFieldPlan
    ) async throws -> TorrentListUpdate {
        let response = try await getTorrents(mode: mode, fieldPlan: fieldPlan)
        return TorrentListUpdate(
            mode: mode,
            torrents: response.torrents,
            removedIDs: response.removedIDs,
            fieldPlanRevision: fieldPlan.revision
        )
    }

    nonisolated private static func isRecentlyActiveRejection(_ error: TransmissionRPCError) -> Bool {
        switch error {
        case .rpcFailure(let message), .rpcFailureWithArguments(let message, _):
            return isUnsupportedRecentlyActiveMessage(message)
        case .httpStatus(let statusCode, let message):
            return (statusCode == 400 || statusCode == 422)
                && isUnsupportedRecentlyActiveMessage(message)
        default:
            return false
        }
    }

    nonisolated private static func isUnsupportedRecentlyActiveMessage(_ message: String) -> Bool {
        let normalized = message
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
        guard !normalized.isEmpty else { return false }

        let namesSelector = normalized.contains("recently-active")
        let rejectsIDsArgument = normalized.contains("invalid argument")
            && normalized.contains("ids")
        let rejectsSelector = namesSelector
            && (normalized.contains("invalid")
                || normalized.contains("unsupported")
                || normalized.contains("unknown"))
        return rejectsIDsArgument || rejectsSelector
    }

    func fetchTorrentDetail(
        id: Int,
        pane: TorrentDetailPane,
        hash: String? = nil,
        overviewPlan: TorrentOverviewRequestPlan? = nil
    ) async throws -> TorrentDetail {
        let fields = pane == .overview
            ? overviewPlan?.fields ?? pane.rpcFields(rpcVersion: rpcVersion)
            : pane.rpcFields(rpcVersion: rpcVersion)
        return try await fetchTorrentDetail(id: id, hash: hash, fields: fields)
    }

    func fetchTorrentProperties(id: Int, hash: String) async throws -> TorrentPropertiesSnapshot {
        guard id > 0, let hash = CanonicalTransmissionTorrentHash.normalize(hash) else {
            throw TransmissionRPCError.invalidArguments
        }
        let arguments: RPCArguments = [
            "ids": .array([.string(hash)]),
            "fields": .array(torrentPropertiesFields.map(JSONValue.string))
        ]
        let response = try TorrentGetResponse(
            validating: await send(RPCRequest(method: "torrent-get", arguments: arguments))
        )
        guard let torrent = response.torrents.first else {
            throw TransmissionRPCError.torrentNotFound(id)
        }
        guard torrent.id == id, CanonicalTransmissionTorrentHash.normalize(torrent.hashString) == hash else {
            throw TransmissionRPCError.invalidArguments
        }
        return TorrentPropertiesSnapshot(torrent: torrent)
    }

    func fetchProvisionalTorrentMetadata(
        torrentHash: String
    ) async throws -> ProvisionalTorrentMetadataSnapshot? {
        guard let torrentHash = CanonicalTransmissionTorrentHash.normalize(torrentHash) else {
            throw TransmissionRPCError.invalidArguments
        }
        let fields = ["hashString", "id", "metadataPercentComplete", "name"]
        let response = try TorrentGetResponse(validating: await send(
            RPCRequest(method: "torrent-get", arguments: [
                "ids": .array([.string(torrentHash)]),
                "fields": .array(fields.map(JSONValue.string))
            ])
        ))
        guard let torrent = response.torrents.first else { return nil }
        guard
            torrent.id > 0,
            let returnedHash = CanonicalTransmissionTorrentHash.normalize(torrent.hashString),
            returnedHash == torrentHash
        else {
            throw TransmissionRPCError.invalidArguments
        }
        return ProvisionalTorrentMetadataSnapshot(
            torrentID: torrent.id,
            torrentHash: returnedHash,
            metadataPercentComplete: torrent.metadataPercentComplete ?? 0,
            rootName: Self.normalizedActionText(torrent.name)
        )
    }

    func fetchDuplicateTorrentTrackers(
        hashString: String?,
        id: Int?
    ) async throws -> TorrentDuplicateTrackerSnapshot? {
        let normalizedHash = TorrentDuplicateTrackerMerge.normalizedHash(hashString)
        let normalizedID = TorrentDuplicateTrackerMerge.normalizedTorrentID(id)

        if let normalizedHash {
            do {
                if let snapshot = try await fetchDuplicateTorrentTrackers(target: .hash(normalizedHash)) {
                    return snapshot
                }
            } catch let error as TransmissionRPCError {
                guard normalizedID != nil, case .rpcFailure = error else { throw error }
            }
        }

        guard let normalizedID else { return nil }
        return try await fetchDuplicateTorrentTrackers(target: .id(normalizedID))
    }

    func addDuplicateTorrentTrackers(
        _ announceURLs: [String],
        target: TorrentDuplicateTrackerTarget
    ) async throws {
        let normalizedTrackers = TorrentDuplicateTrackerMerge.normalizedTrackerURLs(announceURLs)
        guard !normalizedTrackers.isEmpty else { return }

        let arguments: RPCArguments = [
            "trackerAdd": .array(normalizedTrackers.map(JSONValue.string))
        ]
        switch target {
        case .hash(let hashString):
            guard let hashString = TorrentDuplicateTrackerMerge.normalizedHash(hashString) else {
                throw TorrentDuplicateTrackerMergeError.missingIdentity
            }
            try await setTrackerArguments(arguments, torrentIdentifier: .string(hashString))
        case .id(let id):
            guard let id = TorrentDuplicateTrackerMerge.normalizedTorrentID(id) else {
                throw TorrentDuplicateTrackerMergeError.missingIdentity
            }
            try await setTrackerArguments(arguments, torrentIdentifier: .int(id))
        }
    }

    func fetchMagnetLinks(
        hashes: [String],
        rpcVersion overrideRPCVersion: Int? = nil
    ) async throws -> [TorrentMagnetLink] {
        let activeRPCVersion = overrideRPCVersion ?? rpcVersion
        guard activeRPCVersion >= 7 else {
            throw TransmissionRPCError.unsupportedRPCVersion(
                feature: "Copy magnet links",
                required: 7,
                actual: activeRPCVersion
            )
        }
        let normalizedHashes = hashes.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !normalizedHashes.isEmpty else { return [] }
        guard normalizedHashes.allSatisfy({ !$0.isEmpty }) else {
            throw TransmissionRPCError.missingMagnetLinks(
                normalizedHashes.filter(\.isEmpty)
            )
        }

        let arguments: RPCArguments = [
            "ids": .array(normalizedHashes.map(JSONValue.string)),
            "fields": .array([.string("hashString"), .string("magnetLink")])
        ]
        let response = try TorrentGetResponse(
            validating: await send(RPCRequest(method: "torrent-get", arguments: arguments)),
            requiresTorrentIDs: false
        )
        let torrentsByHash = Dictionary(
            response.torrents.compactMap { torrent -> (String, TorrentGetTorrent)? in
                guard let hash = torrent.hashString?.trimmingCharacters(in: .whitespacesAndNewlines), !hash.isEmpty else {
                    return nil
                }
                return (hash, torrent)
            }
        ) { current, _ in current }
        var missingHashes: [String] = []
        var magnetLinks: [TorrentMagnetLink] = []

        for hash in normalizedHashes {
            guard
                let magnetLink = torrentsByHash[hash]?.magnetLink?.trimmingCharacters(in: .whitespacesAndNewlines),
                !magnetLink.isEmpty
            else {
                if !missingHashes.contains(hash) {
                    missingHashes.append(hash)
                }
                continue
            }
            magnetLinks.append(TorrentMagnetLink(hashString: hash, magnetLink: magnetLink))
        }

        guard missingHashes.isEmpty else {
            throw TransmissionRPCError.missingMagnetLinks(missingHashes)
        }
        return magnetLinks
    }

    private func fetchTorrentDetail(id: Int, hash: String?, fields: [String]) async throws -> TorrentDetail {
        let identifier: JSONValue
        if rpcVersion >= 5, let hash {
            guard let canonicalHash = CanonicalTransmissionTorrentHash.normalize(hash) else {
                throw TransmissionRPCError.invalidArguments
            }
            identifier = .string(canonicalHash)
        } else {
            identifier = .int(id)
        }
        let arguments: RPCArguments = [
            "ids": .array([identifier]),
            "fields": .array(supportedTorrentFields(fields).map(JSONValue.string))
        ]
        let response = try TorrentGetResponse(
            validating: await send(RPCRequest(method: "torrent-get", arguments: arguments))
        )
        guard let torrent = response.torrents.first else {
            throw TransmissionRPCError.torrentNotFound(id)
        }
        return TorrentDetail(torrent: torrent, rpcVersion: rpcVersion)
    }

    private func supportedTorrentFields(_ fields: [String]) -> [String] {
        Array(Set(fields.filter { field in
            rpcVersion < 7 || !Self.removedAfterRPC6TorrentFields.contains(field)
        })).sorted()
    }

    private func fetchDuplicateTorrentTrackers(
        target: TorrentDuplicateTrackerTarget
    ) async throws -> TorrentDuplicateTrackerSnapshot? {
        let identifier: JSONValue = switch target {
        case .hash(let hashString): .string(hashString)
        case .id(let id): .int(id)
        }
        let arguments: RPCArguments = [
            "ids": .array([identifier]),
            "fields": .array(["hashString", "id", "trackers"].map(JSONValue.string))
        ]
        let response: TorrentGetResponse
        do {
            response = try TorrentGetResponse(
                validating: await send(RPCRequest(method: "torrent-get", arguments: arguments))
            )
        } catch is TorrentGetResponseDecodingError {
            throw TransmissionRPCError.invalidArguments
        }
        guard let torrent = response.torrents.first else { return nil }
        guard
            let id = try TorrentDuplicateTrackerMerge.decodedTorrentID(torrent["id"]),
            let trackers = torrent.trackers
        else {
            throw TransmissionRPCError.invalidArguments
        }

        let announceURLs = try trackers.map { tracker -> String in
            guard
                let tracker = tracker.objectValue,
                let announceURL = tracker["announce"]?.stringValue
            else {
                throw TransmissionRPCError.invalidArguments
            }
            return announceURL
        }
        return TorrentDuplicateTrackerSnapshot(
            target: target,
            id: id,
            hashString: TorrentDuplicateTrackerMerge.normalizedHash(torrent.hashString),
            announceURLs: announceURLs
        )
    }

    func start(ids: [Int]? = nil) async throws {
        try await action(method: "torrent-start", ids: ids)
    }

    func startNow(ids: [Int]) async throws {
        try await action(method: "torrent-start-now", ids: ids)
    }

    func stop(ids: [Int]? = nil) async throws {
        try await action(method: "torrent-stop", ids: ids)
    }

    func verify(hashes: [String]) async throws {
        try await action(method: "torrent-verify", hashes: hashes)
    }

    func reannounce(ids: [Int]) async throws {
        try await action(method: "torrent-reannounce", ids: ids)
    }

    func queueMoveTop(ids: [Int]) async throws {
        try await action(method: "queue-move-top", ids: ids)
    }

    func queueMoveUp(ids: [Int]) async throws {
        try await action(method: "queue-move-up", ids: ids)
    }

    func queueMoveDown(ids: [Int]) async throws {
        try await action(method: "queue-move-down", ids: ids)
    }

    func queueMoveBottom(ids: [Int]) async throws {
        try await action(method: "queue-move-bottom", ids: ids)
    }

    func remove(hashes: [String], deleteLocalData: Bool) async throws {
        let normalizedHashes = hashes.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !normalizedHashes.isEmpty, normalizedHashes.allSatisfy({ !$0.isEmpty }) else { return }
        try await send(
            RPCRequest(method: "torrent-remove", arguments: [
                "ids": .array(normalizedHashes.map(JSONValue.string)),
                "delete-local-data": .bool(deleteLocalData)
            ]),
            returnArguments: false
        )
    }

    func setLocation(hashes: [String], location: String, moveData: Bool) async throws {
        try requireRPCVersion(6, feature: "Set torrent location")
        let location = try RemotePOSIXDestinationValidator.validated(location)
        try await action(method: "torrent-set-location", hashes: hashes, arguments: [
            "location": .string(location),
            "move": .bool(moveData)
        ])
    }

    func renamePath(hash: String, path: String, name: String) async throws {
        try requireRPCVersion(15, feature: "Rename torrent path")
        guard
            let path = Self.normalizedActionText(path),
            let name = Self.normalizedActionText(name)
        else {
            throw TransmissionRPCError.invalidArguments
        }
        try await action(method: "torrent-rename-path", hashes: [hash], arguments: [
            "path": .string(path),
            "name": .string(name)
        ])
    }

    func renamePath(_ request: TorrentPathRenameRequest) async throws {
        try requireRPCVersion(15, feature: "Rename torrent path")
        try await action(method: "torrent-rename-path", hashes: [request.torrentHash], arguments: [
            "path": .string(request.node.relativePath),
            "name": .string(request.newBasename)
        ])
    }

    func renameProvisionalTorrentRoot(
        torrentHash: String,
        originalRootName: String,
        newName: String,
        rpcVersion overrideRPCVersion: Int? = nil
    ) async throws {
        let activeRPCVersion = overrideRPCVersion ?? rpcVersion
        guard activeRPCVersion >= 15 else {
            throw TransmissionRPCError.unsupportedRPCVersion(
                feature: "Save As",
                required: 15,
                actual: activeRPCVersion
            )
        }
        guard
            let torrentHash = CanonicalTransmissionTorrentHash.normalize(torrentHash),
            let originalRootName = Self.normalizedActionText(originalRootName),
            let newName = Self.normalizedActionText(newName)
        else {
            throw TransmissionRPCError.invalidArguments
        }

        try await send(
            RPCRequest(method: "torrent-rename-path", arguments: [
                "ids": .array([.string(torrentHash)]),
                "path": .string(originalRootName),
                "name": .string(newName)
            ]),
            returnArguments: false
        )
    }

    func setBandwidthPriority(_ priority: BandwidthPriority, ids: [Int]) async throws {
        try await action(method: "torrent-set", ids: ids, arguments: [
            "bandwidthPriority": .int(priority.rawValue)
        ])
    }

    func setLabels(_ labels: [String], ids: [Int]) async throws {
        try await action(method: "torrent-set", ids: ids, arguments: [
            "labels": .array(Self.normalizedLabels(labels).map(JSONValue.string))
        ])
    }

    func setLabels(fromCommaSeparatedText text: String, ids: [Int]) async throws {
        try await setLabels(Self.labels(fromCommaSeparatedText: text), ids: ids)
    }

    func setTorrentProperties(
        update: TorrentPropertiesUpdate,
        hashes: [String],
        rpcVersion overrideRPCVersion: Int? = nil
    ) async throws {
        let arguments = update.arguments(rpcVersion: overrideRPCVersion ?? rpcVersion)
        guard !arguments.isEmpty else { return }
        try await action(method: "torrent-set", hashes: hashes, arguments: arguments)
    }

    func addTracker(announceURL: String, torrentHash: String) async throws {
        guard let announceURL = Self.normalizedActionText(announceURL) else {
            throw TransmissionRPCError.invalidArguments
        }
        try await setTrackerArguments(
            ["trackerAdd": .array([.string(announceURL)])],
            torrentHash: torrentHash
        )
    }

    func replaceTracker(id: Int, announceURL: String, torrentHash: String) async throws {
        guard id >= 0, let announceURL = Self.normalizedActionText(announceURL) else {
            throw TransmissionRPCError.invalidArguments
        }
        try await setTrackerArguments(
            ["trackerReplace": .array([.int(id), .string(announceURL)])],
            torrentHash: torrentHash
        )
    }

    func removeTrackers(ids: [Int], torrentHash: String) async throws {
        guard !ids.isEmpty, ids.allSatisfy({ $0 >= 0 }) else {
            throw TransmissionRPCError.invalidArguments
        }
        try await setTrackerArguments(
            ["trackerRemove": .array(ids.map(JSONValue.int))],
            torrentHash: torrentHash
        )
    }

    func setFileWanted(_ wanted: Bool, torrentID: Int, fileIndexes: [Int]) async throws {
        let normalizedFileIndexes = Self.normalizedFileIndexes(fileIndexes)
        guard !normalizedFileIndexes.isEmpty else { return }
        let key = wanted ? "files-wanted" : "files-unwanted"
        try await action(method: "torrent-set", ids: [torrentID], arguments: [
            key: .array(normalizedFileIndexes.map(JSONValue.int))
        ])
    }

    func setFilePriority(_ priority: TorrentFilePriority, torrentID: Int, fileIndexes: [Int]) async throws {
        let normalizedFileIndexes = Self.normalizedFileIndexes(fileIndexes)
        guard !normalizedFileIndexes.isEmpty else { return }
        try await action(method: "torrent-set", ids: [torrentID], arguments: [
            "files-wanted": .array(normalizedFileIndexes.map(JSONValue.int)),
            priority.rpcArgumentKey: .array(normalizedFileIndexes.map(JSONValue.int))
        ])
    }

    nonisolated static func labels(fromCommaSeparatedText text: String) -> [String] {
        normalizedLabels(text.split(separator: ",").map(String.init))
    }

    nonisolated private static func normalizedLabels(_ labels: [String]) -> [String] {
        labels
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    nonisolated private static func normalizedActionText(_ text: String) -> String? {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedText.isEmpty ? nil : trimmedText
    }

    nonisolated private static func normalizedFileIndexes(_ fileIndexes: [Int]) -> [Int] {
        Array(Set(fileIndexes.filter { $0 >= 0 })).sorted()
    }

    nonisolated private static func normalizedTorrentIDs(_ torrentIDs: [Int]) -> [Int] {
        Array(Set(torrentIDs.filter { $0 > 0 })).sorted()
    }

    func addTorrent(
        filename: String,
        startPaused: Bool?,
        downloadDirectory: String?,
        peerLimit: Int? = nil
    ) async throws -> TorrentAddResult {
        try Self.validateAddPeerLimit(peerLimit)
        var arguments: RPCArguments = [
            "filename": .string(filename)
        ]
        if let startPaused {
            arguments["paused"] = .bool(startPaused)
        }
        if let downloadDirectory = AddTorrentDestinationHistory.normalizedDestination(
            downloadDirectory
        ) {
            arguments["download-dir"] = .string(downloadDirectory)
        }
        if let peerLimit {
            arguments["peer-limit"] = .int(peerLimit)
        }
        return try await addTorrent(arguments: arguments)
    }

    func addTorrent(
        metainfo data: Data,
        startPaused: Bool?,
        downloadDirectory: String?,
        fileSelection: TorrentAddFileSelection? = nil,
        peerLimit: Int? = nil
    ) async throws -> TorrentAddResult {
        try Self.validateAddPeerLimit(peerLimit)
        var arguments: RPCArguments = [
            "metainfo": .string(data.base64EncodedString())
        ]
        if let startPaused {
            arguments["paused"] = .bool(startPaused)
        }
        if let downloadDirectory = AddTorrentDestinationHistory.normalizedDestination(
            downloadDirectory
        ) {
            arguments["download-dir"] = .string(downloadDirectory)
        }
        if let fileSelection {
            arguments.merge(Self.fileSelectionArguments(fileSelection)) { _, next in next }
        }
        if let peerLimit {
            arguments["peer-limit"] = .int(peerLimit)
        }
        return try await addTorrent(arguments: arguments)
    }

    nonisolated private static func validateAddPeerLimit(_ peerLimit: Int?) throws {
        guard let peerLimit else { return }
        guard AddTorrentPeerLimitParser.validRange.contains(peerLimit) else {
            throw TransmissionRPCError.invalidArguments
        }
    }

    nonisolated private static func fileSelectionArguments(_ selection: TorrentAddFileSelection) -> RPCArguments {
        [
            "files-wanted": .array(selection.filesWanted.map(JSONValue.int)),
            "files-unwanted": .array(selection.filesUnwanted.map(JSONValue.int)),
            "priority-high": .array(selection.priorityHigh.map(JSONValue.int)),
            "priority-normal": .array(selection.priorityNormal.map(JSONValue.int)),
            "priority-low": .array(selection.priorityLow.map(JSONValue.int))
        ]
    }

    private func addTorrent(arguments: RPCArguments) async throws -> TorrentAddResult {
        let response = try await send(RPCRequest(method: "torrent-add", arguments: arguments))
        // Some legacy daemons report `result: duplicate torrent` without an arguments object.
        // transgui hashes the exact raw bencoded `info` slice before looking that torrent up.
        // This client does not retain that byte slice, so guessing an identity here would risk
        // mutating the wrong torrent. Leave that response as an RPC failure until it can be
        // resolved from an exact metainfo info-hash.
        return try TorrentAddResult(arguments: response)
    }

    @discardableResult
    func send(
        _ request: RPCRequest,
        returnArguments: Bool = true,
        timeoutInterval: TimeInterval? = nil
    ) async throws -> RPCArguments {
        let requestedFieldCount = request.arguments["fields"]?.arrayValue?.count ?? 0
        let requestID = nextRequestID
        nextRequestID = nextRequestID == Int.max ? 1 : nextRequestID + 1
        var diagnostic = diagnostics.begin(
            method: request.method,
            requestedFieldCount: requestedFieldCount
        )

        do {
            var didRetrySessionChallenge = false
            var didRepairEndpoint = false
            var requestEndpoint = endpoint
            for _ in 0..<3 {
                let protocolForAttempt = wireProtocol
                let body = try RPCProtocolAdapter.encode(
                    request,
                    protocol: protocolForAttempt,
                    id: requestID
                )
                let attemptEndpoint = requestEndpoint
                let data: Data
                let response: URLResponse
                diagnostic.beginHTTPAttempt(requestBytes: body.count)
                let taskDelegate = ConnectionProfileURLSessionTransport.makeTaskDelegate(
                    for: profile,
                    clientIdentityCredentialResolver: clientIdentityCredentialResolver
                )
                do {
                    defer {
                        diagnostic.recordTransportMetrics(taskDelegate.metricsSnapshot())
                    }
                    (data, response) = try await urlSession.data(
                        for: urlRequest(
                            body: body,
                            endpoint: attemptEndpoint,
                            timeoutInterval: timeoutInterval
                        ),
                        delegate: taskDelegate
                    )
                    diagnostic.receiveResponse(bytes: data.count)
                } catch let error as TransmissionRPCError {
                    throw error
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as URLError where error.code == .cancelled {
                    throw CancellationError()
                } catch let error as URLError {
                    throw TransmissionRPCError.connectionFailed(
                        Self.connectionFailureMessage(for: error, endpoint: attemptEndpoint)
                    )
                } catch {
                    throw TransmissionRPCError.connectionFailed(error.localizedDescription)
                }

                guard let httpResponse = response as? HTTPURLResponse else {
                    throw TransmissionRPCError.invalidResponse
                }

                if httpResponse.statusCode == 301,
                   !didRepairEndpoint,
                   let repairedEndpoint = TransmissionRPCEndpointRedirectPolicy.repairedEndpoint(
                       currentEndpoint: attemptEndpoint,
                       location: httpResponse.value(forHTTPHeaderField: "Location")
                   ) {
                    requestEndpoint = repairedEndpoint
                    didRepairEndpoint = true
                    continue
                }

                if httpResponse.statusCode == 409 {
                    guard let nextSessionID = httpResponse.value(forHTTPHeaderField: "X-Transmission-Session-Id") else {
                        throw TransmissionRPCError.missingSessionID
                    }
                    sessionID = nextSessionID
                    if !didRetrySessionChallenge {
                        didRetrySessionChallenge = true
                        wireProtocol = RPCProtocolAdapter.wireProtocol(
                            challengeHeader: httpResponse.value(
                                forHTTPHeaderField: RPCProtocolAdapter.versionHeader
                            )
                        )
                        diagnostic.recordSessionChallengeRetry()
                        continue
                    }
                    throw TransmissionRPCError.sessionIDRejected
                }

                guard httpResponse.statusCode == 200 else {
                    let message = Self.httpErrorMessage(statusCode: httpResponse.statusCode, data: data)
                    throw TransmissionRPCError.httpStatus(httpResponse.statusCode, message)
                }

                let returnedArguments = try RPCProtocolAdapter.decode(
                    data,
                    for: request,
                    protocol: protocolForAttempt,
                    expectedID: requestID,
                    returnArguments: returnArguments
                )
                endpoint = requestEndpoint

                diagnostic.finish(
                    returnedTorrentRows: Self.returnedTorrentRows(
                        method: diagnostic.semanticMethod,
                        arguments: returnArguments ? returnedArguments : nil
                    )
                )
                return returnedArguments
            }

            throw TransmissionRPCError.missingSessionID
        } catch {
            diagnostic.finish(error: error)
            throw error
        }
    }

    nonisolated private static func returnedTorrentRows(
        method: RPCDiagnosticMethod,
        arguments: RPCArguments?
    ) -> Int? {
        guard method == .torrentGet, let arguments else { return nil }
        return TorrentGetResponse.wireRowCount(in: arguments)
    }

    private func action(method: String, ids: [Int]?, arguments: RPCArguments = [:]) async throws {
        var actionArguments = arguments
        if let ids {
            guard !ids.isEmpty else { return }
            actionArguments["ids"] = .array(ids.map(JSONValue.int))
        }
        try await send(RPCRequest(method: method, arguments: actionArguments), returnArguments: false)
    }

    private func action(method: String, hashes: [String], arguments: RPCArguments = [:]) async throws {
        var seen = Set<String>()
        var normalizedHashes: [String] = []
        normalizedHashes.reserveCapacity(hashes.count)
        for hash in hashes {
            guard let normalizedHash = CanonicalTransmissionTorrentHash.normalize(hash) else {
                throw TransmissionRPCError.invalidArguments
            }
            if seen.insert(normalizedHash).inserted {
                normalizedHashes.append(normalizedHash)
            }
        }
        guard !normalizedHashes.isEmpty else {
            throw TransmissionRPCError.invalidArguments
        }

        var actionArguments = arguments
        actionArguments["ids"] = .array(normalizedHashes.map(JSONValue.string))
        try await send(
            RPCRequest(method: method, arguments: actionArguments),
            returnArguments: false
        )
    }

    private func requireRPCVersion(_ required: Int, feature: String) throws {
        guard rpcVersion >= required else {
            throw TransmissionRPCError.unsupportedRPCVersion(
                feature: feature,
                required: required,
                actual: rpcVersion
            )
        }
    }

    private func setTrackerArguments(_ arguments: RPCArguments, torrentHash: String) async throws {
        guard let torrentHash = Self.normalizedActionText(torrentHash) else {
            throw TransmissionRPCError.invalidArguments
        }
        try await setTrackerArguments(arguments, torrentIdentifier: .string(torrentHash))
    }

    private func setTrackerArguments(_ arguments: RPCArguments, torrentIdentifier: JSONValue) async throws {
        var actionArguments = arguments
        actionArguments["ids"] = .array([torrentIdentifier])
        try await send(
            RPCRequest(method: "torrent-set", arguments: actionArguments),
            returnArguments: false
        )
    }

    private func urlRequest(
        body: Data,
        endpoint: URL,
        timeoutInterval: TimeInterval? = nil
    ) throws -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = timeoutInterval ?? TimeInterval(profile.requestTimeoutSeconds)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")
        if let sessionID {
            request.setValue(sessionID, forHTTPHeaderField: "X-Transmission-Session-Id")
        }
        if !profile.username.isEmpty {
            let token = "\(profile.username):\(profile.password)"
                .data(using: .utf8)?
                .base64EncodedString() ?? ""
            request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = body
        return request
    }

    nonisolated private static func httpErrorMessage(statusCode: Int, data: Data) -> String {
        let body = cleanedResponseBody(data)
        if !body.isEmpty {
            return body
        }

        let statusMessage = HTTPURLResponse.localizedString(forStatusCode: statusCode)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !statusMessage.isEmpty {
            return statusMessage
        }
        return statusCode == 0 ? "Invalid server response." : "HTTP error: \(statusCode)"
    }

    nonisolated private static func cleanedResponseBody(_ data: Data) -> String {
        guard !data.isEmpty else { return "" }
        var text = String(decoding: data, as: UTF8.self)
        if let bodyRange = text.range(of: #"<body\b[^>]*>"#, options: [.regularExpression, .caseInsensitive]) {
            text.removeSubrange(text.startIndex..<bodyRange.upperBound)
        }
        if let bodyEndRange = text.range(of: #"</body>"#, options: [.regularExpression, .caseInsensitive]) {
            text.removeSubrange(bodyEndRange.lowerBound..<text.endIndex)
        }

        for tag in ["br", "/p", "/h1", "li"] {
            text = text.replacingOccurrences(
                of: "<\(tag)\\b[^>]*>",
                with: " ",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        text = text.replacingOccurrences(
            of: #"<[^>]+>"#,
            with: " ",
            options: [.regularExpression, .caseInsensitive]
        )

        let entities = [
            "&quot;": "\"",
            "&#34;": "\"",
            "&#39;": "'",
            "&apos;": "'",
            "&amp;": "&",
            "&lt;": "<",
            "&gt;": ">",
            "&nbsp;": " ",
        ]
        for (entity, replacement) in entities {
            text = text.replacingOccurrences(of: entity, with: replacement, options: [.caseInsensitive])
        }

        let collapsed = text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(collapsed.prefix(1_000))
    }

    nonisolated private static func connectionFailureMessage(for error: URLError, endpoint: URL) -> String {
        let reason = switch error.code {
        case .cannotFindHost, .dnsLookupFailed:
            "host not found"
        case .cannotConnectToHost:
            "connection refused"
        case .timedOut:
            "connection timed out"
        case .notConnectedToInternet:
            "not connected to the internet"
        case .networkConnectionLost:
            "network connection was lost"
        case .secureConnectionFailed:
            "secure connection failed"
        case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
            "server certificate was not trusted"
        case .clientCertificateRejected, .clientCertificateRequired:
            "client certificate was rejected or required"
        default:
            error.localizedDescription
        }
        return "\(endpoint.absoluteString) — \(reason)"
    }

    private static let removedAfterRPC6TorrentFields: Set<String> = [
        "announceResponse",
        "leechers",
        "nextAnnounceTime",
        "seeders",
    ]

    private var defaultTorrentListFieldPlan: TorrentListFieldPlan {
        TorrentListFieldPlan(
            revision: 0,
            rpcVersion: rpcVersion,
            visibleColumns: Set(TorrentTableColumnID.allCases),
            activeSortColumn: TorrentTableDefaults.sort.columnID
        )
    }

    private var torrentPropertiesFields: [String] {
        var fields = [
            "id",
            "hashString",
            "downloadLimit",
            "downloadLimited",
            "uploadLimit",
            "uploadLimited",
            "name",
            "maxConnectedPeers",
            "seedRatioMode",
            "seedRatioLimit",
            "seedIdleLimit",
            "seedIdleMode",
        ]
        if rpcVersion < 5 {
            fields += ["downloadLimitMode", "uploadLimitMode"]
        }
        if rpcVersion >= 17 {
            fields.append("trackerList")
        } else {
            fields.append("trackers")
        }
        return Array(Set(fields)).sorted()
    }
}

extension TransmissionRPCClient: TorrentDuplicateTrackerRPC {}

private extension TorrentFilePriority {
    var rpcArgumentKey: String {
        switch self {
        case .low: "priority-low"
        case .normal: "priority-normal"
        case .high: "priority-high"
        }
    }
}
