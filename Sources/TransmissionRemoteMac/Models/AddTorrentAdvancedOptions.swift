// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation

enum AddTorrentPeerLimitValidationError: LocalizedError, Equatable {
    case notInteger
    case outOfRange

    var errorDescription: String? {
        switch self {
        case .notInteger:
            "Peer limit must be a whole number."
        case .outOfRange:
            "Peer limit must be between 1 and 999."
        }
    }
}

enum AddTorrentPeerLimitParser {
    static let validRange = 1 ... 999

    static func parse(_ draft: String) throws -> Int? {
        let normalized = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.isEmpty == false else { return nil }

        guard let value = Int(normalized) else {
            if isIntegerLiteral(normalized) {
                throw AddTorrentPeerLimitValidationError.outOfRange
            }
            throw AddTorrentPeerLimitValidationError.notInteger
        }
        guard validRange.contains(value) else {
            throw AddTorrentPeerLimitValidationError.outOfRange
        }
        return value
    }

    private static func isIntegerLiteral(_ value: String) -> Bool {
        let digits: Substring
        if value.first == "+" || value.first == "-" {
            digits = value.dropFirst()
        } else {
            digits = value[...]
        }
        return digits.isEmpty == false && digits.allSatisfy { $0.isASCII && $0.isNumber }
    }
}

enum AddTorrentSaveAsValidationError: LocalizedError, Equatable {
    case empty
    case reservedName
    case containsPathSeparator
    case containsControlCharacter
    case unchanged

    var errorDescription: String? {
        switch self {
        case .empty:
            "Save As name cannot be empty."
        case .reservedName:
            "Save As name cannot be '.' or '..'."
        case .containsPathSeparator:
            "Save As name must be a single path component."
        case .containsControlCharacter:
            "Save As name cannot contain control characters."
        case .unchanged:
            "Save As name has not changed."
        }
    }
}

enum AddTorrentSaveAsValidator {
    static func validateIntent(_ draft: String) throws -> String {
        try validateShape(draft)
    }

    static func validate(_ draft: String, originalName: String) throws -> String {
        let normalized = try validateShape(draft)
        let normalizedOriginalName = originalName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized != normalizedOriginalName else {
            throw AddTorrentSaveAsValidationError.unchanged
        }
        return normalized
    }

    private static func validateShape(_ draft: String) throws -> String {
        let normalized = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.isEmpty == false else {
            throw AddTorrentSaveAsValidationError.empty
        }
        guard normalized != ".", normalized != ".." else {
            throw AddTorrentSaveAsValidationError.reservedName
        }
        guard normalized.contains("/") == false, normalized.contains("\\") == false else {
            throw AddTorrentSaveAsValidationError.containsPathSeparator
        }
        guard normalized.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0)
        }) == false else {
            throw AddTorrentSaveAsValidationError.containsControlCharacter
        }
        return normalized
    }
}

enum CanonicalTransmissionTorrentHash {
    static func normalize(_ hash: String?) -> String? {
        guard let hash else { return nil }
        let normalized = hash.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.utf8.count == 40 else { return nil }
        guard normalized.utf8.allSatisfy({ byte in
            (48 ... 57).contains(byte) || (97 ... 102).contains(byte)
        }) else {
            return nil
        }
        return normalized
    }
}

enum AddTorrentSaveAsCapability {
    static func isEditable(
        rpcVersion: Int,
        metadataComplete: Bool,
        rootName: String?
    ) -> Bool {
        guard rpcVersion >= 15, metadataComplete else { return false }
        return rootName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }
}

struct ProvisionalTorrentAddOwner: Equatable, Sendable {
    let requestID: UUID
    let presentationID: UUID
    let profileID: UUID
    let connectionToken: UUID
    let torrentID: Int
    let torrentHash: String
    let isDuplicate: Bool

    func mayMutate(currentOwner: ProvisionalTorrentAddOwner?) -> Bool {
        isDuplicate == false && currentOwner == self
    }
}

struct AddTorrentCapabilities: Equatable, Sendable {
    let rpcVersion: Int?

    var supportsSaveAs: Bool {
        guard let rpcVersion else { return false }
        return rpcVersion >= 15
    }
}

struct ProvisionalTorrentMetadataSnapshot: Equatable, Sendable {
    let torrentID: Int
    let torrentHash: String
    let metadataPercentComplete: Double
    let rootName: String?

    var hasAuthoritativeRootName: Bool {
        metadataPercentComplete >= 1
            && rootName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }
}

struct ProvisionalTorrentMetadataPollingPolicy: Equatable, Sendable {
    let interval: Duration
    let maximumAttempts: Int

    static let standard = ProvisionalTorrentMetadataPollingPolicy(
        interval: .seconds(2),
        maximumAttempts: 15
    )

    init(interval: Duration, maximumAttempts: Int) {
        self.interval = interval
        self.maximumAttempts = max(1, maximumAttempts)
    }
}

enum ProvisionalTorrentAddState: Equatable, Sendable {
    case idle
    case waiting(owner: ProvisionalTorrentAddOwner, attempt: Int, maximumAttempts: Int)
    case ready(owner: ProvisionalTorrentAddOwner, originalRootName: String)
    case timedOut(owner: ProvisionalTorrentAddOwner)
    case duplicate(name: String?)
    case unavailable(String)

    var owner: ProvisionalTorrentAddOwner? {
        switch self {
        case .waiting(let owner, _, _), .ready(let owner, _), .timedOut(let owner):
            owner
        case .idle, .duplicate, .unavailable:
            nil
        }
    }
}
