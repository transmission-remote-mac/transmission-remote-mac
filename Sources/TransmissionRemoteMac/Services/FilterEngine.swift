// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation

enum TorrentFilterStatus: String, CaseIterable, Hashable, Identifiable {
    case all
    case downloading
    case done
    case active
    case inactive
    case stopped
    case error
    case waiting

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All Torrents"
        case .downloading: "Downloading"
        case .done: "Done"
        case .active: "Active"
        case .inactive: "Inactive"
        case .stopped: "Stopped"
        case .error: "Errors"
        case .waiting: "Waiting"
        }
    }

    var systemImage: String {
        switch self {
        case .all: "tray.full"
        case .downloading: "arrow.down.circle"
        case .done: "checkmark.circle"
        case .active: "bolt.circle"
        case .inactive: "clock"
        case .stopped: "pause.circle"
        case .error: "exclamationmark.triangle"
        case .waiting: "hourglass"
        }
    }
}

struct TorrentFilters: Equatable {
    var statuses: Set<TorrentFilterStatus> = []
    var paths: Set<String> = []
    var trackers: Set<String> = []
    var labels: Set<String> = []
    var searchText = ""

    static let empty = TorrentFilters()
}

struct TorrentFilterCount: Equatable, Identifiable {
    var value: String
    var count: Int

    var id: String { value }
}

struct TorrentFilterCounts: Equatable {
    var statuses: [TorrentFilterStatus: Int]
    var paths: [TorrentFilterCount]
    var trackers: [TorrentFilterCount]
    var labels: [TorrentFilterCount]
}

struct TorrentFilterEngine {
    func filter(_ torrents: [TorrentSummary], using filters: TorrentFilters) -> [TorrentSummary] {
        torrents.filter { matches($0, filters: filters) }
    }

    func matches(_ torrent: TorrentSummary, filters: TorrentFilters) -> Bool {
        matchesStatus(torrent, statuses: filters.statuses)
            && matchesExact(torrent.downloadDir, selectedValues: filters.paths)
            && matchesExact(torrent.trackerHost, selectedValues: filters.trackers)
            && matchesLabels(torrent.labels, selectedValues: filters.labels)
            && matchesSearch(torrent, searchText: filters.searchText)
    }

    func counts(for torrents: [TorrentSummary]) -> TorrentFilterCounts {
        var statusCounts = Dictionary(uniqueKeysWithValues: TorrentFilterStatus.allCases.map { ($0, 0) })
        var pathCounts: [String: Int] = [:]
        var trackerCounts: [String: Int] = [:]
        var labelCounts: [String: Int] = [:]

        for torrent in torrents {
            for status in TorrentFilterStatus.allCases where matches(torrent, status: status) {
                statusCounts[status, default: 0] += 1
            }
            if !torrent.downloadDir.isEmpty {
                pathCounts[torrent.downloadDir, default: 0] += 1
            }
            if !torrent.trackerHost.isEmpty {
                trackerCounts[torrent.trackerHost, default: 0] += 1
            }
            for label in torrent.labels where !label.isEmpty {
                labelCounts[label, default: 0] += 1
            }
        }

        return TorrentFilterCounts(
            statuses: statusCounts,
            paths: sortedCounts(pathCounts),
            trackers: sortedCounts(trackerCounts),
            labels: sortedCounts(labelCounts)
        )
    }

    func matches(_ torrent: TorrentSummary, status: TorrentFilterStatus) -> Bool {
        switch status {
        case .all:
            true
        case .downloading:
            torrent.status == .downloading
        case .done:
            isDone(torrent)
        case .active:
            isActive(torrent)
        case .inactive:
            !isActive(torrent) && !isStopped(torrent)
        case .stopped:
            isStopped(torrent)
        case .error:
            !torrent.errorString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .waiting:
            torrent.status == .checkWait || torrent.status == .checking || torrent.status == .downloadWait
        }
    }

    private func matchesStatus(_ torrent: TorrentSummary, statuses: Set<TorrentFilterStatus>) -> Bool {
        guard !statuses.isEmpty, !statuses.contains(.all) else { return true }
        return statuses.contains { matches(torrent, status: $0) }
    }

    private func matchesExact(_ value: String, selectedValues: Set<String>) -> Bool {
        selectedValues.isEmpty || selectedValues.contains(value)
    }

    private func matchesLabels(_ labels: [String], selectedValues: Set<String>) -> Bool {
        guard !selectedValues.isEmpty else { return true }
        let displayString = labels.joined(separator: ", ")
        return selectedValues.contains { displayString.contains($0) }
    }

    private func matchesSearch(_ torrent: TorrentSummary, searchText: String) -> Bool {
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        return searchFields(for: torrent).contains { $0.localizedCaseInsensitiveContains(needle) }
    }

    private func searchFields(for torrent: TorrentSummary) -> [String] {
        [
            torrent.name,
            torrent.status.title,
            torrent.errorString,
            torrent.downloadDir,
            torrent.trackerHost,
            torrent.labels.joined(separator: ", ")
        ]
    }

    private func isActive(_ torrent: TorrentSummary) -> Bool {
        torrent.rateDownload != 0 || torrent.rateUpload != 0
    }

    private func isDone(_ torrent: TorrentSummary) -> Bool {
        torrent.status == .seeding || (torrent.percentDone >= 1 && torrent.sizeWhenDone > 0 && torrent.leftUntilDone == 0)
    }

    private func isStopped(_ torrent: TorrentSummary) -> Bool {
        torrent.status == .stopped
    }

    private func sortedCounts(_ values: [String: Int]) -> [TorrentFilterCount] {
        values
            .map { TorrentFilterCount(value: $0.key, count: $0.value) }
            .sorted { lhs, rhs in
                lhs.value.localizedCaseInsensitiveCompare(rhs.value) == .orderedAscending
            }
    }
}
