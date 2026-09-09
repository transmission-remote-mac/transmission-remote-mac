// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation

/// Owns bounded PKCS#12 file IO and security scope, not identity import or storage.
struct ClientIdentityFileLoader: Sendable {
    struct Request: Equatable, Sendable {
        let id = UUID()
        let profileID: ConnectionProfile.ID
    }

    struct LoadState: Equatable, Sendable {
        private(set) var request: Request?
        var isLoading: Bool { request != nil }

        mutating func begin(profileID: ConnectionProfile.ID) -> Request {
            let next = Request(profileID: profileID)
            request = next
            return next
        }

        mutating func cancel(_ owner: Request? = nil) {
            guard owner == nil || request == owner else { return }
            request = nil
        }

        mutating func complete(_ owner: Request, profileID: ConnectionProfile.ID) -> Bool {
            guard request == owner, owner.profileID == profileID else { return false }
            request = nil
            return true
        }
    }

    var startAccess: @Sendable (URL) -> Bool = { $0.startAccessingSecurityScopedResource() }
    var stopAccess: @Sendable (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }
    var read: @Sendable (URL) throws -> Data = {
        try DarwinRaceResistantFileCleanup().readRegularFile(
            at: $0,
            maximumBytes: PendingClientIdentityImport.maximumByteCount,
            checkCancellation: { try Task.checkCancellation() }
        ).data
    }

    func load(at url: URL) async throws -> Data {
        try Task.checkCancellation()
        guard ["p12", "pfx"].contains(url.pathExtension.lowercased()) else {
            throw ClientIdentityFileSelectionError.unsupportedFileType
        }
        let worker = Task.detached(priority: .userInitiated) { [self] in
            try Task.checkCancellation()
            let didAccess = startAccess(url)
            defer { if didAccess { stopAccess(url) } }
            do {
                try Task.checkCancellation()
                let data = try read(url.standardizedFileURL)
                try Task.checkCancellation()
                guard !data.isEmpty, data.count <= PendingClientIdentityImport.maximumByteCount else {
                    throw ClientIdentityFileSelectionError.invalidFileSize
                }
                return data
            } catch let error as RaceResistantFileCleanupError {
                try Task.checkCancellation()
                if case .sourceExceedsMaximumSize = error {
                    throw ClientIdentityFileSelectionError.invalidFileSize
                }
                throw error
            } catch {
                try Task.checkCancellation()
                throw error
            }
        }
        return try await withTaskCancellationHandler {
            let data = try await worker.value
            try Task.checkCancellation()
            return data
        } onCancel: {
            worker.cancel()
        }
    }
}

enum ClientIdentityFileSelectionError: LocalizedError, Equatable {
    case unsupportedFileType
    case invalidFileSize

    var errorDescription: String? {
        switch self {
        case .unsupportedFileType:
            "Choose a PKCS#12 file ending in .p12 or .pfx."
        case .invalidFileSize:
            "The PKCS#12 file must be between 1 byte and 16 MB."
        }
    }
}
