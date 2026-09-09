// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation

enum SessionSpeedPreset: Hashable, Sendable {
    case unlimited
    case limited(Int)

    static let downloadPresets: [SessionSpeedPreset] = [
        .unlimited,
        .limited(50),
        .limited(100),
        .limited(250),
        .limited(500),
        .limited(1_000),
        .limited(2_500)
    ]

    static let uploadPresets: [SessionSpeedPreset] = [
        .unlimited,
        .limited(10),
        .limited(25),
        .limited(50),
        .limited(100),
        .limited(250),
        .limited(500)
    ]

    var limitKBps: Int? {
        switch self {
        case .unlimited: nil
        case .limited(let limitKBps): limitKBps
        }
    }

    var title: String {
        switch self {
        case .unlimited: "Unlimited"
        case .limited(let limitKBps): "\(limitKBps) KB/s"
        }
    }
}

struct SessionInfo: Equatable, Sendable {
    var rpcVersion: Int
    var version: String
    var downloadDir: String
    var downloadDirFreeSpace: Int64?
    var daemonOptions: DaemonOptions

    var capabilities: SessionCapabilities {
        SessionCapabilities(rpcVersion: rpcVersion)
    }

    var isAlternateSpeedEnabled: Bool {
        capabilities.hasAlternateSpeedSchedule && daemonOptions.alternateSpeedEnabled == true
    }

    var activeDownloadSpeedLimitKBps: Int? {
        if isAlternateSpeedEnabled {
            return daemonOptions.alternateSpeedDownKBps
        }
        return daemonOptions.downloadSpeedLimit.isEnabled
            ? daemonOptions.downloadSpeedLimit.limitKBps
            : nil
    }

    var activeUploadSpeedLimitKBps: Int? {
        if isAlternateSpeedEnabled {
            return daemonOptions.alternateSpeedUpKBps
        }
        return daemonOptions.uploadSpeedLimit.isEnabled
            ? daemonOptions.uploadSpeedLimit.limitKBps
            : nil
    }

    var activeSpeedLimitsDisplay: String {
        let prefix = isAlternateSpeedEnabled ? "Alt limits" : "Limits"
        return "\(prefix): ↓ \(Self.speedLimitDisplay(activeDownloadSpeedLimitKBps)) · ↑ \(Self.speedLimitDisplay(activeUploadSpeedLimitKBps))"
    }

    func isCurrentSpeedPreset(_ preset: SessionSpeedPreset, direction: SessionSpeedLimitDirection) -> Bool {
        guard !isAlternateSpeedEnabled else { return false }
        let speedLimit = switch direction {
        case .download: daemonOptions.downloadSpeedLimit
        case .upload: daemonOptions.uploadSpeedLimit
        }
        switch preset {
        case .unlimited:
            return !speedLimit.isEnabled
        case .limited(let limitKBps):
            return speedLimit.isEnabled && speedLimit.limitKBps == limitKBps
        }
    }

    init(arguments: RPCArguments) {
        rpcVersion = arguments["rpc-version"]?.intValue ?? 0
        version = arguments["version"]?.stringValue ?? ""
        downloadDir = arguments["download-dir"]?.stringValue ?? ""
        downloadDirFreeSpace = arguments["download-dir-free-space"]?.int64Value
        daemonOptions = DaemonOptions(arguments: arguments, rpcVersion: rpcVersion)
    }

    private static func speedLimitDisplay(_ limitKBps: Int?) -> String {
        limitKBps.map { "\($0) KB/s" } ?? "Unlimited"
    }
}

struct SessionCapabilities: Equatable, Sendable {
    var rpcVersion: Int

    var hasSessionStats: Bool { rpcVersion >= 4 }
    var hasModernSpeedKeys: Bool { rpcVersion >= 5 }
    var hasPieces: Bool { rpcVersion >= 5 }
    var hasPortTest: Bool { rpcVersion >= 5 }
    var hasBlocklistUpdate: Bool { rpcVersion >= 5 }
    var hasAlternateSpeedSchedule: Bool { rpcVersion >= 5 }
    var hasTrackerStats: Bool { rpcVersion >= 7 }
    var hasIncompleteDirectory: Bool { rpcVersion >= 7 }
    var hasRenamePartialFiles: Bool { rpcVersion >= 8 }
    var hasLPD: Bool { rpcVersion >= 9 }
    var hasSeedIdle: Bool { rpcVersion >= 10 }
    var hasCacheSize: Bool { rpcVersion >= 10 }
    var hasBlocklistURL: Bool { rpcVersion >= 11 }
    var hasUTP: Bool { rpcVersion >= 13 }
    var hasModernStatusCodes: Bool { rpcVersion >= 14 }
    var hasQueueControls: Bool { rpcVersion >= 14 }
    var hasFreeSpace: Bool { rpcVersion >= 15 }
    var hasTorrentRenamePath: Bool { rpcVersion >= 15 }
    var hasLabels: Bool { rpcVersion >= 16 }
    var hasTorrentTableFormat: Bool { rpcVersion >= 16 }
    var hasTrackerListEditing: Bool { rpcVersion >= 17 }
    var hasProtocolSpecificPortTest: Bool { rpcVersion >= 18 }
}
