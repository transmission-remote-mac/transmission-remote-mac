// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation
import Security
import XCTest
@testable import TransmissionRemoteMac

final class GenericPasswordKeychainAccessorTests: XCTestCase {
    private let profileID = UUID(uuidString: "00000000-0000-0000-0000-000000000123")!

    func testTypedStoresRetainExactNamespacesAndNoninteractiveReadQueries() throws {
        for fixture in fixtures() {
            fixture.security.readItem = Data("fixture-password".utf8) as CFData
            XCTAssertEqual(try fixture.read(profileID), "fixture-password")
            let query = try XCTUnwrap(fixture.security.readQueries.first)
            assertIdentity(query, service: fixture.service)
            XCTAssertEqual(query[kSecUseAuthenticationUI as String] as? String, kSecUseAuthenticationUISkip as String)
            XCTAssertEqual(query[kSecReturnData as String] as? Bool, true)
            XCTAssertEqual(query[kSecMatchLimit as String] as? String, kSecMatchLimitOne as String)
            XCTAssertEqual(query.count, 6)
            XCTAssertTrue(fixture.security.updates.isEmpty)
            XCTAssertTrue(fixture.security.addedItems.isEmpty)
            XCTAssertTrue(fixture.security.deletedQueries.isEmpty)
        }
    }

    func testTypedStoresUpdateExistingItemsWithoutChangingLabelsOrAccessControl() throws {
        for fixture in fixtures() {
            try fixture.save("replacement", profileID)
            let update = try XCTUnwrap(fixture.security.updates.first)
            assertIdentity(update.query, service: fixture.service)
            XCTAssertEqual(update.query.count, 3)
            XCTAssertEqual(update.attributes.count, 1)
            XCTAssertEqual(update.attributes[kSecValueData as String] as? Data, Data("replacement".utf8))
            XCTAssertTrue(fixture.security.addedItems.isEmpty)
        }
    }

    func testTypedStoresOnlyAddMissingItemsWithTheirExistingLabels() throws {
        for fixture in fixtures() {
            fixture.security.updateStatus = errSecItemNotFound
            try fixture.save("new-password", profileID)
            XCTAssertEqual(fixture.security.updates.count, 1)
            let item = try XCTUnwrap(fixture.security.addedItems.first)
            assertIdentity(item, service: fixture.service)
            XCTAssertEqual(item[kSecAttrLabel as String] as? String, fixture.label)
            XCTAssertEqual(item[kSecValueData as String] as? Data, Data("new-password".utf8))
            XCTAssertEqual(item.count, 5)
        }
    }

    func testTypedStoresPreserveReadUpdateAddAndDeleteStatusErrors() {
        for fixture in fixtures() {
            for status in [errSecInteractionNotAllowed, errSecAuthFailed, errSecNotAvailable] {
                fixture.security.readStatus = status
                XCTAssertThrowsError(try fixture.read(profileID)) { fixture.assertStatus($0, status) }
                fixture.security.updateStatus = status
                XCTAssertThrowsError(try fixture.save("fixture", profileID)) { fixture.assertStatus($0, status) }
                XCTAssertTrue(fixture.security.addedItems.isEmpty)
                fixture.security.deleteStatus = status
                XCTAssertThrowsError(try fixture.remove(profileID)) { fixture.assertStatus($0, status) }
            }
            fixture.security.updateStatus = errSecItemNotFound
            fixture.security.addStatus = errSecDuplicateItem
            XCTAssertThrowsError(try fixture.save("fixture", profileID)) {
                fixture.assertStatus($0, errSecDuplicateItem)
            }
            XCTAssertEqual(fixture.security.addedItems.count, 1)
        }
    }

    func testTypedStoresKeepMissingReadsCorruptValuesAndIdempotentDeletionDistinct() throws {
        for fixture in fixtures() {
            fixture.security.readStatus = errSecItemNotFound
            XCTAssertNil(try fixture.read(profileID))
            fixture.security.readStatus = errSecSuccess
            let corruptItems: [CFTypeRef?] = [nil, "wrong-type" as CFString, Data([0xFF]) as CFData]
            for item in corruptItems {
                fixture.security.readItem = item
                XCTAssertThrowsError(try fixture.read(profileID)) {
                    XCTAssertEqual($0 as? KeychainSecretValueError, .corruptItem)
                }
            }
            fixture.security.readItem = Data() as CFData
            XCTAssertEqual(try fixture.read(profileID), "")
            for status in [errSecSuccess, errSecItemNotFound] {
                fixture.security.deleteStatus = status
                try fixture.remove(profileID)
            }
            for query in fixture.security.deletedQueries {
                assertIdentity(query, service: fixture.service)
                XCTAssertEqual(query.count, 3)
            }
        }
    }

    private func assertIdentity(_ query: [String: Any], service: String) {
        XCTAssertEqual(query[kSecClass as String] as? String, kSecClassGenericPassword as String)
        XCTAssertEqual(query[kSecAttrService as String] as? String, service)
        XCTAssertEqual(query[kSecAttrAccount as String] as? String, "stable-v1:\(profileID.uuidString)")
    }

    private func fixtures() -> [PasswordStoreFixture] {
        let rpcSecurity = RecordingGenericPasswordSecurityAPI()
        let rpc = KeychainPasswordStore(security: rpcSecurity)
        let proxySecurity = RecordingGenericPasswordSecurityAPI()
        let proxy = KeychainProxyPasswordStore(security: proxySecurity)
        return [
            PasswordStoreFixture(
                security: rpcSecurity,
                service: "net.pokwer.TransmissionRemoteMac.TransmissionRPC.v5",
                label: "TransmissionRemoteMac RPC Password",
                read: rpc.password,
                save: rpc.setPassword,
                remove: rpc.removePassword,
                assertStatus: { XCTAssertEqual($0 as? KeychainPasswordStoreError, .unhandledStatus($1)) }
            ),
            PasswordStoreFixture(
                security: proxySecurity,
                service: "net.pokwer.TransmissionRemoteMac.ProxyPassword.v1",
                label: "TransmissionRemoteMac Proxy Password",
                read: proxy.password,
                save: proxy.setPassword,
                remove: proxy.removePassword,
                assertStatus: { XCTAssertEqual($0 as? KeychainProxyPasswordStoreError, .unhandledStatus($1)) }
            )
        ]
    }
}

private struct PasswordStoreFixture {
    let security: RecordingGenericPasswordSecurityAPI
    let service: String
    let label: String
    let read: (UUID) throws -> String?
    let save: (String, UUID) throws -> Void
    let remove: (UUID) throws -> Void
    let assertStatus: (Error, OSStatus) -> Void
}

private final class RecordingGenericPasswordSecurityAPI: GenericPasswordSecurityAPI {
    var readStatus: OSStatus = errSecSuccess
    var readItem: CFTypeRef?
    var updateStatus: OSStatus = errSecSuccess
    var addStatus: OSStatus = errSecSuccess
    var deleteStatus: OSStatus = errSecSuccess
    var readQueries: [[String: Any]] = []
    var updates: [(query: [String: Any], attributes: [String: Any])] = []
    var addedItems: [[String: Any]] = []
    var deletedQueries: [[String: Any]] = []

    func copyMatching(_ query: [String: Any]) -> (status: OSStatus, item: CFTypeRef?) {
        readQueries.append(query)
        return (readStatus, readItem)
    }

    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        updates.append((query, attributes))
        return updateStatus
    }

    func add(_ item: [String: Any]) -> OSStatus {
        addedItems.append(item)
        return addStatus
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        deletedQueries.append(query)
        return deleteStatus
    }
}
