// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation

struct TorrentPathRenameOwner: Hashable, Sendable {
    let connectionToken: UUID
    let profileID: UUID
    let selectionRevision: Int
    let paneRevision: Int
    let filesRevision: UUID
}

enum TorrentPathRenameNodeKind: Hashable, Sendable {
    case file(index: Int)
    case folder
}

struct TorrentPathRenameNode: Hashable, Sendable {
    let id: String
    let kind: TorrentPathRenameNodeKind
    let relativePath: String
    let basename: String
}

struct TorrentPathRenameRequest: Hashable, Sendable {
    let torrentHash: String
    let torrentID: Int
    let owner: TorrentPathRenameOwner
    let node: TorrentPathRenameNode
    let newBasename: String

    fileprivate init(
        torrentHash: String,
        torrentID: Int,
        owner: TorrentPathRenameOwner,
        node: TorrentPathRenameNode,
        newBasename: String
    ) {
        self.torrentHash = torrentHash
        self.torrentID = torrentID
        self.owner = owner
        self.node = node
        self.newBasename = newBasename
    }
}

enum TorrentPathRenameValidationError: Error, Equatable, LocalizedError, Sendable {
    case invalidTorrentHash
    case invalidTorrentID
    case invalidNodeIdentity
    case invalidFileIndex
    case invalidOldPath
    case nodeBasenameMismatch(expected: String, actual: String)
    case emptyName
    case reservedName(String)
    case unchangedName
    case containsPathSeparator
    case containsNull
    case containsControlCharacter
    case staleNode

    var errorDescription: String? {
        switch self {
        case .invalidTorrentHash:
            "The torrent hash is missing or invalid. Refresh the torrent and try again."
        case .invalidTorrentID:
            "The selected torrent is no longer valid. Refresh the torrent list and try again."
        case .invalidNodeIdentity:
            "The selected file or folder is no longer valid. Refresh Files and try again."
        case .invalidFileIndex:
            "The selected file index is invalid. Refresh Files and try again."
        case .invalidOldPath:
            "The selected file or folder path is invalid. Refresh Files and try again."
        case .nodeBasenameMismatch:
            "The selected file or folder changed. Refresh Files and try again."
        case .emptyName:
            "Enter a new name."
        case .reservedName(let name):
            "\(name) is not a valid file or folder name."
        case .unchangedName:
            "Enter a name different from the current name."
        case .containsPathSeparator:
            "The new name cannot contain a path separator."
        case .containsNull:
            "The new name cannot contain a null character."
        case .containsControlCharacter:
            "The new name cannot contain control characters."
        case .staleNode:
            "The selected file or folder changed. Refresh Files and try again."
        }
    }
}

enum TorrentPathRenameValidator {
    static func request(
        torrentHash: String,
        torrentID: Int,
        owner: TorrentPathRenameOwner,
        node: TorrentFileNode,
        newBasename: String
    ) throws -> TorrentPathRenameRequest {
        try request(
            torrentHash: torrentHash,
            torrentID: torrentID,
            owner: owner,
            nodeID: node.id,
            nodeKind: node.pathRenameKind,
            oldRelativePath: node.relativePath,
            originalBasename: node.name,
            newBasename: newBasename
        )
    }

    static func request(
        torrentHash: String,
        torrentID: Int,
        owner: TorrentPathRenameOwner,
        nodeID: String,
        nodeKind: TorrentPathRenameNodeKind,
        oldRelativePath: String,
        originalBasename: String,
        newBasename: String
    ) throws -> TorrentPathRenameRequest {
        let normalizedHash = try normalizeTorrentHash(torrentHash)
        guard torrentID > 0 else {
            throw TorrentPathRenameValidationError.invalidTorrentID
        }
        let node = try validateNode(
            id: nodeID,
            kind: nodeKind,
            relativePath: oldRelativePath,
            basename: originalBasename
        )
        let normalizedName = try normalizeNewBasename(
            newBasename,
            originalBasename: originalBasename
        )

        return TorrentPathRenameRequest(
            torrentHash: normalizedHash,
            torrentID: torrentID,
            owner: owner,
            node: node,
            newBasename: normalizedName
        )
    }

    static func validateCurrentNode(
        _ currentNode: TorrentPathRenameNode,
        for request: TorrentPathRenameRequest
    ) throws {
        guard currentNode == request.node else {
            throw TorrentPathRenameValidationError.staleNode
        }
    }

    static func normalizeTorrentHash(_ torrentHash: String) throws -> String {
        guard let normalized = CanonicalTransmissionTorrentHash.normalize(torrentHash) else {
            throw TorrentPathRenameValidationError.invalidTorrentHash
        }
        return normalized
    }

    static func normalizeNewBasename(
        _ newBasename: String,
        originalBasename: String
    ) throws -> String {
        let normalized = newBasename.trimmingCharacters(in: .whitespaces)
        guard !normalized.isEmpty else {
            throw TorrentPathRenameValidationError.emptyName
        }
        guard normalized != ".", normalized != ".." else {
            throw TorrentPathRenameValidationError.reservedName(normalized)
        }
        guard normalized != originalBasename else {
            throw TorrentPathRenameValidationError.unchangedName
        }
        guard !normalized.contains("/"), !normalized.contains("\\") else {
            throw TorrentPathRenameValidationError.containsPathSeparator
        }
        guard !normalized.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw TorrentPathRenameValidationError.containsNull
        }
        guard !normalized.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw TorrentPathRenameValidationError.containsControlCharacter
        }
        return normalized
    }

    private static func validateNode(
        id: String,
        kind: TorrentPathRenameNodeKind,
        relativePath: String,
        basename: String
    ) throws -> TorrentPathRenameNode {
        guard !id.isEmpty, id == id.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw TorrentPathRenameValidationError.invalidNodeIdentity
        }
        if case .file(let index) = kind, index < 0 {
            throw TorrentPathRenameValidationError.invalidFileIndex
        }

        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.hasSuffix("/"),
              !relativePath.contains("\\"),
              !relativePath.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw TorrentPathRenameValidationError.invalidOldPath
        }

        let actualBasename = components.last ?? ""
        guard !basename.isEmpty, basename == actualBasename else {
            throw TorrentPathRenameValidationError.nodeBasenameMismatch(
                expected: basename,
                actual: actualBasename
            )
        }

        return TorrentPathRenameNode(
            id: id,
            kind: kind,
            relativePath: relativePath,
            basename: basename
        )
    }
}

extension TorrentPathRenameNode {
    init(fileNode: TorrentFileNode) {
        self.init(
            id: fileNode.id,
            kind: fileNode.pathRenameKind,
            relativePath: fileNode.relativePath,
            basename: fileNode.name
        )
    }
}

private extension TorrentFileNode {
    var pathRenameKind: TorrentPathRenameNodeKind {
        switch kind {
        case .folder:
            .folder
        case .file(let index):
            .file(index: index)
        }
    }

    var relativePath: String {
        path.isEmpty ? name : "\(path)/\(name)"
    }
}
