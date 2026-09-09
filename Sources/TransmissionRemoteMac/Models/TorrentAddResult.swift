// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation

struct TorrentAddResult: Equatable, Sendable {
    enum Outcome: Equatable, Sendable {
        case added
        case duplicate
    }

    let outcome: Outcome
    let id: Int?
    let hashString: String?
    let name: String?

    var isDuplicate: Bool {
        outcome == .duplicate
    }

    init(arguments: RPCArguments) throws {
        let resultKey: String
        switch (arguments["torrent-added"], arguments["torrent-duplicate"]) {
        case (.some, .none):
            outcome = .added
            resultKey = "torrent-added"
        case (.none, .some):
            outcome = .duplicate
            resultKey = "torrent-duplicate"
        default:
            throw TransmissionRPCError.invalidArguments
        }

        guard let result = arguments[resultKey]?.objectValue else {
            throw TransmissionRPCError.invalidArguments
        }

        id = try Self.optionalInt(result["id"])
        hashString = try Self.optionalString(result["hashString"])
        name = try Self.optionalString(result["name"])
    }

    private static func optionalInt(_ value: JSONValue?) throws -> Int? {
        guard let value else { return nil }
        switch value {
        case .int(let intValue):
            return intValue
        case .double(let doubleValue):
            guard let intValue = Int(exactly: doubleValue) else {
                throw TransmissionRPCError.invalidArguments
            }
            return intValue
        case .null:
            return nil
        default:
            throw TransmissionRPCError.invalidArguments
        }
    }

    private static func optionalString(_ value: JSONValue?) throws -> String? {
        guard let value else { return nil }
        guard let stringValue = value.stringValue else {
            throw TransmissionRPCError.invalidArguments
        }
        return stringValue
    }
}
