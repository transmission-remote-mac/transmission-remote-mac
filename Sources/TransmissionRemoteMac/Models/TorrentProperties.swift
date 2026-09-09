// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation

struct TorrentPropertiesSnapshot: Equatable, Sendable {
    var id: Int
    var name: String
    var downloadSpeedLimit: TorrentPropertiesSpeedLimit
    var uploadSpeedLimit: TorrentPropertiesSpeedLimit
    var peerLimit: Int?
    var seedRatio: TorrentPropertiesLimitSetting
    var seedIdle: TorrentPropertiesLimitSetting
    var trackers: [TorrentPropertiesTracker]
    var trackerList: String?

    var trackerText: String {
        trackerList ?? trackers.map(\.announce).joined(separator: "\n")
    }

    init(
        id: Int,
        name: String = "",
        downloadSpeedLimit: TorrentPropertiesSpeedLimit = .init(isEnabled: false, limitKBps: nil),
        uploadSpeedLimit: TorrentPropertiesSpeedLimit = .init(isEnabled: false, limitKBps: nil),
        peerLimit: Int? = nil,
        seedRatio: TorrentPropertiesLimitSetting = .init(mode: .global, limit: nil),
        seedIdle: TorrentPropertiesLimitSetting = .init(mode: .global, limit: nil),
        trackers: [TorrentPropertiesTracker] = [],
        trackerList: String? = nil
    ) {
        self.id = id
        self.name = name
        self.downloadSpeedLimit = downloadSpeedLimit
        self.uploadSpeedLimit = uploadSpeedLimit
        self.peerLimit = peerLimit
        self.seedRatio = seedRatio
        self.seedIdle = seedIdle
        self.trackers = trackers
        self.trackerList = trackerList
    }

    init(torrent: TorrentGetTorrent) {
        id = torrent.id
        name = torrent.name
        downloadSpeedLimit = TorrentPropertiesSpeedLimit(
            isEnabled: torrent["downloadLimited"]?.boolOrIntValue
                ?? Self.legacyLimitEnabled(torrent["downloadLimitMode"]?.intValue),
            limitKBps: torrent["downloadLimit"]?.intValue
        )
        uploadSpeedLimit = TorrentPropertiesSpeedLimit(
            isEnabled: torrent["uploadLimited"]?.boolOrIntValue
                ?? Self.legacyLimitEnabled(torrent["uploadLimitMode"]?.intValue),
            limitKBps: torrent["uploadLimit"]?.intValue
        )
        peerLimit = torrent["maxConnectedPeers"]?.intValue
        seedRatio = TorrentPropertiesLimitSetting(
            mode: TorrentPropertiesLimitMode(rawValue: torrent["seedRatioMode"]?.intValue ?? 0) ?? .global,
            limit: torrent["seedRatioLimit"]?.doubleValue
        )
        seedIdle = TorrentPropertiesLimitSetting(
            mode: TorrentPropertiesLimitMode(rawValue: torrent["seedIdleMode"]?.intValue ?? 0) ?? .global,
            limit: torrent["seedIdleLimit"]?.doubleValue
        )
        trackers = (torrent["trackers"]?.arrayValue ?? []).enumerated().compactMap { index, value in
            guard let tracker = value.objectValue else { return nil }
            return TorrentPropertiesTracker(index: index, json: tracker)
        }
        trackerList = torrent["trackerList"]?.stringValue
    }

    func draft() -> TorrentPropertiesDraft {
        TorrentPropertiesDraft(snapshot: self)
    }

    private static func legacyLimitEnabled(_ mode: Int?) -> Bool {
        mode == 1
    }
}

struct TorrentPropertiesSpeedLimit: Equatable, Sendable {
    var isEnabled: Bool
    var limitKBps: Int?
}

enum TorrentPropertiesLimitMode: Int, Equatable, Sendable {
    case global = 0
    case single = 1
    case unlimited = 2
}

