// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation
import Security

protocol ConnectionProxyPasswordStoring {
    func password(for profileID: ConnectionProfile.ID) throws -> String?
    func setPassword(_ password: String, for profileID: ConnectionProfile.ID) throws
    func removePassword(for profileID: ConnectionProfile.ID) throws
}

final class KeychainProxyPasswordStore: ConnectionProxyPasswordStoring {
    static let service = "net.pokwer.TransmissionRemoteMac.ProxyPassword.v1"
    static let accountNamespace = "stable-v1"

    private let accessor: GenericPasswordKeychainAccessor

    init(security: any GenericPasswordSecurityAPI = SystemGenericPasswordSecurityAPI()) {
        accessor = GenericPasswordKeychainAccessor(
            service: Self.service,
            itemLabel: "TransmissionRemoteMac Proxy Password",
            security: security,
            statusError: KeychainProxyPasswordStoreError.unhandledStatus
        )
    }

    func password(for profileID: ConnectionProfile.ID) throws -> String? {
        try accessor.password(account: Self.account(for: profileID))
    }

    func setPassword(_ password: String, for profileID: ConnectionProfile.ID) throws {
        try accessor.setPassword(password, account: Self.account(for: profileID))
    }

    func removePassword(for profileID: ConnectionProfile.ID) throws {
        try accessor.removePassword(account: Self.account(for: profileID))
    }

    static func account(for profileID: ConnectionProfile.ID) -> String {
        "\(accountNamespace):\(profileID.uuidString)"
    }
}

enum KeychainProxyPasswordStoreError: LocalizedError, Equatable {
    case unhandledStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .unhandledStatus(let status): "Keychain proxy password storage failed with status \(status)"
        }
    }
}
