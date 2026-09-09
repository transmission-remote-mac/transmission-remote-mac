// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation

enum TorrentFileLoadResult: Sendable {
    case loaded(snapshot: RaceResistantRegularFileSnapshot, summary: TorrentMetainfoSummary?, previewError: String?)
    case failed(String)
}

struct TorrentMetainfoSummary: Equatable, Sendable {
    var announceURLs: [String]
    var displayName: String
    var totalSize: Int64
    var files: [TorrentMetainfoFile]

    var announceURL: String? {
        announceURLs.first
    }

    init(data: Data) throws {
        try self.init(value: BencodeParser.parse(data))
    }

    init(value: BencodeValue) throws {
        try Task.checkCancellation()
        guard let root = value.dictionaryValue else {
            throw TorrentMetainfoError.rootNotDictionary
        }
        guard let info = root[utf8: "info"]?.dictionaryValue else {
            throw TorrentMetainfoError.missingInfoDictionary
        }

        let name = try Self.requiredString(in: info, key: "name", utf8Key: "name.utf-8", missingError: .missingName)
        guard !name.isEmpty else { throw TorrentMetainfoError.missingName }

        let files = try Self.files(from: info, displayName: name)
        self.announceURLs = try Self.announceURLs(from: root)
        self.displayName = name
        self.totalSize = try files.reduce(Int64(0)) { total, file in
            try Task.checkCancellation()
            let (next, overflow) = total.addingReportingOverflow(file.length)
            guard !overflow else { throw TorrentMetainfoError.invalidLength("files") }
            return next
        }
        self.files = files
    }

    private static func announceURLs(from root: [Data: BencodeValue]) throws -> [String] {
        var urls: [String] = []
        if let announce = try optionalString(root[utf8: "announce"], key: "announce"), !announce.isEmpty {
            urls.append(announce)
        }

        if let announceList = root[utf8: "announce-list"] {
            guard let tiers = announceList.listValue else {
                throw TorrentMetainfoError.invalidAnnounceList
            }
            for tier in tiers {
                try Task.checkCancellation()
                guard let tierURLs = tier.listValue else {
                    throw TorrentMetainfoError.invalidAnnounceList
                }
                for tracker in tierURLs {
                    try Task.checkCancellation()
                    guard let url = tracker.utf8StringValue else {
                        throw TorrentMetainfoError.invalidStringEncoding("announce-list")
                    }
                    if !url.isEmpty {
                        urls.append(url)
                    }
                }
            }
        }

        var seen: Set<String> = []
        return urls.filter { seen.insert($0).inserted }
    }

    private static func files(from info: [Data: BencodeValue], displayName: String) throws -> [TorrentMetainfoFile] {
        if let filesValue = info[utf8: "files"] {
            guard let fileValues = filesValue.listValue, !fileValues.isEmpty else {
                throw TorrentMetainfoError.invalidFilesList
            }
            return try fileValues.map { fileValue in
                try Task.checkCancellation()
                guard let file = fileValue.dictionaryValue else {
                    throw TorrentMetainfoError.invalidFilesList
                }
                let length = try requiredLength(in: file, context: "files.length")
                let pathComponents = try pathComponents(in: file)
                return TorrentMetainfoFile(pathComponents: pathComponents, length: length)
            }
        }

        let length = try requiredLength(in: info, context: "length")
        return [TorrentMetainfoFile(pathComponents: [displayName], length: length)]
    }

    private static func pathComponents(in file: [Data: BencodeValue]) throws -> [String] {
        let pathValue = file[utf8: "path.utf-8"] ?? file[utf8: "path"]
        guard let values = pathValue?.listValue, !values.isEmpty else {
            throw TorrentMetainfoError.invalidFilePath
        }
        let components = try values.map { value in
            try Task.checkCancellation()
            guard let component = value.utf8StringValue else {
                throw TorrentMetainfoError.invalidStringEncoding("path")
            }
            guard !component.isEmpty else {
                throw TorrentMetainfoError.invalidFilePath
            }
            return component
        }
        return components
    }

