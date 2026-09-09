// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import CryptoKit
import Foundation
#if canImport(AppKit)
import AppKit
#endif

enum ClipboardTorrentPayload: Equatable, Sendable {
    case plainText(String)
    case fileURLs([URL])
    case unavailable
}

enum ClipboardTorrentSourceKind: Equatable, Sendable {
    case magnetLink
    case remoteURL
    case rawInfoHash
}

struct ClipboardTorrentIntakeCandidate: Equatable, Sendable {
    let normalizedSource: String
    let sourceKind: ClipboardTorrentSourceKind
}

enum ClipboardTorrentIntakeIgnoreReason: Equatable, Sendable {
    case disabled
    case unavailable
    case filePayload
    case unsupportedText
    case duplicateCandidate
}

enum ClipboardTorrentIntakeDecision: Equatable, Sendable {
    case candidate(ClipboardTorrentIntakeCandidate)
    case ignore(ClipboardTorrentIntakeIgnoreReason)
}

/// Pure, in-memory clipboard candidate evaluator. It never reads, clears or
/// writes a pasteboard and retains only bounded SHA-256 digests for deduplication.
struct ClipboardTorrentIntakeService: Sendable {
    static let defaultDeduplicationCapacity = 128
    static let allowedDeduplicationCapacity = 1 ... 1_024
    static let maximumCandidateLength = 8_192
    static let persistsClipboardContents = false

    private let deduplicationCapacity: Int
    private var digestOrder: [String] = []
    private var seenDigests: Set<String> = []

    init(deduplicationCapacity: Int = Self.defaultDeduplicationCapacity) {
        self.deduplicationCapacity = min(
            max(deduplicationCapacity, Self.allowedDeduplicationCapacity.lowerBound),
            Self.allowedDeduplicationCapacity.upperBound
        )
    }

    var retainedDigestCount: Int {
        seenDigests.count
    }

    mutating func inspect(
        _ payload: ClipboardTorrentPayload,
        policy: ClipboardTorrentIntakePolicy
    ) -> ClipboardTorrentIntakeDecision {
        guard policy.isEnabled else {
            return .ignore(.disabled)
        }

        switch payload {
        case .unavailable:
            return .ignore(.unavailable)
        case .fileURLs:
            return .ignore(.filePayload)
        case let .plainText(text):
            guard let candidate = Self.candidate(from: text) else {
                return .ignore(.unsupportedText)
            }

            let digest = Self.digest(for: candidate.normalizedSource)
            guard seenDigests.insert(digest).inserted else {
                return .ignore(.duplicateCandidate)
            }
            digestOrder.append(digest)
            evictOldDigestsIfNeeded()
            return .candidate(candidate)
        }
    }

    mutating func resetDeduplication() {
        digestOrder.removeAll(keepingCapacity: true)
        seenDigests.removeAll(keepingCapacity: true)
    }

    private static func candidate(from text: String) -> ClipboardTorrentIntakeCandidate? {
        let source = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty,
              source.utf8.count <= maximumCandidateLength,
              !source.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else {
            return nil
        }

        let kind: ClipboardTorrentSourceKind
        if source.lowercased().hasPrefix("magnet:?") {
            kind = .magnetLink
        } else if isCredentialFreeRemoteURL(source) {
            kind = .remoteURL
        } else if isExplicitRawInfoHash(source) {
            kind = .rawInfoHash
        } else {
            return nil
        }

        guard let normalizedSource = try? TorrentSourceNormalizer.normalize(source) else {
            return nil
        }
        return ClipboardTorrentIntakeCandidate(
            normalizedSource: normalizedSource,
            sourceKind: kind
        )
    }

    private static func isCredentialFreeRemoteURL(_ source: String) -> Bool {
        guard let components = URLComponents(string: source),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host,
              !host.isEmpty,
              components.user == nil,
              components.password == nil else {
            return false
        }
        return true
    }

    private static func isExplicitRawInfoHash(_ source: String) -> Bool {
        switch source.count {
        case 32:
            return source.unicodeScalars.allSatisfy { scalar in
                switch scalar.value {
                case 65 ... 90, 97 ... 122, 50 ... 55:
                    return true
                default:
                    return false
                }
            }
        case 40, 64:
            return source.unicodeScalars.allSatisfy { scalar in
                switch scalar.value {
                case 48 ... 57, 65 ... 70, 97 ... 102:
                    return true
                default:
                    return false
                }
            }
        default:
            return false
        }
    }

    private static func digest(for source: String) -> String {
        SHA256.hash(data: Data(source.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private mutating func evictOldDigestsIfNeeded() {
        while digestOrder.count > deduplicationCapacity {
            seenDigests.remove(digestOrder.removeFirst())
        }
    }
}

@MainActor
protocol ClipboardTorrentPayloadReading: AnyObject {
    func readIfChanged() -> ClipboardTorrentPayload?
}

#if canImport(AppKit)
/// Event-driven pasteboard adapter. It observes change counts when the app is
/// activated or clipboard intake is enabled, and never mutates the pasteboard.
@MainActor
final class SystemClipboardTorrentPayloadReader: ClipboardTorrentPayloadReading {
    private let pasteboard: NSPasteboard
    private var lastInspectedChangeCount: Int?

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    func readIfChanged() -> ClipboardTorrentPayload? {
        let changeCount = pasteboard.changeCount
        guard changeCount != lastInspectedChangeCount else { return nil }
        lastInspectedChangeCount = changeCount

        let fileURLReadingOptions: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]
        if let fileURLs = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: fileURLReadingOptions
        ) as? [URL], !fileURLs.isEmpty {
            return .fileURLs(fileURLs)
        }
        if let text = pasteboard.string(forType: .string) {
            return .plainText(text)
        }
        return .unavailable
    }
}
#endif
