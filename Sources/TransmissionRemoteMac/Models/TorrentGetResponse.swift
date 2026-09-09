// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation

enum TorrentGetResponseDecodingError: Equatable, LocalizedError {
    case invalidRows
    case invalidTableFields
    case truncatedTableRow
    case invalidTorrentID
    case duplicateTorrentID(Int)

    var errorDescription: String? {
        switch self {
        case .invalidRows:
            "Transmission returned malformed or mixed torrent rows."
        case .invalidTableFields:
            "Transmission returned an invalid torrent table field list."
        case .truncatedTableRow:
            "Transmission returned a torrent table row with the wrong number of values."
        case .invalidTorrentID:
            "Transmission returned a torrent without a positive integer ID."
        case .duplicateTorrentID(let id):
            "Transmission returned duplicate torrent ID \(id)."
        }
    }
}

struct TorrentGetResponse: Equatable, Sendable {
    var torrents: [TorrentGetTorrent]
    var removedIDs: [Int]

    init(
        validating arguments: RPCArguments,
        requiresTorrentIDs: Bool = true
    ) throws {
        let decodedTorrents = try Self.decodeTorrents(from: arguments)
        var seenIDs = Set<Int>()
        torrents = try decodedTorrents.map { torrent in
            if let idValue = torrent["id"] {
                guard let id = idValue.intValue, id > 0 else {
                    throw TorrentGetResponseDecodingError.invalidTorrentID
                }
                guard seenIDs.insert(id).inserted else {
                    throw TorrentGetResponseDecodingError.duplicateTorrentID(id)
                }
            } else if requiresTorrentIDs {
                throw TorrentGetResponseDecodingError.invalidTorrentID
            }
            return torrent
        }
        removedIDs = Array(Set(arguments["removed"]?.arrayValue?.compactMap(\.intValue) ?? [])).sorted()
    }

    /// Counts structurally valid wire rows for diagnostics without materializing
    /// every table row as a dictionary before the caller performs real decoding.
    static func wireRowCount(in arguments: RPCArguments) -> Int {
        if let rows = arguments["torrents"]?.arrayValue,
           rows.allSatisfy({ $0.objectValue != nil }) {
            return rows.count
        }
        if arguments["fields"] != nil {
            guard let fieldNames = try? decodeFieldNames(arguments["fields"]) else { return 0 }
            let rows = arguments["data"]?.arrayValue ?? arguments["torrents"]?.arrayValue ?? []
            guard rows.allSatisfy({ $0.arrayValue?.count == fieldNames.count }) else { return 0 }
            return rows.count
        }

        guard let rows = arguments["torrents"]?.arrayValue else { return 0 }
        if rows.allSatisfy({ $0.objectValue != nil }) {
            return rows.count
        }
        guard let header = rows.first,
              let fieldNames = try? decodeFieldNames(header) else {
            return 0
        }
        let dataRows = rows.dropFirst()
        guard dataRows.allSatisfy({ $0.arrayValue?.count == fieldNames.count }) else { return 0 }
        return dataRows.count
    }

    private static func decodeTorrents(from arguments: RPCArguments) throws -> [TorrentGetTorrent] {
        let torrentRows = arguments["torrents"]?.arrayValue
        if let torrentRows, torrentRows.isEmpty {
            return []
        }

        if let torrentRows, torrentRows.contains(where: { $0.objectValue != nil }) {
            guard torrentRows.allSatisfy({ $0.objectValue != nil }) else {
                throw TorrentGetResponseDecodingError.invalidRows
            }
            return torrentRows.compactMap(\.objectValue).map(TorrentGetTorrent.init(json:))
        }

        if arguments["fields"] != nil {
            let fieldNames = try decodeFieldNames(arguments["fields"])
            if let dataRows = arguments["data"]?.arrayValue {
                return try decodeTableRows(dataRows, fieldNames: fieldNames)
            }
            if let torrentRows {
                return try decodeTableRows(torrentRows, fieldNames: fieldNames)
            }
            return []
        }

        guard var rows = torrentRows else { return [] }
        guard let header = rows.first else {
            return []
        }
        let fieldNames = try decodeFieldNames(header)
        rows.removeFirst()
        return try decodeTableRows(rows, fieldNames: fieldNames)
    }

    private static func decodeFieldNames(_ value: JSONValue?) throws -> [String] {
        guard
            let values = value?.arrayValue,
            !values.isEmpty,
            values.allSatisfy({ $0.stringValue != nil })
        else {
            throw TorrentGetResponseDecodingError.invalidTableFields
        }
        let fieldNames = values.compactMap(\.stringValue)
        guard Set(fieldNames).count == fieldNames.count else {
            throw TorrentGetResponseDecodingError.invalidTableFields
        }
        return fieldNames
    }

    private static func decodeTableRows(
        _ rows: [JSONValue],
        fieldNames: [String]
    ) throws -> [TorrentGetTorrent] {
        let fieldIndexes = Dictionary(
            uniqueKeysWithValues: fieldNames.enumerated().map { ($0.element, $0.offset) }
        )
        return try rows.map { row in
            guard let values = row.arrayValue else {
                throw TorrentGetResponseDecodingError.invalidRows
            }
            guard values.count == fieldNames.count else {
                throw TorrentGetResponseDecodingError.truncatedTableRow
            }
            return TorrentGetTorrent(fieldIndexes: fieldIndexes, tableValues: values)
        }
    }
}

