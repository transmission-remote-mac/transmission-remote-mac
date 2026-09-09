// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation

enum SessionEncryption: String, CaseIterable, Equatable, Sendable {
    case tolerated
    case preferred
    case required
}

enum SessionSpeedLimitDirection: String, Equatable, Sendable {
    case download = "down"
    case upload = "up"

    var enabledKey: String {
        "speed-limit-\(rawValue)-enabled"
    }

    var limitKey: String {
        "speed-limit-\(rawValue)"
    }
}

struct SessionSpeedLimit: Equatable, Sendable {
    var isEnabled: Bool
    var limitKBps: Int

    init(isEnabled: Bool, limitKBps: Int) {
        self.isEnabled = isEnabled
        self.limitKBps = limitKBps
    }

    init(arguments: RPCArguments, direction: SessionSpeedLimitDirection) {
        isEnabled = arguments[direction.enabledKey].daemonBoolValue ?? false
        limitKBps = arguments[direction.limitKey]?.intValue ?? 0
    }
}

struct DaemonOptions: Equatable, Sendable {
    var downloadDirectory: String
    var portForwardingEnabled: Bool?
    var encryption: SessionEncryption?
    var downloadSpeedLimit: SessionSpeedLimit
    var uploadSpeedLimit: SessionSpeedLimit
    var peerPort: Int?
    var peerPortRandomOnStart: Bool?
    var peerLimitGlobal: Int?
    var peerLimitPerTorrent: Int?
    var legacyPeerLimit: Int?
    var pexEnabled: Bool?
    var dhtEnabled: Bool?
    var seedRatioLimited: Bool?
    var seedRatioLimit: Double?
    var blocklistEnabled: Bool?
    var blocklistURL: String?
    var alternateSpeedEnabled: Bool?
    var alternateSpeedDownKBps: Int?
    var alternateSpeedUpKBps: Int?
    var alternateSpeedTimeEnabled: Bool?
    var alternateSpeedTimeBeginMinutes: Int?
    var alternateSpeedTimeEndMinutes: Int?
    var alternateSpeedTimeDayMask: Int?
    var incompleteDirectoryEnabled: Bool?
    var incompleteDirectory: String?
    var renamePartialFiles: Bool?
    var lpdEnabled: Bool?
    var cacheSizeMB: Int?
    var idleSeedingLimitEnabled: Bool?
    var idleSeedingLimitMinutes: Int?
    var utpEnabled: Bool?
    var downloadQueueEnabled: Bool?
    var downloadQueueSize: Int?
    var seedQueueEnabled: Bool?
    var seedQueueSize: Int?
    var queueStalledEnabled: Bool?
    var queueStalledMinutes: Int?

    init(arguments: RPCArguments, rpcVersion: Int) {
        downloadDirectory = arguments["download-dir"]?.stringValue ?? ""
        portForwardingEnabled = arguments["port-forwarding-enabled"].daemonBoolValue
        encryption = arguments["encryption"]?.stringValue.flatMap(SessionEncryption.init(rawValue:))
        downloadSpeedLimit = SessionSpeedLimit(arguments: arguments, direction: .download)
        uploadSpeedLimit = SessionSpeedLimit(arguments: arguments, direction: .upload)
        blocklistURL = arguments["blocklist-url"]?.stringValue

        if rpcVersion >= 5 {
            peerPort = arguments["peer-port"]?.intValue
            peerPortRandomOnStart = arguments["peer-port-random-on-start"].daemonBoolValue
            peerLimitGlobal = arguments["peer-limit-global"]?.intValue
            peerLimitPerTorrent = arguments["peer-limit-per-torrent"]?.intValue
            pexEnabled = arguments["pex-enabled"].daemonBoolValue
            dhtEnabled = arguments["dht-enabled"].daemonBoolValue
            seedRatioLimited = arguments["seedRatioLimited"].daemonBoolValue
            seedRatioLimit = arguments["seedRatioLimit"]?.doubleValue
            blocklistEnabled = arguments["blocklist-enabled"].daemonBoolValue
            alternateSpeedEnabled = arguments["alt-speed-enabled"].daemonBoolValue
            alternateSpeedDownKBps = arguments["alt-speed-down"]?.intValue
            alternateSpeedUpKBps = arguments["alt-speed-up"]?.intValue
            alternateSpeedTimeEnabled = arguments["alt-speed-time-enabled"].daemonBoolValue
            alternateSpeedTimeBeginMinutes = arguments["alt-speed-time-begin"]?.intValue
            alternateSpeedTimeEndMinutes = arguments["alt-speed-time-end"]?.intValue
            alternateSpeedTimeDayMask = arguments["alt-speed-time-day"]?.intValue
        } else {
            peerPort = arguments["port"]?.intValue
            legacyPeerLimit = arguments["peer-limit"]?.intValue
            pexEnabled = arguments["pex-allowed"].daemonBoolValue
        }

        if rpcVersion >= 7 {
            incompleteDirectoryEnabled = arguments["incomplete-dir-enabled"].daemonBoolValue
            incompleteDirectory = arguments["incomplete-dir"]?.stringValue
        }
        if rpcVersion >= 8 {
            renamePartialFiles = arguments["rename-partial-files"].daemonBoolValue
        }
        if rpcVersion >= 9 {
            lpdEnabled = arguments["lpd-enabled"].daemonBoolValue
        }
        if rpcVersion >= 10 {
            cacheSizeMB = arguments["cache-size-mb"]?.intValue
            idleSeedingLimitEnabled = arguments["idle-seeding-limit-enabled"].daemonBoolValue
            idleSeedingLimitMinutes = arguments["idle-seeding-limit"]?.intValue
        }
        if rpcVersion >= 13 {
            utpEnabled = arguments["utp-enabled"].daemonBoolValue
        }
        if rpcVersion >= 14 {
            downloadQueueEnabled = arguments["download-queue-enabled"].daemonBoolValue
            downloadQueueSize = arguments["download-queue-size"]?.intValue
            seedQueueEnabled = arguments["seed-queue-enabled"].daemonBoolValue
            seedQueueSize = arguments["seed-queue-size"]?.intValue
            queueStalledEnabled = arguments["queue-stalled-enabled"].daemonBoolValue
            queueStalledMinutes = arguments["queue-stalled-minutes"]?.intValue
        }
    }
}