struct TorrentPropertiesLimitSetting: Equatable, Sendable {
    var mode: TorrentPropertiesLimitMode
    var limit: Double?
}

struct TorrentPropertiesTracker: Equatable, Sendable {
    var id: Int
    var announce: String

    init(id: Int, announce: String) {
        self.id = id
        self.announce = announce
    }

    init(index: Int, json: RPCArguments) {
        id = json["id"]?.intValue ?? index
        announce = json["announce"]?.stringValue ?? ""
    }
}

struct TorrentPropertiesDraft: Equatable, Sendable {
    private var original: TorrentPropertiesSnapshot

    var downloadSpeedLimit: TorrentPropertiesSpeedLimit
    var uploadSpeedLimit: TorrentPropertiesSpeedLimit
    var peerLimit: Int?
    var seedRatio: TorrentPropertiesLimitSetting
    var seedIdle: TorrentPropertiesLimitSetting
    var trackerText: String

    init(snapshot: TorrentPropertiesSnapshot) {
        original = snapshot
        downloadSpeedLimit = snapshot.downloadSpeedLimit
        uploadSpeedLimit = snapshot.uploadSpeedLimit
        peerLimit = snapshot.peerLimit
        seedRatio = snapshot.seedRatio
        seedIdle = snapshot.seedIdle
        trackerText = snapshot.trackerText
    }

    /// Keeps incomplete editor text separate from the last valid domain values.
    struct NumericInput: Equatable, Sendable {
        var downloadSpeedText: String
        var uploadSpeedText: String
        var peerLimitText: String
        var seedRatioText: String
        var seedIdleText: String

        init(draft: TorrentPropertiesDraft) {
            downloadSpeedText = draft.downloadSpeedLimit.limitKBps.map(String.init) ?? ""
            uploadSpeedText = draft.uploadSpeedLimit.limitKBps.map(String.init) ?? ""
            peerLimitText = draft.peerLimit.map(String.init) ?? ""
            seedRatioText = draft.seedRatio.limit.map {
                Int(exactly: $0).map(String.init) ?? String($0)
            } ?? ""
            seedIdleText = draft.seedIdle.limit.map {
                Int(exactly: $0.rounded(.towardZero)).map(String.init) ?? String($0)
            } ?? ""
        }

        fileprivate var downloadSpeed: Int? { Self.boundedInteger(downloadSpeedText, maximum: 999_999) }
        fileprivate var uploadSpeed: Int? { Self.boundedInteger(uploadSpeedText, maximum: 999_999) }
        fileprivate var peerLimit: Int? { Self.boundedInteger(peerLimitText, maximum: 999) }
        fileprivate var seedIdle: Int? { Self.boundedInteger(seedIdleText, maximum: 999_999) }
        fileprivate var seedRatio: Double? {
            let trimmed = seedRatioText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let value = Double(trimmed), value.isFinite, value > 0, value <= 9_999 else { return nil }
            return value
        }

        private static func boundedInteger(_ text: String, maximum: Int) -> Int? {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let value = Int(trimmed), (1 ... maximum).contains(value) else { return nil }
            return value
        }
    }

    func validationMessage(for input: NumericInput, rpcVersion: Int) -> String? {
        if downloadSpeedLimit.isEnabled, input.downloadSpeed == nil {
            return "Download speed must be a whole number from 1 to 999999 KB/s."
        }
        if uploadSpeedLimit.isEnabled, input.uploadSpeed == nil {
            return "Upload speed must be a whole number from 1 to 999999 KB/s."
        }
        if input.peerLimit == nil {
            return "Peer limit must be a whole number from 1 to 999."
        }
        if rpcVersion >= 5, seedRatio.mode == .single, input.seedRatio == nil {
            return "Seed ratio must be greater than 0 and no more than 9999."
        }
        if rpcVersion >= 10, seedIdle.mode == .single, input.seedIdle == nil {
            return "Inactive seeding must be a whole number from 1 to 999999 minutes."
        }
        return nil
    }