struct TorrentGetTorrent: Identifiable, Equatable, Sendable {
    private enum Storage: Equatable, Sendable {
        case object(RPCArguments)
        case table(fieldIndexes: [String: Int], values: [JSONValue])
    }

    private var storage: Storage

    var json: RPCArguments {
        switch storage {
        case .object(let object):
            object
        case .table(let fieldIndexes, let values):
            Dictionary(uniqueKeysWithValues: fieldIndexes.compactMap { field, index in
                guard values.indices.contains(index) else { return nil }
                return (field, values[index])
            })
        }
    }

    subscript(field: String) -> JSONValue? {
        switch storage {
        case .object(let object):
            return object[field]
        case .table(let fieldIndexes, let values):
            guard let index = fieldIndexes[field], values.indices.contains(index) else { return nil }
            return values[index]
        }
    }

    var id: Int { self["id"]?.intValue ?? 0 }
    var providedName: String? { self["name"]?.stringValue }
    var name: String { self["name"]?.stringValue ?? "" }
    var status: Int? { self["status"]?.intValue }
    var errorString: String? { self["errorString"]?.stringValue }
    var announceResponse: String? { self["announceResponse"]?.stringValue }
    var recheckProgress: Double? { self["recheckProgress"]?.doubleValue }
    var metadataPercentComplete: Double? { self["metadataPercentComplete"]?.doubleValue }
    var percentDone: Double? { self["percentDone"]?.doubleValue }
    var totalSize: Int64? { self["totalSize"]?.int64Value }
    var sizeWhenDone: Int64? { self["sizeWhenDone"]?.int64Value }
    var leftUntilDone: Int64? { self["leftUntilDone"]?.int64Value }
    var rateDownload: Int64? { self["rateDownload"]?.int64Value }
    var rateUpload: Int64? { self["rateUpload"]?.int64Value }
    var peersSendingToUs: Int? { self["peersSendingToUs"]?.intValue }
    var seeders: Int? { self["seeders"]?.intValue }
    var peersGettingFromUs: Int? { self["peersGettingFromUs"]?.intValue }
    var leechers: Int? { self["leechers"]?.intValue }
    var eta: Int? { self["eta"]?.intValue }
    var uploadRatio: Double? { self["uploadRatio"]?.doubleValue }
    var downloadedEver: Int64? { self["downloadedEver"]?.int64Value }
    var uploadedEver: Int64? { self["uploadedEver"]?.int64Value }
    var addedDate: Date? { self["addedDate"]?.dateFromUnixTime }
    var doneDate: Date? { self["doneDate"]?.dateFromUnixTime }
    var activityDate: Date? { self["activityDate"]?.dateFromUnixTime }
    var downloadDir: String? { self["downloadDir"]?.stringValue }
    var bandwidthPriority: Int? { self["bandwidthPriority"]?.intValue }
    var queuePosition: Int? { self["queuePosition"]?.intValue }
    var secondsSeeding: Int? { self["secondsSeeding"]?.intValue }
    var isPrivate: Bool? { self["isPrivate"]?.boolValue }
    var labels: [String]? { self["labels"]?.arrayValue?.compactMap(\.stringValue) }
    var peers: [JSONValue]? { self["peers"]?.arrayValue }
    var trackerStats: [JSONValue]? { self["trackerStats"]?.arrayValue }
    var trackers: [JSONValue]? { self["trackers"]?.arrayValue }
    var files: [JSONValue]? { self["files"]?.arrayValue }
    var fileStats: [JSONValue]? { self["fileStats"]?.arrayValue }
    var priorities: [JSONValue]? { self["priorities"]?.arrayValue }
    var wanted: [JSONValue]? { self["wanted"]?.arrayValue }
    var nextAnnounceDate: Date? { self["nextAnnounceTime"]?.dateFromUnixTime }
    var hashString: String? { self["hashString"]?.stringValue }
    var magnetLink: String? { self["magnetLink"]?.stringValue }
    var comment: String? { self["comment"]?.stringValue }
    var creator: String? { self["creator"]?.stringValue }
    var dateCreated: Date? { self["dateCreated"]?.dateFromUnixTime }
    var pieceCount: Int? { self["pieceCount"]?.intValue }
    var pieceSize: Int64? { self["pieceSize"]?.int64Value }
    var pieceMapState: TorrentPieceMapState {
        TorrentPieceMapState(
            base64Encoded: self["pieces"]?.stringValue,
            pieceCount: pieceCount
        )
    }
    var haveValid: Int64? { self["haveValid"]?.int64Value }
    var haveUnchecked: Int64? { self["haveUnchecked"]?.int64Value }
    var secondsDownloading: Int? { self["secondsDownloading"]?.intValue }
    var desiredAvailable: Int64? { self["desiredAvailable"]?.int64Value }

    init(json: RPCArguments) {
        storage = .object(json)
    }

    fileprivate init(fieldIndexes: [String: Int], tableValues: [JSONValue]) {
        storage = .table(fieldIndexes: fieldIndexes, values: tableValues)
    }

    func merging(_ overridingValues: TorrentGetTorrent) -> TorrentGetTorrent {
        var merged = json
        merged.merge(overridingValues.json) { _, overridingValue in overridingValue }
        return TorrentGetTorrent(json: merged)
    }
}