struct DaemonOptionsDraft: Equatable, Sendable {
    var downloadDirectory: String
    var portForwardingEnabled: Bool
    var encryption: SessionEncryption
    var downloadSpeedLimitEnabled: Bool
    var downloadSpeedLimitKBps: String
    var uploadSpeedLimitEnabled: Bool
    var uploadSpeedLimitKBps: String
    var peerPort: String
    var peerPortRandomOnStart: Bool
    var peerLimitGlobal: String
    var peerLimitPerTorrent: String
    var legacyPeerLimit: String
    var pexEnabled: Bool
    var dhtEnabled: Bool
    var seedRatioLimited: Bool
    var seedRatioLimit: String
    var blocklistEnabled: Bool
    var blocklistURL: String
    var alternateSpeedEnabled: Bool
    var alternateSpeedDownKBps: String
    var alternateSpeedUpKBps: String
    var alternateSpeedTimeEnabled: Bool
    var alternateSpeedTimeBegin: String
    var alternateSpeedTimeEnd: String
    var alternateSpeedSunday: Bool
    var alternateSpeedMonday: Bool
    var alternateSpeedTuesday: Bool
    var alternateSpeedWednesday: Bool
    var alternateSpeedThursday: Bool
    var alternateSpeedFriday: Bool
    var alternateSpeedSaturday: Bool
    var incompleteDirectoryEnabled: Bool
    var incompleteDirectory: String
    var renamePartialFiles: Bool
    var lpdEnabled: Bool
    var cacheSizeMB: String
    var idleSeedingLimitEnabled: Bool
    var idleSeedingLimitMinutes: String
    var utpEnabled: Bool
    var downloadQueueEnabled: Bool
    var downloadQueueSize: String
    var seedQueueEnabled: Bool
    var seedQueueSize: String
    var queueStalledEnabled: Bool
    var queueStalledMinutes: String

    init(options: DaemonOptions) {
        downloadDirectory = options.downloadDirectory
        portForwardingEnabled = options.portForwardingEnabled ?? false
        encryption = options.encryption ?? .tolerated
        downloadSpeedLimitEnabled = options.downloadSpeedLimit.isEnabled
        downloadSpeedLimitKBps = "\(options.downloadSpeedLimit.limitKBps)"
        uploadSpeedLimitEnabled = options.uploadSpeedLimit.isEnabled
        uploadSpeedLimitKBps = "\(options.uploadSpeedLimit.limitKBps)"
        peerPort = Self.text(options.peerPort)
        peerPortRandomOnStart = options.peerPortRandomOnStart ?? false
        peerLimitGlobal = Self.text(options.peerLimitGlobal)
        peerLimitPerTorrent = Self.text(options.peerLimitPerTorrent)
        legacyPeerLimit = Self.text(options.legacyPeerLimit)
        pexEnabled = options.pexEnabled ?? false
        dhtEnabled = options.dhtEnabled ?? false
        seedRatioLimited = options.seedRatioLimited ?? false
        seedRatioLimit = Self.text(options.seedRatioLimit)
        blocklistEnabled = options.blocklistEnabled ?? false
        blocklistURL = options.blocklistURL ?? ""
        alternateSpeedEnabled = options.alternateSpeedEnabled ?? false
        alternateSpeedDownKBps = Self.text(options.alternateSpeedDownKBps)
        alternateSpeedUpKBps = Self.text(options.alternateSpeedUpKBps)
        alternateSpeedTimeEnabled = options.alternateSpeedTimeEnabled ?? false
        alternateSpeedTimeBegin = Self.timeText(options.alternateSpeedTimeBeginMinutes)
        alternateSpeedTimeEnd = Self.timeText(options.alternateSpeedTimeEndMinutes)
        let alternateDayMask = options.alternateSpeedTimeDayMask ?? 0
        alternateSpeedSunday = alternateDayMask & 1 != 0
        alternateSpeedMonday = alternateDayMask & 2 != 0
        alternateSpeedTuesday = alternateDayMask & 4 != 0
        alternateSpeedWednesday = alternateDayMask & 8 != 0
        alternateSpeedThursday = alternateDayMask & 16 != 0
        alternateSpeedFriday = alternateDayMask & 32 != 0
        alternateSpeedSaturday = alternateDayMask & 64 != 0
        incompleteDirectoryEnabled = options.incompleteDirectoryEnabled ?? false
        incompleteDirectory = options.incompleteDirectory ?? ""
        renamePartialFiles = options.renamePartialFiles ?? false
        lpdEnabled = options.lpdEnabled ?? false
        cacheSizeMB = Self.text(options.cacheSizeMB)
        idleSeedingLimitEnabled = options.idleSeedingLimitEnabled ?? false
        idleSeedingLimitMinutes = Self.text(options.idleSeedingLimitMinutes)
        utpEnabled = options.utpEnabled ?? false
        downloadQueueEnabled = options.downloadQueueEnabled ?? false
        downloadQueueSize = Self.text(options.downloadQueueSize)
        seedQueueEnabled = options.seedQueueEnabled ?? false
        seedQueueSize = Self.text(options.seedQueueSize)
        queueStalledEnabled = options.queueStalledEnabled ?? false
        queueStalledMinutes = Self.text(options.queueStalledMinutes)
    }

