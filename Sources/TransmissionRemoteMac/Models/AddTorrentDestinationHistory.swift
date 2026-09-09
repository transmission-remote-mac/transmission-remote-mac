// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation

struct AddTorrentDestinationHistory: Equatable, Sendable {
    static let defaultLimit = 50

    private let limit: Int
    private(set) var destinations: [String]

    init(destinations: [String] = [], limit: Int = Self.defaultLimit) {
        self.limit = max(1, limit)
        self.destinations = Self.normalizedDestinations(destinations, limit: self.limit)
    }

    mutating func record(_ destination: String?) {
        guard let destination = Self.normalizedDestination(destination) else { return }
        destinations.removeAll { $0 == destination }
        destinations.insert(destination, at: 0)
        if destinations.count > limit {
            destinations.removeLast(destinations.count - limit)
        }
    }

    static func normalizedDestination(_ destination: String?) -> String? {
        guard let destination else { return nil }
        let trimmed = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalizedDestinations(_ destinations: [String], limit: Int) -> [String] {
        var normalized: [String] = []
        for destination in destinations {
            guard let destination = normalizedDestination(destination),
                  !normalized.contains(destination) else { continue }
            normalized.append(destination)
            if normalized.count == limit { break }
        }
        return normalized
    }
}

enum AddTorrentFreeSpaceProbeResult: Equatable, Sendable {
    case available(path: String, sizeBytes: Int64)
    case failed(path: String, message: String)

    var path: String {
        switch self {
        case .available(let path, _), .failed(let path, _):
            path
        }
    }
}
