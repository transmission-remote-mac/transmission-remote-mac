// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation

private func reversedRPCNames(_ canonicalToWire: [String: String]) -> [String: String] {
    Dictionary(uniqueKeysWithValues: canonicalToWire.map { ($1, $0) })
}

struct RPCSemanticVersion: Comparable, Equatable, Sendable {
    let major: Int
    let minor: Int
    let patch: Int

    init?(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutBuild = trimmed.split(separator: "+", maxSplits: 1).first.map(String.init) ?? ""
        let core = withoutBuild.split(separator: "-", maxSplits: 1).first.map(String.init) ?? ""
        let components = core.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count >= 1, components.count <= 3 else { return nil }
        let numbers = components.compactMap { Int($0) }
        guard numbers.count == components.count, numbers.allSatisfy({ $0 >= 0 }) else { return nil }
        major = numbers[0]
        minor = numbers.count > 1 ? numbers[1] : 0
        patch = numbers.count > 2 ? numbers[2] : 0
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

enum RPCWireProtocol: Equatable, Sendable {
    case legacy
    case jsonRPC2(RPCSemanticVersion)
}

struct RPCProtocolAdapter: Sendable {
    static let versionHeader = "X-Transmission-Rpc-Version"
    static let jsonRPCMinimumVersion = RPCSemanticVersion("6.0.0")!

    private enum ResponseContext: Equatable {
        case blocklistUpdate
        case freeSpace
        case generic
        case portTest
        case session
        case sessionStats
        case sessionStatsSnapshot
        case torrent
        case torrentAdd
        case torrentAddResult
        case torrentFile
        case torrentFileStats
        case torrentGet
        case torrentPeer
        case torrentTracker
        case torrentTrackerStats
    }

    private static let methodNames: [String: String] = [
        "blocklist-update": "blocklist_update",
        "free-space": "free_space",
        "port-test": "port_test",
        "queue-move-bottom": "queue_move_bottom",
        "queue-move-down": "queue_move_down",
        "queue-move-top": "queue_move_top",
        "queue-move-up": "queue_move_up",
        "session-close": "session_close",
        "session-get": "session_get",
        "session-set": "session_set",
        "session-stats": "session_stats",
        "torrent-add": "torrent_add",
        "torrent-get": "torrent_get",
        "torrent-reannounce": "torrent_reannounce",
        "torrent-remove": "torrent_remove",
        "torrent-rename-path": "torrent_rename_path",
        "torrent-set": "torrent_set",
        "torrent-set-location": "torrent_set_location",
        "torrent-start": "torrent_start",
        "torrent-start-now": "torrent_start_now",
        "torrent-stop": "torrent_stop",
        "torrent-verify": "torrent_verify",
    ]

    private static let argumentNames: [String: String] = [
        "alt-speed-down": "alt_speed_down",
        "alt-speed-enabled": "alt_speed_enabled",
        "alt-speed-time-begin": "alt_speed_time_begin",
        "alt-speed-time-day": "alt_speed_time_day",
        "alt-speed-time-enabled": "alt_speed_time_enabled",
        "alt-speed-time-end": "alt_speed_time_end",
        "alt-speed-up": "alt_speed_up",
        "bandwidthPriority": "bandwidth_priority",
        "blocklist-enabled": "blocklist_enabled",
        "blocklist-url": "blocklist_url",
        "cache-size-mb": "cache_size_mib",
        "delete-local-data": "delete_local_data",
        "dht-enabled": "dht_enabled",
        "download-dir": "download_dir",
        "download-queue-enabled": "download_queue_enabled",
        "download-queue-size": "download_queue_size",
        "downloadLimit": "download_limit",
        "downloadLimited": "download_limited",
        "files-unwanted": "files_unwanted",
        "files-wanted": "files_wanted",
        "honorsSessionLimits": "honors_session_limits",
        "idle-seeding-limit": "idle_seeding_limit",
        "idle-seeding-limit-enabled": "idle_seeding_limit_enabled",
        "incomplete-dir": "incomplete_dir",
        "incomplete-dir-enabled": "incomplete_dir_enabled",
        "ip-protocol": "ip_protocol",
        "lpd-enabled": "lpd_enabled",
        "peer-limit": "peer_limit",
        "peer-limit-global": "peer_limit_global",
        "peer-limit-per-torrent": "peer_limit_per_torrent",
        "peer-port": "peer_port",
        "peer-port-random-on-start": "peer_port_random_on_start",
        "pex-enabled": "pex_enabled",
        "port-forwarding-enabled": "port_forwarding_enabled",
        "priority-high": "priority_high",
        "priority-low": "priority_low",
        "priority-normal": "priority_normal",
        "queuePosition": "queue_position",
        "queue-stalled-enabled": "queue_stalled_enabled",
        "queue-stalled-minutes": "queue_stalled_minutes",
        "rename-partial-files": "rename_partial_files",
        "seed-queue-enabled": "seed_queue_enabled",
        "seed-queue-size": "seed_queue_size",
        "seedIdleLimit": "seed_idle_limit",
        "seedIdleMode": "seed_idle_mode",
        "seedRatioLimit": "seed_ratio_limit",
        "seedRatioLimited": "seed_ratio_limited",
        "seedRatioMode": "seed_ratio_mode",
        "sequentialDownload": "sequential_download",
        "sequentialDownloadFromPiece": "sequential_download_from_piece",
        "speed-limit-down": "speed_limit_down",
        "speed-limit-down-enabled": "speed_limit_down_enabled",
        "speed-limit-up": "speed_limit_up",
        "speed-limit-up-enabled": "speed_limit_up_enabled",
        "trackerAdd": "tracker_add",
        "trackerList": "tracker_list",
        "trackerRemove": "tracker_remove",
        "trackerReplace": "tracker_replace",
        "uploadLimit": "upload_limit",
        "uploadLimited": "upload_limited",
    ]

    private static let torrentFieldNames: [String: String] = [
        "activityDate": "activity_date",
        "addedDate": "added_date",
        "announceResponse": "announce_response",
        "bandwidthPriority": "bandwidth_priority",
        "comment": "comment",
        "corruptEver": "corrupt_ever",
        "creator": "creator",
        "dateCreated": "date_created",
        "desiredAvailable": "desired_available",
        "doneDate": "done_date",
        "downloadDir": "download_dir",
        "downloadedEver": "downloaded_ever",
        "downloadLimit": "download_limit",
        "downloadLimitMode": "download_limit_mode",
        "downloadLimited": "download_limited",
        "errorString": "error_string",
        "eta": "eta",
        "fileStats": "file_stats",
        "files": "files",
        "hashString": "hash_string",
        "haveUnchecked": "have_unchecked",
        "haveValid": "have_valid",
        "id": "id",
        "isPrivate": "is_private",
        "isStalled": "is_stalled",
        "labels": "labels",
        "leechers": "leechers",
        "leftUntilDone": "left_until_done",
        "magnetLink": "magnet_link",
        "maxConnectedPeers": "max_connected_peers",
        "metadataPercentComplete": "metadata_percent_complete",
        "name": "name",
        "nextAnnounceTime": "next_announce_time",
        "peers": "peers",
        "peersGettingFromUs": "peers_getting_from_us",
        "peersSendingToUs": "peers_sending_to_us",
        "percentDone": "percent_done",
        "percentComplete": "percent_complete",
        "pieceCount": "piece_count",
        "pieceSize": "piece_size",
        "pieces": "pieces",
        "priorities": "priorities",
        "queuePosition": "queue_position",
        "rateDownload": "rate_download",
        "rateUpload": "rate_upload",
        "recheckProgress": "recheck_progress",
        "secondsDownloading": "seconds_downloading",
        "secondsSeeding": "seconds_seeding",
        "sequentialDownload": "sequential_download",
        "sequentialDownloadFromPiece": "sequential_download_from_piece",
        "seeders": "seeders",
        "seedIdleLimit": "seed_idle_limit",
        "seedIdleMode": "seed_idle_mode",
        "seedRatioLimit": "seed_ratio_limit",
        "seedRatioMode": "seed_ratio_mode",
        "sizeWhenDone": "size_when_done",
        "status": "status",
        "totalSize": "total_size",
        "trackerList": "tracker_list",
        "trackers": "trackers",
        "trackerStats": "tracker_stats",
        "uploadedEver": "uploaded_ever",
        "uploadLimit": "upload_limit",
        "uploadLimitMode": "upload_limit_mode",
        "uploadLimited": "upload_limited",
        "uploadRatio": "upload_ratio",
        "wanted": "wanted",
    ]

    private static let removedJSONRPCFields: Set<String> = [
        "announceResponse",
        "downloadLimitMode",
        "leechers",
        "nextAnnounceTime",
        "seeders",
        "uploadLimitMode",
    ]

    private static let sessionResponseNames = reversedRPCNames([
        "alt-speed-down": "alt_speed_down",
        "alt-speed-enabled": "alt_speed_enabled",
        "alt-speed-time-begin": "alt_speed_time_begin",
        "alt-speed-time-day": "alt_speed_time_day",
        "alt-speed-time-enabled": "alt_speed_time_enabled",
        "alt-speed-time-end": "alt_speed_time_end",
        "alt-speed-up": "alt_speed_up",
        "blocklist-enabled": "blocklist_enabled",
        "blocklist-url": "blocklist_url",
        "cache-size-mb": "cache_size_mb",
        "dht-enabled": "dht_enabled",
        "download-dir": "download_dir",
        "download-dir-free-space": "download_dir_free_space",
        "download-queue-enabled": "download_queue_enabled",
        "download-queue-size": "download_queue_size",
        "idle-seeding-limit": "idle_seeding_limit",
        "idle-seeding-limit-enabled": "idle_seeding_limit_enabled",
        "incomplete-dir": "incomplete_dir",
        "incomplete-dir-enabled": "incomplete_dir_enabled",
        "lpd-enabled": "lpd_enabled",
        "peer-limit-global": "peer_limit_global",
        "peer-limit-per-torrent": "peer_limit_per_torrent",
        "peer-port": "peer_port",
        "peer-port-random-on-start": "peer_port_random_on_start",
        "pex-enabled": "pex_enabled",
        "port-forwarding-enabled": "port_forwarding_enabled",
        "queue-stalled-enabled": "queue_stalled_enabled",
        "queue-stalled-minutes": "queue_stalled_minutes",
        "rename-partial-files": "rename_partial_files",
        "rpc-version": "rpc_version",
        "rpc-version-minimum": "rpc_version_minimum",
        "rpc-version-semver": "rpc_version_semver",
        "seed-queue-enabled": "seed_queue_enabled",
        "seed-queue-size": "seed_queue_size",
        "seedRatioLimit": "seed_ratio_limit",
        "seedRatioLimited": "seed_ratio_limited",
        "speed-limit-down": "speed_limit_down",
        "speed-limit-down-enabled": "speed_limit_down_enabled",
        "speed-limit-up": "speed_limit_up",
        "speed-limit-up-enabled": "speed_limit_up_enabled",
        "utp-enabled": "utp_enabled",
    ])

    private static let statsResponseNames = reversedRPCNames([
        "activeTorrentCount": "active_torrent_count",
        "cumulative-stats": "cumulative_stats",
        "current-stats": "current_stats",
        "downloadSpeed": "download_speed",
        "pausedTorrentCount": "paused_torrent_count",
        "torrentCount": "torrent_count",
        "uploadSpeed": "upload_speed",
    ])

    private static let statsSnapshotResponseNames = reversedRPCNames([
        "downloadedBytes": "downloaded_bytes",
        "filesAdded": "files_added",
        "secondsActive": "seconds_active",
        "sessionCount": "session_count",
        "uploadedBytes": "uploaded_bytes",
    ])
    private static let portTestResponseNames = reversedRPCNames([
        "ip-protocol": "ip_protocol",
        "port-is-open": "port_is_open",
    ])
    private static let blocklistUpdateResponseNames = reversedRPCNames([
        "blocklist-size": "blocklist_size",
    ])

    private static let torrentResponseNames = reversedRPCNames(torrentFieldNames)
    private static let torrentAddResponseNames = reversedRPCNames([
        "torrent-added": "torrent_added",
        "torrent-duplicate": "torrent_duplicate",
    ])
    private static let torrentAddResultResponseNames = reversedRPCNames(["hashString": "hash_string"])
    private static let fileResponseNames = reversedRPCNames([
        "beginPiece": "begin_piece",
        "bytesCompleted": "bytes_completed",
        "endPiece": "end_piece",
    ])
    private static let fileStatsResponseNames = reversedRPCNames(["bytesCompleted": "bytes_completed"])
    private static let peerResponseNames = reversedRPCNames([
        "bytesToClient": "bytes_to_client",
        "bytesToPeer": "bytes_to_peer",
        "clientIsChoked": "client_is_choked",
        "clientIsInterested": "client_is_interested",
        "clientName": "client_name",
        "flagStr": "flag_str",
        "isDownloadingFrom": "is_downloading_from",
        "isEncrypted": "is_encrypted",
        "isIncoming": "is_incoming",
        "isUploadingTo": "is_uploading_to",
        "isUTP": "is_utp",
        "peerID": "peer_id",
        "peerIsChoked": "peer_is_choked",
        "peerIsInterested": "peer_is_interested",
        "rateToClient": "rate_to_client",
        "rateToPeer": "rate_to_peer",
        "supportsHolepunch": "supports_holepunch",
    ])
    private static let trackerStatsResponseNames = reversedRPCNames([
        "announceState": "announce_state",
        "downloadCount": "download_count",
        "downloaderCount": "downloader_count",
        "hasAnnounced": "has_announced",
        "hasScraped": "has_scraped",
        "isBackup": "is_backup",
        "lastAnnouncePeerCount": "last_announce_peer_count",
        "lastAnnounceResult": "last_announce_result",
        "lastAnnounceStartTime": "last_announce_start_time",
        "lastAnnounceSucceeded": "last_announce_succeeded",
        "lastAnnounceTime": "last_announce_time",
        "lastAnnounceTimedOut": "last_announce_timed_out",
        "lastScrapeResult": "last_scrape_result",
        "lastScrapeStartTime": "last_scrape_start_time",
        "lastScrapeSucceeded": "last_scrape_succeeded",
        "lastScrapeTime": "last_scrape_time",
        "lastScrapeTimedOut": "last_scrape_timed_out",
        "leecherCount": "leecher_count",
        "nextAnnounceTime": "next_announce_time",
        "nextScrapeTime": "next_scrape_time",
        "scrapeState": "scrape_state",
        "seederCount": "seeder_count",
    ])

    static func wireProtocol(challengeHeader: String?) -> RPCWireProtocol {
        guard
            let challengeHeader,
            let version = RPCSemanticVersion(challengeHeader),
            version >= jsonRPCMinimumVersion
        else {
            return .legacy
        }
        return .jsonRPC2(version)
    }

    static func encode(_ request: RPCRequest, protocol wireProtocol: RPCWireProtocol, id: Int) throws -> Data {
        switch wireProtocol {
        case .legacy:
            return try JSONEncoder().encode(request)
        case .jsonRPC2:
            guard let method = methodNames[request.method] else {
                throw TransmissionRPCError.invalidArguments
            }
            let params = try jsonArguments(request.arguments, method: request.method)
            return try JSONEncoder().encode(JSONValue.object([
                "jsonrpc": .string("2.0"),
                "method": .string(method),
                "params": .object(params),
                "id": .int(id),
            ]))
        }
    }

    static func decode(
        _ data: Data,
        for request: RPCRequest,
        protocol wireProtocol: RPCWireProtocol,
        expectedID: Int,
        returnArguments: Bool
    ) throws -> RPCArguments {
        switch wireProtocol {
        case .legacy:
            return try decodeLegacy(data, returnArguments: returnArguments)
        case .jsonRPC2:
            return try decodeJSONRPC(
                data,
                for: request,
                expectedID: expectedID,
                returnArguments: returnArguments
            )
        }
    }

    private static func jsonArguments(_ arguments: RPCArguments, method: String) throws -> RPCArguments {
        var result: RPCArguments = [:]
        for (key, value) in arguments {
            if key == "utp-enabled" {
                guard let enabled = value.boolValue else { throw TransmissionRPCError.invalidArguments }
                result["preferred_transports"] = .array(
                    (enabled ? ["utp", "tcp"] : ["tcp"]).map(JSONValue.string)
                )
                continue
            }
            let wireKey = argumentNames[key] ?? key
            result[wireKey] = try jsonArgumentValue(value, key: key, method: method)
        }
        return result
    }

    private static func jsonArgumentValue(_ value: JSONValue, key: String, method: String) throws -> JSONValue {
        if method == "torrent-get", key == "fields" {
            guard let fields = value.arrayValue else { throw TransmissionRPCError.invalidArguments }
            return .array(try fields.compactMap { field in
                guard let field = field.stringValue else {
                    throw TransmissionRPCError.invalidArguments
                }
                guard !removedJSONRPCFields.contains(field) else { return nil }
                guard let wireField = torrentFieldNames[field] else {
                    throw TransmissionRPCError.invalidArguments
                }
                return .string(wireField)
            })
        }
        if key == "ids", value.stringValue == "recently-active" {
            return .string("recently_active")
        }
        if key == "encryption", value.stringValue == "tolerated" {
            return .string("allowed")
        }
        return value
    }

    private static func decodeLegacy(_ data: Data, returnArguments: Bool) throws -> RPCArguments {
        let response: RPCResponse
        do {
            response = try JSONDecoder().decode(RPCResponse.self, from: data)
        } catch {
            throw TransmissionRPCError.malformedJSON
        }
        guard !response.containsJSONRPC else { throw TransmissionRPCError.invalidResponse }
        guard let result = response.result?.stringValue else {
            throw TransmissionRPCError.malformedJSON
        }
        guard result.caseInsensitiveCompare("success") == .orderedSame else {
            throw TransmissionRPCError.rpcFailure(result)
        }
        guard returnArguments else { return [:] }
        guard response.arguments != nil else { throw TransmissionRPCError.missingArguments }
        guard let arguments = response.arguments?.objectValue else {
            throw TransmissionRPCError.invalidArguments
        }
        return arguments
    }

    private static func decodeJSONRPC(
        _ data: Data,
        for request: RPCRequest,
        expectedID: Int,
        returnArguments: Bool
    ) throws -> RPCArguments {
        let rootValue: JSONValue
        do {
            rootValue = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw TransmissionRPCError.malformedJSON
        }
        guard let root = rootValue.objectValue else { throw TransmissionRPCError.invalidResponse }
        guard root["jsonrpc"]?.stringValue == "2.0" else { throw TransmissionRPCError.invalidResponse }
        guard root["id"] == .int(expectedID) else { throw TransmissionRPCError.invalidResponse }

        let result = root["result"]
        let error = root["error"]
        guard (result == nil) != (error == nil) else { throw TransmissionRPCError.invalidResponse }
        if let error {
            let rpcError = try jsonRPCError(error, for: request)
            throw rpcError
        }
        guard let resultObject = result?.objectValue else { throw TransmissionRPCError.invalidArguments }
        guard returnArguments else { return [:] }
        return normalize(resultObject, context: responseContext(for: request.method))
    }

    private static func jsonRPCError(
        _ value: JSONValue,
        for request: RPCRequest
    ) throws -> TransmissionRPCError {
        guard
            let error = value.objectValue,
            let code = error["code"],
            case .int = code,
            let message = error["message"]?.stringValue,
            !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw TransmissionRPCError.invalidResponse
        }

        var detail: String?
        var normalizedResult: RPCArguments?
        if let data = error["data"] {
            guard let dataObject = data.objectValue else { throw TransmissionRPCError.invalidResponse }
            if let errorString = dataObject["error_string"] {
                guard let string = errorString.stringValue else { throw TransmissionRPCError.invalidResponse }
                detail = string.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let result = dataObject["result"] {
                guard let resultObject = result.objectValue else {
                    throw TransmissionRPCError.invalidResponse
                }
                normalizedResult = normalize(
                    resultObject,
                    context: responseContext(for: request.method)
                )
            }
        }
        let normalizedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayMessage: String
        if let detail, !detail.isEmpty, detail != normalizedMessage {
            displayMessage = "\(normalizedMessage): \(detail)"
        } else {
            displayMessage = normalizedMessage
        }
        if let normalizedResult, !normalizedResult.isEmpty {
            return .rpcFailureWithArguments(displayMessage, normalizedResult)
        }
        return .rpcFailure(displayMessage)
    }

    private static func responseContext(for method: String) -> ResponseContext {
        switch method {
        case "session-get": .session
        case "session-stats": .sessionStats
        case "torrent-get": .torrentGet
        case "torrent-add": .torrentAdd
        case "free-space": .freeSpace
        case "port-test": .portTest
        case "blocklist-update": .blocklistUpdate
        default: .generic
        }
    }

    private static func normalize(_ object: RPCArguments, context: ResponseContext) -> RPCArguments {
        if context == .torrentGet {
            return normalizeTorrentGet(object)
        }

        let names = responseNames(for: context)
        var normalized: RPCArguments = [:]
        for (wireKey, value) in object {
            let canonicalKey = names[wireKey] ?? wireKey
            normalized[canonicalKey] = normalize(value, parentKey: canonicalKey, context: context)
        }

        if context == .session {
            if let transports = object["preferred_transports"]?.arrayValue?.compactMap(\.stringValue) {
                normalized["utp-enabled"] = .bool(transports.contains("utp"))
            }
            if let cacheSize = object["cache_size_mib"] {
                normalized["cache-size-mb"] = cacheSize
            }
            if normalized["encryption"]?.stringValue == "allowed" {
                normalized["encryption"] = .string("tolerated")
            }
        }
        return normalized
    }

    private static func normalizeTorrentGet(_ object: RPCArguments) -> RPCArguments {
        let separateFieldNames = normalizedTorrentFieldNames(object["fields"])
        var normalized: RPCArguments = [:]
        for (key, value) in object {
            switch key {
            case "fields":
                normalized[key] = normalizeFieldArray(value)
            case "torrents", "data":
                normalized[key] = normalizeTorrentRows(
                    value,
                    separateFieldNames: separateFieldNames
                )
            default:
                normalized[key] = value
            }
        }
        return normalized
    }

    private static func normalizeTorrentRows(
        _ value: JSONValue,
        separateFieldNames: [String]?
    ) -> JSONValue {
        guard let rows = value.arrayValue else { return value }
        var fieldNames = separateFieldNames
        return .array(rows.enumerated().map { index, row in
            if let object = row.objectValue {
                return .object(normalize(object, context: .torrent))
            }
            if separateFieldNames == nil,
               index == 0,
               let embeddedFieldNames = normalizedTorrentFieldNames(row) {
                fieldNames = embeddedFieldNames
                return .array(embeddedFieldNames.map(JSONValue.string))
            }
            guard let fieldNames, let values = row.arrayValue, values.count == fieldNames.count else {
                return row
            }
            return .array(zip(fieldNames, values).map { field, cell in
                normalize(cell, parentKey: field, context: .torrent)
            })
        })
    }

    private static func normalizedTorrentFieldNames(_ value: JSONValue?) -> [String]? {
        guard
            let values = value?.arrayValue,
            !values.isEmpty,
            values.allSatisfy({ $0.stringValue != nil })
        else {
            return nil
        }
        return values.compactMap(\.stringValue).map { torrentResponseNames[$0] ?? $0 }
    }

    private static func normalizeFieldArray(_ value: JSONValue) -> JSONValue {
        guard let values = value.arrayValue else { return value }
        return .array(values.map { item in
            guard let field = item.stringValue else { return item }
            return .string(torrentResponseNames[field] ?? field)
        })
    }

    private static func normalize(_ value: JSONValue, parentKey: String, context: ResponseContext) -> JSONValue {
        let childContext: ResponseContext? = switch (context, parentKey) {
        case (.sessionStats, "current-stats"), (.sessionStats, "cumulative-stats"):
            .sessionStatsSnapshot
        case (.torrent, "files"):
            .torrentFile
        case (.torrent, "fileStats"):
            .torrentFileStats
        case (.torrent, "peers"):
            .torrentPeer
        case (.torrent, "trackers"):
            .torrentTracker
        case (.torrent, "trackerStats"):
            .torrentTrackerStats
        case (.torrentAdd, "torrent-added"), (.torrentAdd, "torrent-duplicate"):
            .torrentAddResult
        default:
            nil
        }

        guard let childContext else { return value }
        if let object = value.objectValue {
            return .object(normalize(object, context: childContext))
        }
        if let array = value.arrayValue {
            return .array(array.map { item in
                guard let object = item.objectValue else { return item }
                return .object(normalize(object, context: childContext))
            })
        }
        return value
    }

    private static func responseNames(for context: ResponseContext) -> [String: String] {
        switch context {
        case .session: sessionResponseNames
        case .sessionStats: statsResponseNames
        case .sessionStatsSnapshot: statsSnapshotResponseNames
        case .torrent: torrentResponseNames
        case .torrentAdd: torrentAddResponseNames
        case .torrentAddResult: torrentAddResultResponseNames
        case .torrentFile: fileResponseNames
        case .torrentFileStats: fileStatsResponseNames
        case .torrentPeer: peerResponseNames
        case .torrentTrackerStats: trackerStatsResponseNames
        case .freeSpace: ["size_bytes": "size-bytes", "total_size": "total-size"]
        case .portTest: portTestResponseNames
        case .blocklistUpdate: blocklistUpdateResponseNames
        case .generic, .torrentGet, .torrentTracker: [:]
        }
    }
}