    func hasChanges(comparedTo options: DaemonOptions, capabilities: SessionCapabilities) -> Bool {
        let original = DaemonOptionsDraft(options: options)
        guard normalized(downloadDirectory) == normalized(original.downloadDirectory),
              portForwardingEnabled == original.portForwardingEnabled,
              encryption == original.encryption,
              downloadSpeedLimitEnabled == original.downloadSpeedLimitEnabled,
              normalized(downloadSpeedLimitKBps) == normalized(original.downloadSpeedLimitKBps),
              uploadSpeedLimitEnabled == original.uploadSpeedLimitEnabled,
              normalized(uploadSpeedLimitKBps) == normalized(original.uploadSpeedLimitKBps)
        else {
            return true
        }

        if capabilities.hasModernSpeedKeys {
            guard normalized(peerPort) == normalized(original.peerPort),
                  peerPortRandomOnStart == original.peerPortRandomOnStart,
                  normalized(peerLimitGlobal) == normalized(original.peerLimitGlobal),
                  normalized(peerLimitPerTorrent) == normalized(original.peerLimitPerTorrent),
                  pexEnabled == original.pexEnabled,
                  dhtEnabled == original.dhtEnabled,
                  seedRatioLimited == original.seedRatioLimited,
                  blocklistEnabled == original.blocklistEnabled,
                  alternateSpeedEnabled == original.alternateSpeedEnabled,
                  normalized(alternateSpeedDownKBps) == normalized(original.alternateSpeedDownKBps),
                  normalized(alternateSpeedUpKBps) == normalized(original.alternateSpeedUpKBps),
                  alternateSpeedTimeEnabled == original.alternateSpeedTimeEnabled,
                  normalized(alternateSpeedTimeBegin) == normalized(original.alternateSpeedTimeBegin),
                  normalized(alternateSpeedTimeEnd) == normalized(original.alternateSpeedTimeEnd),
                  alternateSpeedDayMask == original.alternateSpeedDayMask
            else {
                return true
            }
            if seedRatioLimited,
               normalized(seedRatioLimit) != normalized(original.seedRatioLimit) {
                return true
            }
            if capabilities.hasBlocklistURL,
               normalized(blocklistURL) != normalized(original.blocklistURL) {
                return true
            }
        } else {
            guard normalized(peerPort) == normalized(original.peerPort),
                  normalized(legacyPeerLimit) == normalized(original.legacyPeerLimit),
                  pexEnabled == original.pexEnabled
            else {
                return true
            }
        }

        if capabilities.hasIncompleteDirectory {
            guard incompleteDirectoryEnabled == original.incompleteDirectoryEnabled,
                  normalized(incompleteDirectory) == normalized(original.incompleteDirectory)
            else {
                return true
            }
        }

        if capabilities.hasRenamePartialFiles, renamePartialFiles != original.renamePartialFiles {
            return true
        }

        if capabilities.hasLPD, lpdEnabled != original.lpdEnabled {
            return true
        }

        if capabilities.hasCacheSize {
            guard normalized(cacheSizeMB) == normalized(original.cacheSizeMB) else {
                return true
            }
        }

        if capabilities.hasSeedIdle {
            guard idleSeedingLimitEnabled == original.idleSeedingLimitEnabled else {
                return true
            }
            if idleSeedingLimitEnabled,
               normalized(idleSeedingLimitMinutes) != normalized(original.idleSeedingLimitMinutes) {
                return true
            }
        }

        if capabilities.hasUTP, utpEnabled != original.utpEnabled {
            return true
        }

        if capabilities.hasQueueControls {
            guard downloadQueueEnabled == original.downloadQueueEnabled,
                  normalized(downloadQueueSize) == normalized(original.downloadQueueSize),
                  seedQueueEnabled == original.seedQueueEnabled,
                  normalized(seedQueueSize) == normalized(original.seedQueueSize),
                  queueStalledEnabled == original.queueStalledEnabled,
                  normalized(queueStalledMinutes) == normalized(original.queueStalledMinutes)
            else {
                return true
            }
        }

        return false
    }

