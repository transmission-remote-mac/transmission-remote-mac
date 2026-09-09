// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation

enum ConfirmedTorrentAddOutcome: Equatable, Sendable {
    case added
    case duplicate
    case failed
}

enum TorrentSourceDeletionDecision: Equatable, Sendable {
    case keepSource
    case deleteLocalTorrentFile(URL)
}

enum TorrentSourceDeletionResult: Equatable, Sendable {
    case kept
    case deleted(URL)
    case failed(String)
}

struct PreparedTorrentSourceDeletion: Equatable, Sendable {
    let sourceFileURL: URL
    let sourceIdentity: RaceResistantFileIdentity
}

enum TorrentSourceDeletionPreparationError: LocalizedError, Equatable {
    case missingReadTimeIdentity

    var errorDescription: String? {
        switch self {
        case .missingReadTimeIdentity:
            "The source .torrent identity was not captured with the submitted bytes, so the source was left untouched."
        }
    }
}

struct TorrentSourceDeletionService: Sendable {
    private let fileCleanup: any RaceResistantFileCleaning

    init(fileCleanup: any RaceResistantFileCleaning = DarwinRaceResistantFileCleanup()) {
        self.fileCleanup = fileCleanup
    }

    func prepareDeletionIfNeeded(
        policy: SourceTorrentDeletionPolicy,
        sourceFileURL: URL,
        sourceIdentity: RaceResistantFileIdentity
    ) throws -> PreparedTorrentSourceDeletion? {
        guard case .deleteLocalTorrentFile(let normalizedURL) = Self.decision(
            policy: policy,
            sourceFileURL: sourceFileURL,
            addOutcome: .added
        ) else {
            return nil
        }
        return PreparedTorrentSourceDeletion(
            sourceFileURL: normalizedURL,
            sourceIdentity: sourceIdentity
        )
    }

    func deleteIfAllowed(
        preparedDeletion: PreparedTorrentSourceDeletion?,
        addOutcome: ConfirmedTorrentAddOutcome
    ) -> TorrentSourceDeletionResult {
        guard addOutcome == .added, let preparedDeletion else {
            return .kept
        }

        do {
            try fileCleanup.removeRegularFile(
                at: preparedDeletion.sourceFileURL,
                matching: preparedDeletion.sourceIdentity
            )
            return .deleted(preparedDeletion.sourceFileURL)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    func deleteIfAllowed(
        policy: SourceTorrentDeletionPolicy,
        sourceFileURL: URL,
        sourceIdentity: RaceResistantFileIdentity,
        addOutcome: ConfirmedTorrentAddOutcome
    ) -> TorrentSourceDeletionResult {
        let decision = Self.decision(
            policy: policy,
            sourceFileURL: sourceFileURL,
            addOutcome: addOutcome
        )
        guard case .deleteLocalTorrentFile(let fileURL) = decision else {
            return .kept
        }

        do {
            return deleteIfAllowed(
                preparedDeletion: try prepareDeletionIfNeeded(
                    policy: policy,
                    sourceFileURL: fileURL,
                    sourceIdentity: sourceIdentity
                ),
                addOutcome: addOutcome
            )
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    static func decision(
        policy: SourceTorrentDeletionPolicy,
        source: String,
        addOutcome: ConfirmedTorrentAddOutcome
    ) -> TorrentSourceDeletionDecision {
        guard policy == .afterSuccessfulNonDuplicateAdd,
              addOutcome == .added,
              let localTorrentFileURL = localTorrentFileURL(from: source) else {
            return .keepSource
        }
        return .deleteLocalTorrentFile(localTorrentFileURL)
    }

    static func decision(
        policy: SourceTorrentDeletionPolicy,
        sourceFileURL: URL,
        addOutcome: ConfirmedTorrentAddOutcome
    ) -> TorrentSourceDeletionDecision {
        guard sourceFileURL.isFileURL else { return .keepSource }
        return decision(
            policy: policy,
            source: sourceFileURL.standardizedFileURL.absoluteString,
            addOutcome: addOutcome
        )
    }

    private static func localTorrentFileURL(from source: String) -> URL? {
        let trimmedSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSource.isEmpty else { return nil }

        let fileURL: URL
        if let components = URLComponents(string: trimmedSource), components.scheme != nil {
            guard components.scheme?.lowercased() == "file",
                  components.user == nil,
                  components.password == nil,
                  components.host?.isEmpty != false || components.host?.lowercased() == "localhost",
                  let url = components.url,
                  url.isFileURL else {
                return nil
            }
            fileURL = url
        } else {
            guard trimmedSource.hasPrefix("/") else { return nil }
            fileURL = URL(fileURLWithPath: trimmedSource)
        }

        guard fileURL.pathExtension.caseInsensitiveCompare("torrent") == .orderedSame else {
            return nil
        }
        return fileURL.standardizedFileURL
    }
}
