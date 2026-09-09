// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation

struct ClientIdentityMetadata: Codable, Hashable, Sendable {
    let displayName: String
    let sha256Fingerprint: String
    let subject: String
    let issuer: String
    let notBefore: Date
    let notAfter: Date

    init(
        displayName: String,
        sha256Fingerprint: String,
        subject: String,
        issuer: String,
        notBefore: Date,
        notAfter: Date
    ) {
        self.displayName = displayName
        self.sha256Fingerprint = sha256Fingerprint
        self.subject = subject
        self.issuer = issuer
        self.notBefore = notBefore
        self.notAfter = notAfter
    }
}

struct PendingClientIdentityImport: Hashable, Sendable {
    static let maximumByteCount = 16 * 1_024 * 1_024

    let operationID: UUID
    let sourceFileName: String
    let pkcs12Data: Data
    var passphrase: String

    init(
        operationID: UUID = UUID(),
        sourceFileName: String,
        pkcs12Data: Data,
        passphrase: String = ""
    ) {
        self.operationID = operationID
        self.sourceFileName = sourceFileName
        self.pkcs12Data = pkcs12Data
        self.passphrase = passphrase
    }

    var isValid: Bool {
        !sourceFileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !pkcs12Data.isEmpty
            && pkcs12Data.count <= Self.maximumByteCount
    }
}

/// Copies of a profile share its post-persistence acknowledgment. The lock protects
/// every state access; readers use one snapshot for decisions involving multiple fields.
final class ClientIdentityEditState: Hashable, @unchecked Sendable {
    struct Snapshot: Hashable, Sendable {
        let pendingImport: PendingClientIdentityImport?
        let removeOnApply: Bool
        let didApply: Bool
        let appliedMetadata: ClientIdentityMetadata?
    }

    private let lock = NSLock()
    private var state: Snapshot

    var snapshot: Snapshot { lock.withLock { state } }

    init(
        pendingImport: PendingClientIdentityImport? = nil,
        removeOnApply: Bool = false
    ) {
        state = Snapshot(
            pendingImport: pendingImport,
            removeOnApply: removeOnApply,
            didApply: false,
            appliedMetadata: nil
        )
    }

    func markApplied(metadata: ClientIdentityMetadata?) {
        lock.withLock {
            state = Snapshot(
                pendingImport: nil,
                removeOnApply: false,
                didApply: true,
                appliedMetadata: metadata
            )
        }
    }

    static func == (lhs: ClientIdentityEditState, rhs: ClientIdentityEditState) -> Bool {
        lhs === rhs || lhs.snapshot == rhs.snapshot
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(snapshot)
    }
}