    private static func requiredLength(in dictionary: [Data: BencodeValue], context: String) throws -> Int64 {
        guard let value = dictionary[utf8: "length"]?.integerValue else {
            throw TorrentMetainfoError.missingLength(context)
        }
        guard value >= 0 else {
            throw TorrentMetainfoError.invalidLength(context)
        }
        return value
    }

    private static func requiredString(
        in dictionary: [Data: BencodeValue],
        key: String,
        utf8Key: String,
        missingError: TorrentMetainfoError
    ) throws -> String {
        let value = dictionary[utf8: utf8Key] ?? dictionary[utf8: key]
        guard let value else { throw missingError }
        guard let string = value.utf8StringValue else {
            throw TorrentMetainfoError.invalidStringEncoding(key)
        }
        return string
    }

    private static func optionalString(_ value: BencodeValue?, key: String) throws -> String? {
        guard let value else { return nil }
        guard let string = value.utf8StringValue else {
            throw TorrentMetainfoError.invalidStringEncoding(key)
        }
        return string
    }
}

struct TorrentMetainfoFile: Equatable, Sendable {
    var pathComponents: [String]
    var length: Int64

    var path: String {
        pathComponents.joined(separator: "/")
    }
}

enum TorrentMetainfoFilePriority: Int, CaseIterable, Identifiable, Sendable {
    case low = -1
    case normal = 0
    case high = 1

    var id: Int {
        rawValue
    }

    var title: String {
        switch self {
        case .low: "Low"
        case .normal: "Normal"
        case .high: "High"
        }
    }
}

struct TorrentMetainfoFileSelection: Identifiable, Equatable, Sendable {
    var index: Int
    var path: String
    var length: Int64
    var wanted: Bool
    var priority: TorrentMetainfoFilePriority

    var id: Int {
        index
    }

    static func selections(from summary: TorrentMetainfoSummary) -> [TorrentMetainfoFileSelection] {
        summary.files.enumerated().map { index, file in
            TorrentMetainfoFileSelection(
                index: index,
                path: file.path,
                length: file.length,
                wanted: true,
                priority: .normal
            )
        }
    }
}

struct TorrentAddFileSelection: Equatable, Sendable {
    var filesWanted: [Int]
    var filesUnwanted: [Int]
    var priorityHigh: [Int]
    var priorityNormal: [Int]
    var priorityLow: [Int]

    init(files: [TorrentMetainfoFileSelection]) {
        filesWanted = files.filter(\.wanted).map(\.index)
        filesUnwanted = files.filter { !$0.wanted }.map(\.index)
        priorityHigh = files.filter { $0.priority == .high }.map(\.index)
        priorityNormal = files.filter { $0.priority == .normal }.map(\.index)
        priorityLow = files.filter { $0.priority == .low }.map(\.index)
    }
}

enum TorrentMetainfoError: LocalizedError, Equatable {
    case rootNotDictionary
    case missingInfoDictionary
    case missingName
    case invalidStringEncoding(String)
    case invalidAnnounceList
    case invalidFilesList
    case invalidFilePath
    case missingLength(String)
    case invalidLength(String)

    var errorDescription: String? {
        switch self {
        case .rootNotDictionary: "Torrent metainfo root is not a dictionary"
        case .missingInfoDictionary: "Torrent metainfo is missing the info dictionary"
        case .missingName: "Torrent metainfo is missing the display name"
        case .invalidStringEncoding(let key): "Torrent metainfo string is not UTF-8 for \(key)"
        case .invalidAnnounceList: "Torrent metainfo announce-list is invalid"
        case .invalidFilesList: "Torrent metainfo files list is invalid"
        case .invalidFilePath: "Torrent metainfo file path is invalid"
        case .missingLength(let context): "Torrent metainfo is missing length for \(context)"
        case .invalidLength(let context): "Torrent metainfo has invalid length for \(context)"
        }
    }
}

private extension Dictionary where Key == Data, Value == BencodeValue {
    subscript(utf8 key: String) -> BencodeValue? {
        self[Data(key.utf8)]
    }
}
