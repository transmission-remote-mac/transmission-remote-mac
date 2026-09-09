// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation

enum TorrentDetailFormatters {
    static func percent(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(1)))
    }

    static func size(_ bytes: Int64) -> String {
        bytes >= 0 ? ByteCountFormatters.fileSize(bytes) : "—"
    }

    static func optionalSize(_ bytes: Int64?) -> String {
        guard let bytes else { return "—" }
        return ByteCountFormatters.transferSize(bytes)
    }

    static func elapsed(_ seconds: Int?) -> String {
        guard let seconds else { return "—" }
        return DurationFormatters.elapsed(seconds)
    }

    static func ratio(_ value: Double) -> String {
        value.isInfinite ? "∞" : value.formatted(.number.precision(.fractionLength(2)))
    }

    static func optionalRatio(_ value: Double?) -> String {
        guard let value, value.isFinite || value.isInfinite else { return "—" }
        return ratio(value)
    }

    static func eta(_ seconds: Int?) -> String {
        seconds.map(DurationFormatters.eta) ?? "—"
    }

    static func averageSpeed(bytes: Int64?, seconds: Int?) -> String {
        guard let bytes, bytes > 0, let seconds, seconds > 0 else { return "—" }
        return ByteCountFormatters.speed(bytes / Int64(seconds))
    }

    static func speed(_ bytesPerSecond: Int64?) -> String {
        bytesPerSecond.map { ByteCountFormatters.speed($0) } ?? "—"
    }

    static func wasted(bytes: Int64?, pieceSize: Int64?) -> String {
        guard let bytes, bytes > 0 else { return "—" }
        let size = ByteCountFormatters.transferSize(bytes)
        guard let pieceSize, pieceSize > 0 else { return size }
        let quotient = bytes / pieceSize
        let remainder = bytes % pieceSize
        let roundingThreshold = pieceSize / 2 + pieceSize % 2
        let failures = quotient + (remainder >= roundingThreshold ? 1 : 0)
        let suffix = failures == 1 ? "hash failure" : "hash failures"
        return "\(size) (\(failures) \(suffix))"
    }

    static func speedLimit(_ limit: TorrentGeneralSpeedLimit?) -> String {
        switch limit {
        case .none, .some(.global):
            "—"
        case .some(.unlimited):
            "∞"
        case .some(.limited(let kilobytesPerSecond)):
            "\(kilobytesPerSecond) KB/s"
        }
    }

    static func priority(_ rawValue: Int?) -> String {
        switch rawValue {
        case 1: "High"
        case 0: "Normal"
        case -1: "Low"
        case .some(let value): "\(value)"
        case nil: "—"
        }
    }

    static func trackerUpdate(
        _ update: TorrentTrackerUpdate?,
        relativeTo referenceDate: Date = Date()
    ) -> String {
        switch update {
        case .some(.updating):
            "Updating"
        case .some(.scheduled(let date)):
            updateIn(date, relativeTo: referenceDate)
        case nil:
            "—"
        }
    }

    static func placeholder(_ value: String) -> String {
        value.isEmpty ? "—" : value
    }

    static func count(_ value: Int) -> String {
        value >= 0 ? "\(value)" : "—"
    }

    static func count(_ value: Int?) -> String {
        value.map { count($0) } ?? "—"
    }

    static func updateIn(_ date: Date?, relativeTo referenceDate: Date = Date()) -> String {
        guard let date,
              date.timeIntervalSinceReferenceDate.isFinite,
              date >= .distantPast,
              date <= .distantFuture,
              referenceDate.timeIntervalSinceReferenceDate.isFinite,
              referenceDate >= .distantPast,
              referenceDate <= .distantFuture,
              let seconds = Int(exactly: date.timeIntervalSince(referenceDate).rounded()) else {
            return "—"
        }
        return seconds >= 0 ? DurationFormatters.eta(seconds) : "Now"
    }
}
