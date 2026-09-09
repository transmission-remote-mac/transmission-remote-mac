// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation

enum TorrentStatus: Int, Codable, CaseIterable, Sendable {
    case stopped = 0
    case checkWait = 1
    case checking = 2
    case downloadWait = 3
    case downloading = 4
    case seedWait = 5
    case seeding = 6
    case finished = 256
    case unknown = -1

    static func mapped(rawStatus: Int?, rpcVersion: Int) -> TorrentStatus {
        guard let rawStatus else { return .unknown }
        if rpcVersion >= 14 {
            return TorrentStatus(rawValue: rawStatus) ?? .unknown
        }

        if rawStatus & 16 != 0 { return .stopped }
        if rawStatus & 8 != 0 { return .seeding }
        if rawStatus & 4 != 0 { return .downloading }
        if rawStatus & 2 != 0 { return .checking }
        if rawStatus & 1 != 0 { return .checkWait }
        return .unknown
    }

    var title: String {
        switch self {
        case .stopped: "Stopped"
        case .checkWait: "Waiting to verify"
        case .checking: "Verifying"
        case .downloadWait: "Waiting"
        case .downloading: "Downloading"
        case .seedWait: "Waiting to seed"
        case .seeding: "Seeding"
        case .finished: "Finished"
        case .unknown: "Unknown"
        }
    }

    var isActive: Bool {
        self == .downloading || self == .seeding || self == .checking
    }

    var isWaiting: Bool {
        self == .checkWait || self == .downloadWait || self == .seedWait
    }
}