    func validationIssues(capabilities: SessionCapabilities) -> [String] {
        var issues: [String] = []

        validateRequiredPath(downloadDirectory, label: "Download folder", issues: &issues)
        if downloadSpeedLimitEnabled {
            validateNonNegativeInt(downloadSpeedLimitKBps, label: "Download speed limit", issues: &issues)
        }
        if uploadSpeedLimitEnabled {
            validateNonNegativeInt(uploadSpeedLimitKBps, label: "Upload speed limit", issues: &issues)
        }
        if capabilities.hasModernSpeedKeys {
            validatePeerPort(peerPort, issues: &issues)
            validateNonNegativeInt(peerLimitGlobal, label: "Global peer limit", issues: &issues)
            validateNonNegativeInt(peerLimitPerTorrent, label: "Per-torrent peer limit", issues: &issues)
            if seedRatioLimited {
                validateNonNegativeDouble(seedRatioLimit, label: "Seed ratio limit", issues: &issues)
            }
            if capabilities.hasBlocklistURL, blocklistEnabled {
                validateRequiredText(blocklistURL, label: "Blocklist URL", issues: &issues)
            }
            validateNonNegativeInt(alternateSpeedDownKBps, label: "Alternate download speed", issues: &issues)
            validateNonNegativeInt(alternateSpeedUpKBps, label: "Alternate upload speed", issues: &issues)
            if alternateSpeedTimeEnabled {
                validateTime(alternateSpeedTimeBegin, label: "Alternate speed start time", issues: &issues)
                validateTime(alternateSpeedTimeEnd, label: "Alternate speed end time", issues: &issues)
                if alternateSpeedDayMask == 0 {
                    issues.append("Alternate speed schedule must include at least one day.")
                }
            }
        } else {
            validatePeerPort(peerPort, issues: &issues)
            validateNonNegativeInt(legacyPeerLimit, label: "Peer limit", issues: &issues)
        }
        if capabilities.hasIncompleteDirectory, incompleteDirectoryEnabled {
            validateRequiredPath(incompleteDirectory, label: "Incomplete folder", issues: &issues)
        }
        if capabilities.hasCacheSize {
            validateNonNegativeInt(cacheSizeMB, label: "Cache size", issues: &issues)
        }
        if capabilities.hasSeedIdle, idleSeedingLimitEnabled {
            validateNonNegativeInt(idleSeedingLimitMinutes, label: "Idle seeding limit", issues: &issues)
        }
        if capabilities.hasQueueControls {
            validateNonNegativeInt(downloadQueueSize, label: "Download queue size", issues: &issues)
            validateNonNegativeInt(seedQueueSize, label: "Seed queue size", issues: &issues)
            validateNonNegativeInt(queueStalledMinutes, label: "Stalled queue minutes", issues: &issues)
        }

        return issues
    }

