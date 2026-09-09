// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation
import Security

enum KeychainItemStatusPolicy {
    static func isAbsent(_ status: OSStatus) -> Bool {
        status == errSecItemNotFound
    }

    static func deletionSucceeded(_ status: OSStatus) -> Bool {
        status == errSecSuccess || isAbsent(status)
    }
}

enum KeychainSecretValueDecoder {
    static func decode(_ item: CFTypeRef?) throws -> String {
        guard
            let data = item as? Data,
            let value = String(data: data, encoding: .utf8)
        else {
            throw KeychainSecretValueError.corruptItem
        }
        return value
    }
}

enum KeychainSecretValueError: LocalizedError, Equatable {
    case corruptItem

    var errorDescription: String? {
        "The Keychain item does not contain a valid UTF-8 password."
    }
}

protocol ConnectionPasswordStoring {
    func password(for profileID: ConnectionProfile.ID) throws -> String?
    func setPassword(_ password: String, for profileID: ConnectionProfile.ID) throws
    func removePassword(for profileID: ConnectionProfile.ID) throws
}

final class KeychainPasswordStore: ConnectionPasswordStoring {
    private let accessor: GenericPasswordKeychainAccessor

    init(security: any GenericPasswordSecurityAPI = SystemGenericPasswordSecurityAPI()) {
        accessor = GenericPasswordKeychainAccessor(
            service: "net.pokwer.TransmissionRemoteMac.TransmissionRPC.v5",
            itemLabel: "TransmissionRemoteMac RPC Password",
            security: security,
            statusError: KeychainPasswordStoreError.unhandledStatus
        )
    }

    func password(for profileID: ConnectionProfile.ID) throws -> String? {
        try accessor.password(account: account(for: profileID))
    }

    func setPassword(_ password: String, for profileID: ConnectionProfile.ID) throws {
        try accessor.setPassword(password, account: account(for: profileID))
    }

    func removePassword(for profileID: ConnectionProfile.ID) throws {
        try accessor.removePassword(account: account(for: profileID))
    }

    private func account(for profileID: ConnectionProfile.ID) -> String {
        "stable-v1:\(profileID.uuidString)"
    }
}

enum KeychainPasswordStoreError: LocalizedError, Equatable {
    case unhandledStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .unhandledStatus(let status): "Keychain password storage failed with status \(status)"
        }
    }
}