    mutating func updateNumericValues(from input: NumericInput, previous: NumericInput) {
        if input.downloadSpeedText != previous.downloadSpeedText, let value = input.downloadSpeed {
            downloadSpeedLimit.limitKBps = value
        }
        if input.uploadSpeedText != previous.uploadSpeedText, let value = input.uploadSpeed {
            uploadSpeedLimit.limitKBps = value
        }
        if input.peerLimitText != previous.peerLimitText, let value = input.peerLimit { peerLimit = value }
        if input.seedRatioText != previous.seedRatioText, let value = input.seedRatio { seedRatio.limit = value }
        if input.seedIdleText != previous.seedIdleText, let value = input.seedIdle { seedIdle.limit = Double(value) }
    }

    func update(forceAllGeneral: Bool = false, includeTrackers: Bool = true) -> TorrentPropertiesUpdate {
        TorrentPropertiesUpdate(
            downloadSpeedLimit: forceAllGeneral || downloadSpeedLimit != original.downloadSpeedLimit ? downloadSpeedLimit : nil,
            uploadSpeedLimit: forceAllGeneral || uploadSpeedLimit != original.uploadSpeedLimit ? uploadSpeedLimit : nil,
            peerLimit: forceAllGeneral || peerLimit != original.peerLimit ? peerLimit : nil,
            seedRatio: forceAllGeneral || seedRatio != original.seedRatio ? seedRatio : nil,
            seedIdle: forceAllGeneral || seedIdle != original.seedIdle ? seedIdle : nil,
            trackerEdit: !includeTrackers || Self.normalizedTrackerText(trackerText) == Self.normalizedTrackerText(original.trackerText)
                ? nil
                : TorrentPropertiesTrackerEdit(
                    originalTrackers: original.trackers,
                    originalTrackerList: original.trackerList,
                    editedText: trackerText
                )
        )
    }