    func update(comparedTo options: DaemonOptions, capabilities: SessionCapabilities) -> DaemonOptionsUpdate? {
        guard validationIssues(capabilities: capabilities).isEmpty else { return nil }

        var update = DaemonOptionsUpdate()
        let nextDownloadDirectory = normalized(downloadDirectory)
        let downloadLimit = intValue(downloadSpeedLimitKBps)
        let uploadLimit = intValue(uploadSpeedLimitKBps)

        if nextDownloadDirectory != normalized(options.downloadDirectory) {
            update.downloadDirectory = nextDownloadDirectory
        }
        if portForwardingEnabled != (options.portForwardingEnabled ?? false) {
            update.portForwardingEnabled = portForwardingEnabled
        }
        if encryption != (options.encryption ?? .tolerated) {
            update.encryption = encryption
        }

        if downloadSpeedLimitEnabled != options.downloadSpeedLimit.isEnabled {
            update.downloadSpeedLimitEnabled = downloadSpeedLimitEnabled
        }
        if downloadSpeedLimitEnabled,
           (downloadSpeedLimitEnabled != options.downloadSpeedLimit.isEnabled || downloadLimit != options.downloadSpeedLimit.limitKBps) {
            update.downloadSpeedLimitKBps = downloadLimit
        }

        if uploadSpeedLimitEnabled != options.uploadSpeedLimit.isEnabled {
            update.uploadSpeedLimitEnabled = uploadSpeedLimitEnabled
        }
        if uploadSpeedLimitEnabled,
           (uploadSpeedLimitEnabled != options.uploadSpeedLimit.isEnabled || uploadLimit != options.uploadSpeedLimit.limitKBps) {
            update.uploadSpeedLimitKBps = uploadLimit
        }

        if capabilities.hasModernSpeedKeys {
            let nextPeerPort = intValue(peerPort)
            let nextPeerLimitGlobal = intValue(peerLimitGlobal)
            let nextPeerLimitPerTorrent = intValue(peerLimitPerTorrent)
            let nextSeedRatioLimit = doubleValue(seedRatioLimit)
            let nextBlocklistURL = normalized(blocklistURL)
            let alternateDown = intValue(alternateSpeedDownKBps)
            let alternateUp = intValue(alternateSpeedUpKBps)
            let alternateBegin = timeValue(alternateSpeedTimeBegin)
            let alternateEnd = timeValue(alternateSpeedTimeEnd)

            if nextPeerPort != options.peerPort {
                update.peerPort = nextPeerPort
            }
            if peerPortRandomOnStart != (options.peerPortRandomOnStart ?? false) {
                update.peerPortRandomOnStart = peerPortRandomOnStart
            }
            if nextPeerLimitGlobal != options.peerLimitGlobal {
                update.peerLimitGlobal = nextPeerLimitGlobal
            }
            if nextPeerLimitPerTorrent != options.peerLimitPerTorrent {
                update.peerLimitPerTorrent = nextPeerLimitPerTorrent
            }
            if pexEnabled != (options.pexEnabled ?? false) {
                update.pexEnabled = pexEnabled
            }
            if dhtEnabled != (options.dhtEnabled ?? false) {
                update.dhtEnabled = dhtEnabled
            }
            if seedRatioLimited != (options.seedRatioLimited ?? false) {
                update.seedRatioLimited = seedRatioLimited
            }
            if seedRatioLimited,
               (seedRatioLimited != (options.seedRatioLimited ?? false) || nextSeedRatioLimit != options.seedRatioLimit) {
                update.seedRatioLimit = nextSeedRatioLimit
            }
            if blocklistEnabled != (options.blocklistEnabled ?? false) {
                update.blocklistEnabled = blocklistEnabled
            }
            if capabilities.hasBlocklistURL,
               blocklistEnabled,
               nextBlocklistURL != normalized(options.blocklistURL ?? "") {
                update.blocklistURL = nextBlocklistURL
            }
            if alternateSpeedEnabled != (options.alternateSpeedEnabled ?? false) {
                update.alternateSpeedEnabled = alternateSpeedEnabled
            }
            if alternateDown != options.alternateSpeedDownKBps {
                update.alternateSpeedDownKBps = alternateDown
            }
            if alternateUp != options.alternateSpeedUpKBps {
                update.alternateSpeedUpKBps = alternateUp
            }
            if alternateSpeedTimeEnabled != (options.alternateSpeedTimeEnabled ?? false) {
                update.alternateSpeedTimeEnabled = alternateSpeedTimeEnabled
            }
            if alternateSpeedTimeEnabled,
               (alternateSpeedTimeEnabled != (options.alternateSpeedTimeEnabled ?? false)
                || alternateBegin != options.alternateSpeedTimeBeginMinutes) {
                update.alternateSpeedTimeBeginMinutes = alternateBegin
            }
            if alternateSpeedTimeEnabled,
               (alternateSpeedTimeEnabled != (options.alternateSpeedTimeEnabled ?? false)
                || alternateEnd != options.alternateSpeedTimeEndMinutes) {
                update.alternateSpeedTimeEndMinutes = alternateEnd
            }
            if alternateSpeedTimeEnabled,
               (alternateSpeedTimeEnabled != (options.alternateSpeedTimeEnabled ?? false)
                || alternateSpeedDayMask != options.alternateSpeedTimeDayMask) {
                update.alternateSpeedTimeDayMask = alternateSpeedDayMask
            }
        } else {
            let nextPeerPort = intValue(peerPort)
            let nextPeerLimit = intValue(legacyPeerLimit)

            if nextPeerPort != options.peerPort {
                update.peerPort = nextPeerPort
            }
            if nextPeerLimit != options.legacyPeerLimit {
                update.legacyPeerLimit = nextPeerLimit
            }
            if pexEnabled != (options.pexEnabled ?? false) {
                update.pexEnabled = pexEnabled
            }
        }

        if capabilities.hasIncompleteDirectory {
            let nextIncompleteDirectory = normalized(incompleteDirectory)
            if incompleteDirectoryEnabled != (options.incompleteDirectoryEnabled ?? false) {
                update.incompleteDirectoryEnabled = incompleteDirectoryEnabled
            }
            if incompleteDirectoryEnabled,
               (incompleteDirectoryEnabled != (options.incompleteDirectoryEnabled ?? false)
                || nextIncompleteDirectory != normalized(options.incompleteDirectory ?? "")) {
                update.incompleteDirectory = nextIncompleteDirectory
            }
        }

        if capabilities.hasRenamePartialFiles, renamePartialFiles != (options.renamePartialFiles ?? false) {
            update.renamePartialFiles = renamePartialFiles
        }

        if capabilities.hasLPD, lpdEnabled != (options.lpdEnabled ?? false) {
            update.lpdEnabled = lpdEnabled
        }

        if capabilities.hasCacheSize {
            let nextCacheSize = intValue(cacheSizeMB)
            if nextCacheSize != options.cacheSizeMB {
                update.cacheSizeMB = nextCacheSize
            }
        }

        if capabilities.hasSeedIdle {
            let nextIdleSeedingLimit = intValue(idleSeedingLimitMinutes)

            if idleSeedingLimitEnabled != (options.idleSeedingLimitEnabled ?? false) {
                update.idleSeedingLimitEnabled = idleSeedingLimitEnabled
            }
            if idleSeedingLimitEnabled,
               (idleSeedingLimitEnabled != (options.idleSeedingLimitEnabled ?? false)
                || nextIdleSeedingLimit != options.idleSeedingLimitMinutes) {
                update.idleSeedingLimitMinutes = nextIdleSeedingLimit
            }
        }

        if capabilities.hasUTP, utpEnabled != (options.utpEnabled ?? false) {
            update.utpEnabled = utpEnabled
        }

        if capabilities.hasQueueControls {
            let nextDownloadQueueSize = intValue(downloadQueueSize)
            let nextSeedQueueSize = intValue(seedQueueSize)
            let nextStalledMinutes = intValue(queueStalledMinutes)

            if downloadQueueEnabled != (options.downloadQueueEnabled ?? false) {
                update.downloadQueueEnabled = downloadQueueEnabled
            }
            if nextDownloadQueueSize != options.downloadQueueSize {
                update.downloadQueueSize = nextDownloadQueueSize
            }
            if seedQueueEnabled != (options.seedQueueEnabled ?? false) {
                update.seedQueueEnabled = seedQueueEnabled
            }
            if nextSeedQueueSize != options.seedQueueSize {
                update.seedQueueSize = nextSeedQueueSize
            }
            if queueStalledEnabled != (options.queueStalledEnabled ?? false) {
                update.queueStalledEnabled = queueStalledEnabled
            }
            if nextStalledMinutes != options.queueStalledMinutes {
                update.queueStalledMinutes = nextStalledMinutes
            }
        }

        guard update.arguments(rpcVersion: capabilities.rpcVersion).isEmpty == false else { return nil }
        return update
    }

