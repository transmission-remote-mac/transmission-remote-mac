// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation

enum TorrentDuplicateTrackerTarget: Equatable, Sendable {
    case hash(String)
    case id(Int)
}

struct TorrentDuplicateTrackerSnapshot: Equatable, Sendable {
    let target: TorrentDuplicateTrackerTarget
    let id: Int
    let hashString: String?
    let announceURLs: [String]
}

struct TorrentDuplicateTrackerPlan: Identifiable, Equatable, Sendable {
    let id = UUID()
    let target: TorrentDuplicateTrackerTarget
    let torrentName: String?
    let missingTrackerURLs: [String]

    var confirmationMessage: String {
        let trackerList = missingTrackerURLs.map { "• \($0)" }.joined(separator: "\n")
        return "This torrent already exists. Add these missing trackers?\n\n\(trackerList)"
    }
}

protocol TorrentDuplicateTrackerRPC: Sendable {
    func fetchDuplicateTorrentTrackers(
        hashString: String?,
        id: Int?
    ) async throws -> TorrentDuplicateTrackerSnapshot?

    func addDuplicateTorrentTrackers(
        _ announceURLs: [String],
        target: TorrentDuplicateTrackerTarget
    ) async throws
}

enum TorrentDuplicateTrackerMergeError: LocalizedError, Equatable {
    case missingIdentity
    case torrentNotFound
    case comparisonFailed(String)
    case updateFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingIdentity:
            "Transmission reported a duplicate torrent without an id or hash. Its trackers were not changed."
        case .torrentNotFound:
            "Transmission reported a duplicate torrent, but it could not be found to compare trackers. No trackers were changed."
        case .comparisonFailed(let message):
            "Could not compare trackers for the duplicate torrent: \(message) The existing torrent was left in place."
        case .updateFailed(let message):
            "Could not add every missing tracker to the duplicate torrent: \(message) The existing torrent was not removed or re-added."
        }
    }
}

struct TorrentDuplicateTrackerMerge {
    func planIfNeeded(
        addResult: TorrentAddResult,
        localTrackerURLs: [String],
        rpcVersion: Int,
        rpc: any TorrentDuplicateTrackerRPC
    ) async throws -> TorrentDuplicateTrackerPlan? {
        guard addResult.isDuplicate else { return nil }

        let normalizedLocalTrackers = Self.normalizedTrackerURLs(localTrackerURLs)
        guard !normalizedLocalTrackers.isEmpty else { return nil }
        guard rpcVersion >= 10 else {
            throw TransmissionRPCError.unsupportedRPCVersion(
                feature: "Updating trackers for a duplicate torrent",
                required: 10,
                actual: rpcVersion
            )
        }

        let hashString = Self.normalizedHash(addResult.hashString)
        let id = Self.normalizedTorrentID(addResult.id)
        guard hashString != nil || id != nil else {
            throw TorrentDuplicateTrackerMergeError.missingIdentity
        }

        let existingTorrent: TorrentDuplicateTrackerSnapshot?
        do {
            existingTorrent = try await rpc.fetchDuplicateTorrentTrackers(
                hashString: hashString,
                id: id
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw TorrentDuplicateTrackerMergeError.comparisonFailed(error.localizedDescription)
        }
        guard let existingTorrent else {
            throw TorrentDuplicateTrackerMergeError.torrentNotFound
        }

        let existingTrackers = Set(Self.normalizedTrackerURLs(existingTorrent.announceURLs))
        let missingTrackers = normalizedLocalTrackers.filter { !existingTrackers.contains($0) }
        guard !missingTrackers.isEmpty else { return nil }

        return TorrentDuplicateTrackerPlan(
            target: existingTorrent.target,
            torrentName: Self.normalizedName(addResult.name),
            missingTrackerURLs: missingTrackers
        )
    }

    func apply(
        _ plan: TorrentDuplicateTrackerPlan,
        rpc: any TorrentDuplicateTrackerRPC
    ) async throws {
        guard !plan.missingTrackerURLs.isEmpty else { return }
        do {
            try await rpc.addDuplicateTorrentTrackers(
                plan.missingTrackerURLs,
                target: plan.target
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw TorrentDuplicateTrackerMergeError.updateFailed(error.localizedDescription)
        }
    }

    static func normalizedTrackerURLs(_ trackerURLs: [String]) -> [String] {
        var seen = Set<String>()
        return trackerURLs.compactMap { trackerURL in
            let normalized = trackerURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { return nil }
            return normalized
        }
    }

    static func normalizedHash(_ hashString: String?) -> String? {
        guard let hashString else { return nil }
        let normalized = hashString.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    static func normalizedName(_ name: String?) -> String? {
        guard let name else { return nil }
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    static func normalizedTorrentID(_ id: Int?) -> Int? {
        guard let id, id > 0 else { return nil }
        return id
    }

    static func decodedTorrentID(_ value: JSONValue?) throws -> Int? {
        guard let value else { return nil }
        let id: Int
        switch value {
        case .int(let intValue):
            id = intValue
        case .double(let doubleValue):
            guard let intValue = Int(exactly: doubleValue) else {
                throw TransmissionRPCError.invalidArguments
            }
            id = intValue
        case .null:
            return nil
        default:
            throw TransmissionRPCError.invalidArguments
        }
        return normalizedTorrentID(id)
    }
}
