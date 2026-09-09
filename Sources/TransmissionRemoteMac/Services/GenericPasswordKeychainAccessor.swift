// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation
import Security

/// The Security boundary is injectable so CRUD policy can be tested without
/// opening the user's Keychain or changing an existing item's access control.
protocol GenericPasswordSecurityAPI {
    func copyMatching(_ query: [String: Any]) -> (status: OSStatus, item: CFTypeRef?)
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus
    func add(_ item: [String: Any]) -> OSStatus
    func delete(_ query: [String: Any]) -> OSStatus
}

struct SystemGenericPasswordSecurityAPI: GenericPasswordSecurityAPI {
    func copyMatching(_ query: [String: Any]) -> (status: OSStatus, item: CFTypeRef?) {
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return (status, item)
    }

    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }

    func add(_ item: [String: Any]) -> OSStatus {
        SecItemAdd(item as CFDictionary, nil)
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        SecItemDelete(query as CFDictionary)
    }
}

struct GenericPasswordKeychainAccessor {
    let service: String
    let itemLabel: String
    let security: any GenericPasswordSecurityAPI
    let statusError: (OSStatus) -> Error

    func password(account: String) throws -> String? {
        var query = identityQuery(account: account)
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let result = security.copyMatching(query)
        if KeychainItemStatusPolicy.isAbsent(result.status) { return nil }
        guard result.status == errSecSuccess else { throw statusError(result.status) }
        return try KeychainSecretValueDecoder.decode(result.item)
    }

    func setPassword(_ password: String, account: String) throws {
        let query = identityQuery(account: account)
        let data = Data(password.utf8)
        let status = security.update(query, attributes: [kSecValueData as String: data])
        if KeychainItemStatusPolicy.isAbsent(status) {
            var item = query
            item[kSecAttrLabel as String] = itemLabel
            item[kSecValueData as String] = data
            let addStatus = security.add(item)
            guard addStatus == errSecSuccess else { throw statusError(addStatus) }
            return
        }
        guard status == errSecSuccess else { throw statusError(status) }
    }

    func removePassword(account: String) throws {
        let status = security.delete(identityQuery(account: account))
        guard KeychainItemStatusPolicy.deletionSucceeded(status) else {
            throw statusError(status)
        }
    }

    private func identityQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