    private static func text(_ value: Int?) -> String {
        value.map(String.init) ?? ""
    }

    private static func text(_ value: Double?) -> String {
        guard let value else { return "" }
        if value.rounded() == value {
            return "\(Int(value))"
        }
        return "\(value)"
    }

    private static func timeText(_ minutes: Int?) -> String {
        guard let minutes else { return "" }
        let hours = minutes / 60
        let mins = minutes % 60
        return String(format: "%02d:%02d", hours, mins)
    }

    private var alternateSpeedDayMask: Int {
        var mask = 0
        if alternateSpeedSunday { mask |= 1 }
        if alternateSpeedMonday { mask |= 2 }
        if alternateSpeedTuesday { mask |= 4 }
        if alternateSpeedWednesday { mask |= 8 }
        if alternateSpeedThursday { mask |= 16 }
        if alternateSpeedFriday { mask |= 32 }
        if alternateSpeedSaturday { mask |= 64 }
        return mask
    }

    private func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func intValue(_ text: String) -> Int? {
        Int(normalized(text))
    }

    private func doubleValue(_ text: String) -> Double? {
        Double(normalized(text))
    }

    private func timeValue(_ text: String) -> Int? {
        let value = normalized(text)
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let hour = Int(String(parts[0])),
              let minute = Int(String(parts[1])),
              (0...23).contains(hour),
              (0...59).contains(minute)
        else {
            return nil
        }
        return hour * 60 + minute
    }

    private func validateNonNegativeInt(_ text: String, label: String, issues: inout [String]) {
        let value = normalized(text)
        guard !value.isEmpty else {
            issues.append("\(label) is required.")
            return
        }
        guard let intValue = Int(value), intValue >= 0 else {
            issues.append("\(label) must be a whole number.")
            return
        }
    }

    private func validatePeerPort(_ text: String, issues: inout [String]) {
        let value = normalized(text)
        guard !value.isEmpty else {
            issues.append("Peer port is required.")
            return
        }
        guard let intValue = Int(value), (1...65_535).contains(intValue) else {
            issues.append("Peer port must be a whole number from 1 to 65535.")
            return
        }
    }

    private func validateNonNegativeDouble(_ text: String, label: String, issues: inout [String]) {
        let value = normalized(text)
        guard !value.isEmpty else {
            issues.append("\(label) is required.")
            return
        }
        guard let doubleValue = Double(value), doubleValue >= 0 else {
            issues.append("\(label) must be a number.")
            return
        }
    }

    private func validateRequiredPath(_ text: String, label: String, issues: inout [String]) {
        validateRequiredText(text, label: label, issues: &issues)
    }

    private func validateRequiredText(_ text: String, label: String, issues: inout [String]) {
        guard !normalized(text).isEmpty else {
            issues.append("\(label) is required.")
            return
        }
    }

    private func validateTime(_ text: String, label: String, issues: inout [String]) {
        let value = normalized(text)
        guard !value.isEmpty else {
            issues.append("\(label) is required.")
            return
        }
        guard timeValue(value) != nil else {
            issues.append("\(label) must use HH:MM.")
            return
        }
    }
}