    private static func normalizedTrackerText(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct TorrentPropertiesUpdate: Equatable, Sendable {
    var downloadSpeedLimit: TorrentPropertiesSpeedLimit?
    var uploadSpeedLimit: TorrentPropertiesSpeedLimit?
    var peerLimit: Int?
    var seedRatio: TorrentPropertiesLimitSetting?
    var seedIdle: TorrentPropertiesLimitSetting?
    var trackerEdit: TorrentPropertiesTrackerEdit?

    init(
        downloadSpeedLimit: TorrentPropertiesSpeedLimit? = nil,
        uploadSpeedLimit: TorrentPropertiesSpeedLimit? = nil,
        peerLimit: Int? = nil,
        seedRatio: TorrentPropertiesLimitSetting? = nil,
        seedIdle: TorrentPropertiesLimitSetting? = nil,
        trackerEdit: TorrentPropertiesTrackerEdit? = nil
    ) {
        self.downloadSpeedLimit = downloadSpeedLimit
        self.uploadSpeedLimit = uploadSpeedLimit
        self.peerLimit = peerLimit
        self.seedRatio = seedRatio
        self.seedIdle = seedIdle
        self.trackerEdit = trackerEdit
    }

    func arguments(rpcVersion: Int) -> RPCArguments {
        var arguments: RPCArguments = [:]

        if let downloadSpeedLimit {
            if rpcVersion < 5 {
                arguments["speed-limit-down-enabled"] = .bool(downloadSpeedLimit.isEnabled)
                if downloadSpeedLimit.isEnabled, let limit = downloadSpeedLimit.limitKBps {
                    arguments["speed-limit-down"] = .int(limit)
                }
            } else {
                arguments["downloadLimited"] = .bool(downloadSpeedLimit.isEnabled)
                if downloadSpeedLimit.isEnabled, let limit = downloadSpeedLimit.limitKBps {
                    arguments["downloadLimit"] = .int(limit)
                }
            }
        }

        if let uploadSpeedLimit {
            if rpcVersion < 5 {
                arguments["speed-limit-up-enabled"] = .bool(uploadSpeedLimit.isEnabled)
                if uploadSpeedLimit.isEnabled, let limit = uploadSpeedLimit.limitKBps {
                    arguments["speed-limit-up"] = .int(limit)
                }
            } else {
                arguments["uploadLimited"] = .bool(uploadSpeedLimit.isEnabled)
                if uploadSpeedLimit.isEnabled, let limit = uploadSpeedLimit.limitKBps {
                    arguments["uploadLimit"] = .int(limit)
                }
            }
        }

        if let peerLimit {
            arguments["peer-limit"] = .int(peerLimit)
        }

        if rpcVersion >= 5, let seedRatio {
            arguments["seedRatioMode"] = .int(seedRatio.mode.rawValue)
            if seedRatio.mode == .single, let limit = seedRatio.limit {
                arguments["seedRatioLimit"] = .double(limit)
            }
        }

        if rpcVersion >= 10, let seedIdle {
            arguments["seedIdleMode"] = .int(seedIdle.mode.rawValue)
            if seedIdle.mode == .single, let limit = seedIdle.limit {
                arguments["seedIdleLimit"] = .int(Int(limit))
            }
        }

        if rpcVersion >= 10, let trackerEdit {
            arguments.merge(trackerEdit.arguments(rpcVersion: rpcVersion)) { _, next in next }
        }

        return arguments
    }
}

struct TorrentPropertiesTrackerEdit: Equatable, Sendable {
    var originalTrackers: [TorrentPropertiesTracker]
    var originalTrackerList: String?
    var editedText: String

    init(originalTrackers: [TorrentPropertiesTracker], originalTrackerList: String? = nil, editedText: String) {
        self.originalTrackers = originalTrackers
        self.originalTrackerList = originalTrackerList
        self.editedText = editedText
    }

    func arguments(rpcVersion: Int) -> RPCArguments {
        guard rpcVersion >= 10 else { return [:] }
        if rpcVersion >= 17 {
            return ["trackerList": .string(normalizedTrackerListText(editedText))]
        }
        return legacyDiffArguments()
    }

    private func legacyDiffArguments() -> RPCArguments {
        var remainingOriginals = originalTrackers
        var editedURLs = trackerURLs(from: editedText)

        var editedIndex = 0
        while editedIndex < editedURLs.count {
            guard let originalIndex = remainingOriginals.firstIndex(where: { $0.announce == editedURLs[editedIndex] }) else {
                editedIndex += 1
                continue
            }
            remainingOriginals.remove(at: originalIndex)
            editedURLs.remove(at: editedIndex)
        }

        var replacements: [JSONValue] = []
        var additions: [JSONValue] = []
        for editedURL in editedURLs {
            if remainingOriginals.isEmpty {
                additions.append(.string(editedURL))
            } else {
                let original = remainingOriginals.removeFirst()
                replacements.append(.int(original.id))
                replacements.append(.string(editedURL))
            }
        }

        let removals = remainingOriginals.map { JSONValue.int($0.id) }
        var arguments: RPCArguments = [:]
        if !additions.isEmpty {
            arguments["trackerAdd"] = .array(additions)
        }
        if !replacements.isEmpty {
            arguments["trackerReplace"] = .array(replacements)
        }
        if !removals.isEmpty {
            arguments["trackerRemove"] = .array(removals)
        }
        return arguments
    }

    private func trackerURLs(from text: String) -> [String] {
        normalizedTrackerListText(text)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func normalizedTrackerListText(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension JSONValue {
    var boolOrIntValue: Bool? {
        if let boolValue {
            return boolValue
        }
        if let intValue {
            return intValue != 0
        }
        return nil
    }
}
