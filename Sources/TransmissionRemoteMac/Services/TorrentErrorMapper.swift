// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation

struct TorrentMappedError: Equatable {
    var displayError: String
    var trackerError: String
    var globalError: String
    var trackerStatus: String
}

enum TorrentErrorMapper {
    static func merging(
        _ torrent: TorrentGetTorrent,
        into existing: TorrentMappedError,
        status: TorrentStatus,
        rpcVersion: Int
    ) -> TorrentMappedError {
        var result = existing
        if let errorString = torrent.errorString {
            result.globalError = errorString
        }

        if rpcVersion >= 7, let trackerStats = torrent.trackerStats {
            let mapped = mapTrackerStats(trackerStats, globalError: result.globalError)
            let legacyTrackerError = torrent.announceResponse.map(mapLegacyAnnounceResponse) ?? ""
            result.trackerError = mapped.trackerError.isEmpty ? legacyTrackerError : mapped.trackerError
            result.trackerStatus = mapped.trackerStatus.isEmpty
                ? torrent.announceResponse.map { legacyTrackerStatus($0, status: status) } ?? ""
                : mapped.trackerStatus
            result.globalError = mapped.globalError
        } else if let announceResponse = torrent.announceResponse {
            result.trackerError = mapLegacyAnnounceResponse(announceResponse)
            result.trackerStatus = legacyTrackerStatus(announceResponse, status: status)
        }

        if status == .stopped || status == .finished {
            result.trackerStatus = ""
        }
        result.displayError = if result.trackerError.isEmpty || status == .stopped || status == .finished {
            result.globalError
        } else {
            result.trackerError
        }
        return result
    }

    private static func mapTrackerStats(_ stats: [JSONValue], globalError: String) -> TorrentMappedError {
        var trackerError = ""
        var globalError = globalError
        var hasWorkingTracker = false
        var trackerStatus = ""

        for (index, value) in stats.enumerated() {
            guard let tracker = value.objectValue else { continue }
            var error = ""
            if bool(tracker, "hasAnnounced"), !bool(tracker, "lastAnnounceSucceeded") {
                error = tracker["lastAnnounceResult"]?.stringValue ?? ""
            }
            if error == "Success" {
                error = ""
            }

            if index == 0 {
                trackerStatus = statusText(for: tracker)
            }

            if error.isEmpty {
                hasWorkingTracker = true
                trackerError = ""
            } else {
                if !hasWorkingTracker, trackerError.isEmpty {
                    trackerError = "Tracker error: \(error)"
                }
                if globalError == error {
                    globalError = ""
                }
            }
        }

        return TorrentMappedError(
            displayError: trackerError.isEmpty ? globalError : trackerError,
            trackerError: trackerError,
            globalError: globalError,
            trackerStatus: trackerStatus
        )
    }

    private static func mapLegacyAnnounceResponse(_ response: String) -> String {
        guard !response.isEmpty, response != "Success" else { return "" }
        guard let parenthesis = response.firstIndex(of: "(") else { return response }
        let code = response[parenthesis...].prefix(5)
        if code == "(200)" {
            return ""
        }
        return "Tracker error: \(response[..<parenthesis].trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    private static func legacyTrackerStatus(_ response: String, status: TorrentStatus) -> String {
        status == .stopped || status == .finished ? "" : response
    }

    private static func statusText(for tracker: RPCArguments) -> String {
        if let announceState = tracker["announceState"]?.intValue, announceState == 2 || announceState == 3 {
            return "Updating"
        }
        guard bool(tracker, "hasAnnounced") else { return "" }
        if bool(tracker, "lastAnnounceSucceeded") {
            return "Working"
        }
        let result = tracker["lastAnnounceResult"]?.stringValue ?? ""
        return result == "Success" ? "Working" : result
    }

    private static func bool(_ object: RPCArguments, _ key: String) -> Bool {
        object[key]?.boolValue ?? false
    }
}