struct DaemonOptionsUpdate: Equatable, Sendable {
    var downloadDirectory: String?
    var portForwardingEnabled: Bool?
    var encryption: SessionEncryption?
    var downloadSpeedLimitEnabled: Bool?
    var downloadSpeedLimitKBps: Int?
    var uploadSpeedLimitEnabled: Bool?
    var uploadSpeedLimitKBps: Int?
    var peerPort: Int?
    var peerPortRandomOnStart: Bool?
    var peerLimitGlobal: Int?
    var peerLimitPerTorrent: Int?
    var legacyPeerLimit: Int?
    var pexEnabled: Bool?
    var dhtEnabled: Bool?
    var seedRatioLimited: Bool?
    var seedRatioLimit: Double?
    var blocklistEnabled: Bool?
    var blocklistURL: String?
    var alternateSpeedEnabled: Bool?
    var alternateSpeedDownKBps: Int?
    var alternateSpeedUpKBps: Int?
    var alternateSpeedTimeEnabled: Bool?
    var alternateSpeedTimeBeginMinutes: Int?
    var alternateSpeedTimeEndMinutes: Int?
    var alternateSpeedTimeDayMask: Int?
    var incompleteDirectoryEnabled: Bool?
    var incompleteDirectory: String?
    var renamePartialFiles: Bool?
    var lpdEnabled: Bool?
    var cacheSizeMB: Int?
    var idleSeedingLimitEnabled: Bool?
    var idleSeedingLimitMinutes: Int?
    var utpEnabled: Bool?
    var downloadQueueEnabled: Bool?
    var downloadQueueSize: Int?
    var seedQueueEnabled: Bool?
    var seedQueueSize: Int?
    var queueStalledEnabled: Bool?
    var queueStalledMinutes: Int?

    init(
        downloadDirectory: String? = nil,
        portForwardingEnabled: Bool? = nil,
        encryption: SessionEncryption? = nil,
        downloadSpeedLimitEnabled: Bool? = nil,
        downloadSpeedLimitKBps: Int? = nil,
        uploadSpeedLimitEnabled: Bool? = nil,
        uploadSpeedLimitKBps: Int? = nil,
        peerPort: Int? = nil,
        peerPortRandomOnStart: Bool? = nil,
        peerLimitGlobal: Int? = nil,
        peerLimitPerTorrent: Int? = nil,
        legacyPeerLimit: Int? = nil,
        pexEnabled: Bool? = nil,
        dhtEnabled: Bool? = nil,
        seedRatioLimited: Bool? = nil,
        seedRatioLimit: Double? = nil,
        blocklistEnabled: Bool? = nil,
        blocklistURL: String? = nil,
        alternateSpeedEnabled: Bool? = nil,
        alternateSpeedDownKBps: Int? = nil,
        alternateSpeedUpKBps: Int? = nil,
        alternateSpeedTimeEnabled: Bool? = nil,
        alternateSpeedTimeBeginMinutes: Int? = nil,
        alternateSpeedTimeEndMinutes: Int? = nil,
        alternateSpeedTimeDayMask: Int? = nil,
        incompleteDirectoryEnabled: Bool? = nil,
        incompleteDirectory: String? = nil,
        renamePartialFiles: Bool? = nil,
        lpdEnabled: Bool? = nil,
        cacheSizeMB: Int? = nil,
        idleSeedingLimitEnabled: Bool? = nil,
        idleSeedingLimitMinutes: Int? = nil,
        utpEnabled: Bool? = nil,
        downloadQueueEnabled: Bool? = nil,
        downloadQueueSize: Int? = nil,
        seedQueueEnabled: Bool? = nil,
        seedQueueSize: Int? = nil,
        queueStalledEnabled: Bool? = nil,
        queueStalledMinutes: Int? = nil
    ) {
        self.downloadDirectory = downloadDirectory
        self.portForwardingEnabled = portForwardingEnabled
        self.encryption = encryption
        self.downloadSpeedLimitEnabled = downloadSpeedLimitEnabled
        self.downloadSpeedLimitKBps = downloadSpeedLimitKBps
        self.uploadSpeedLimitEnabled = uploadSpeedLimitEnabled
        self.uploadSpeedLimitKBps = uploadSpeedLimitKBps
        self.peerPort = peerPort
        self.peerPortRandomOnStart = peerPortRandomOnStart
        self.peerLimitGlobal = peerLimitGlobal
        self.peerLimitPerTorrent = peerLimitPerTorrent
        self.legacyPeerLimit = legacyPeerLimit
        self.pexEnabled = pexEnabled
        self.dhtEnabled = dhtEnabled
        self.seedRatioLimited = seedRatioLimited
        self.seedRatioLimit = seedRatioLimit
        self.blocklistEnabled = blocklistEnabled
        self.blocklistURL = blocklistURL
        self.alternateSpeedEnabled = alternateSpeedEnabled
        self.alternateSpeedDownKBps = alternateSpeedDownKBps
        self.alternateSpeedUpKBps = alternateSpeedUpKBps
        self.alternateSpeedTimeEnabled = alternateSpeedTimeEnabled
        self.alternateSpeedTimeBeginMinutes = alternateSpeedTimeBeginMinutes
        self.alternateSpeedTimeEndMinutes = alternateSpeedTimeEndMinutes
        self.alternateSpeedTimeDayMask = alternateSpeedTimeDayMask
        self.incompleteDirectoryEnabled = incompleteDirectoryEnabled
        self.incompleteDirectory = incompleteDirectory
        self.renamePartialFiles = renamePartialFiles
        self.lpdEnabled = lpdEnabled
        self.cacheSizeMB = cacheSizeMB
        self.idleSeedingLimitEnabled = idleSeedingLimitEnabled
        self.idleSeedingLimitMinutes = idleSeedingLimitMinutes
        self.utpEnabled = utpEnabled
        self.downloadQueueEnabled = downloadQueueEnabled
        self.downloadQueueSize = downloadQueueSize
        self.seedQueueEnabled = seedQueueEnabled
        self.seedQueueSize = seedQueueSize
        self.queueStalledEnabled = queueStalledEnabled
        self.queueStalledMinutes = queueStalledMinutes
    }

