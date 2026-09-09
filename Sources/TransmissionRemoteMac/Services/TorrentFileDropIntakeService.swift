// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import AppKit
import Foundation
import UniformTypeIdentifiers

/// Resolves Finder file-URL providers without making the SwiftUI drop target
/// responsible for provider decoding or source validation.
enum TorrentFileDropIntakeService {
    static let maximumFileURLRepresentationBytes = 64 * 1_024

    @discardableResult
    static func receive(
        providers: [NSItemProvider],
        onTorrentFiles: @escaping @MainActor ([URL]) -> Void
    ) -> Bool {
        let fileURLType = UTType.fileURL.identifier
        let eligibleProviders = providers.enumerated().filter { _, provider in
            provider.hasItemConformingToTypeIdentifier(fileURLType)
        }
        guard !eligibleProviders.isEmpty else { return false }

        let collector = TorrentFileDropResultCollector(
            expectedIndexes: eligibleProviders.map { $0.offset },
            completion: onTorrentFiles
        )
        for (index, provider) in eligibleProviders {
            provider.loadDataRepresentation(forTypeIdentifier: fileURLType) { data, error in
                let url: URL?
                if error == nil, let data {
                    url = normalizedTorrentFileURL(from: data)
                } else {
                    url = nil
                }
                collector.record(url, at: index)
            }
        }
        return true
    }

    static func normalizedTorrentFileURL(from representation: Data) -> URL? {
        guard !representation.isEmpty,
              representation.count <= maximumFileURLRepresentationBytes,
              let url = URL(dataRepresentation: representation, relativeTo: nil) else {
            return nil
        }
        return normalizedTorrentFileURL(url)
    }

    static func normalizedTorrentFileURL(_ url: URL) -> URL? {
        guard url.isFileURL,
              url.pathExtension.caseInsensitiveCompare("torrent") == .orderedSame else {
            return nil
        }
        return url.standardizedFileURL
    }
}

/// Provider callbacks can finish in any order. This collector waits for every
/// eligible provider, then restores the original drop order while omitting only
/// entries that failed validation.
final class TorrentFileDropResultCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var outstandingIndexes: Set<Int>
    private var indexedURLs: [(index: Int, url: URL)] = []
    private var didComplete = false
    private let completion: @MainActor ([URL]) -> Void

    init(
        expectedIndexes: [Int],
        completion: @escaping @MainActor ([URL]) -> Void
    ) {
        precondition(!expectedIndexes.isEmpty)
        outstandingIndexes = Set(expectedIndexes)
        precondition(outstandingIndexes.count == expectedIndexes.count)
        self.completion = completion
    }

    func record(_ url: URL?, at index: Int) {
        lock.lock()
        guard !didComplete, outstandingIndexes.remove(index) != nil else {
            lock.unlock()
            return
        }
        if let url {
            indexedURLs.append((index, url))
        }
        guard outstandingIndexes.isEmpty else {
            lock.unlock()
            return
        }

        didComplete = true
        let orderedURLs = indexedURLs
            .sorted { $0.index < $1.index }
            .map(\.url)
        lock.unlock()

        Task { @MainActor [completion] in
            completion(orderedURLs)
        }
    }
}