    func arguments(rpcVersion: Int) -> RPCArguments {
        var arguments: RPCArguments = [:]
        arguments.set("download-dir", downloadDirectory)
        arguments.set("port-forwarding-enabled", portForwardingEnabled)
        arguments.set("encryption", encryption?.rawValue)
        arguments.set("speed-limit-down-enabled", downloadSpeedLimitEnabled)
        if downloadSpeedLimitEnabled != false {
            arguments.set("speed-limit-down", downloadSpeedLimitKBps)
        }
        arguments.set("speed-limit-up-enabled", uploadSpeedLimitEnabled)
        if uploadSpeedLimitEnabled != false {
            arguments.set("speed-limit-up", uploadSpeedLimitKBps)
        }

        if rpcVersion >= 5 {
            arguments.set("peer-limit-global", peerLimitGlobal)
            arguments.set("peer-limit-per-torrent", peerLimitPerTorrent)
            arguments.set("peer-port", peerPort)
            arguments.set("pex-enabled", pexEnabled)
            arguments.set("peer-port-random-on-start", peerPortRandomOnStart)
            arguments.set("dht-enabled", dhtEnabled)
            arguments.set("seedRatioLimited", seedRatioLimited)
            if seedRatioLimited != false {
                arguments.set("seedRatioLimit", seedRatioLimit)
            }
            arguments.set("blocklist-enabled", blocklistEnabled)
            arguments.set("alt-speed-enabled", alternateSpeedEnabled)
            arguments.set("alt-speed-down", alternateSpeedDownKBps)
            arguments.set("alt-speed-up", alternateSpeedUpKBps)
            arguments.set("alt-speed-time-enabled", alternateSpeedTimeEnabled)
            if alternateSpeedTimeEnabled != false {
                arguments.set("alt-speed-time-begin", alternateSpeedTimeBeginMinutes)
                arguments.set("alt-speed-time-end", alternateSpeedTimeEndMinutes)
                arguments.set("alt-speed-time-day", alternateSpeedTimeDayMask)
            }
            if rpcVersion >= 11, blocklistEnabled != false {
                arguments.set("blocklist-url", blocklistURL)
            }
        } else {
            arguments.set("peer-limit", legacyPeerLimit ?? peerLimitGlobal)
            arguments.set("port", peerPort)
            arguments.set("pex-allowed", pexEnabled)
        }

        if rpcVersion >= 7 {
            arguments.set("incomplete-dir-enabled", incompleteDirectoryEnabled)
            if incompleteDirectoryEnabled != false {
                arguments.set("incomplete-dir", incompleteDirectory)
            }
        }
        if rpcVersion >= 8 {
            arguments.set("rename-partial-files", renamePartialFiles)
        }
        if rpcVersion >= 9 {
            arguments.set("lpd-enabled", lpdEnabled)
        }
        if rpcVersion >= 10 {
            arguments.set("cache-size-mb", cacheSizeMB)
            arguments.set("idle-seeding-limit-enabled", idleSeedingLimitEnabled)
            if idleSeedingLimitEnabled != false {
                arguments.set("idle-seeding-limit", idleSeedingLimitMinutes)
            }
        }
        if rpcVersion >= 13 {
            arguments.set("utp-enabled", utpEnabled)
        }
        if rpcVersion >= 14 {
            arguments.set("download-queue-enabled", downloadQueueEnabled)
            arguments.set("download-queue-size", downloadQueueSize)
            arguments.set("seed-queue-enabled", seedQueueEnabled)
            arguments.set("seed-queue-size", seedQueueSize)
            arguments.set("queue-stalled-enabled", queueStalledEnabled)
            arguments.set("queue-stalled-minutes", queueStalledMinutes)
        }

        return arguments
    }
}

private extension Dictionary where Key == String, Value == JSONValue {
    mutating func set(_ key: String, _ value: String?) {
        guard let value else { return }
        self[key] = .string(value)
    }

    mutating func set(_ key: String, _ value: Int?) {
        guard let value else { return }
        self[key] = .int(value)
    }

    mutating func set(_ key: String, _ value: Double?) {
        guard let value else { return }
        self[key] = .double(value)
    }

    mutating func set(_ key: String, _ value: Bool?) {
        guard let value else { return }
        self[key] = .bool(value)
    }
}

private extension Optional where Wrapped == JSONValue {
    var daemonBoolValue: Bool? {
        switch self {
        case .some(.bool(let value)):
            return value
        case .some(.int(let value)):
            return value != 0
        case .some(.double(let value)):
            return value != 0
        default:
            return nil
        }
    }
}
