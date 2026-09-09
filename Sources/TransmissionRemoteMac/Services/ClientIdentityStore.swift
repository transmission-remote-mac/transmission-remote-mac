// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import CryptoKit
import Foundation
import Security

struct ImportedClientIdentity<Identity> {
    let identity: Identity
    let metadata: ClientIdentityMetadata
    let hasPrivateKey: Bool

    private let cleanupLease: ClientIdentityImportCleanupLease

    init(
        identity: Identity,
        metadata: ClientIdentityMetadata,
        hasPrivateKey: Bool,
        cleanup: @escaping () throws -> Void = {}
    ) {
        self.identity = identity
        self.metadata = metadata
        self.hasPrivateKey = hasPrivateKey
        cleanupLease = ClientIdentityImportCleanupLease(cleanup: cleanup)
    }

    func cleanup() throws {
        try cleanupLease.cleanup()
    }
}

private final class ClientIdentityImportCleanupLease {
    private var cleanupHandler: (() throws -> Void)?

    init(cleanup: @escaping () throws -> Void) {
        cleanupHandler = cleanup
    }

    func cleanup() throws {
        guard let cleanupHandler else { return }
        try cleanupHandler()
        self.cleanupHandler = nil
    }

    deinit {
        try? cleanupHandler?()
    }
}

struct ResolvedClientIdentity<Identity> {
    let identity: Identity
    let metadata: ClientIdentityMetadata
    let hasPrivateKey: Bool
}

enum ClientIdentityKeychainItemClass: Hashable, Sendable {
    case certificate
    case privateKey
}

struct ClientIdentityKeychainItemReference: Hashable, Sendable {
    let itemClass: ClientIdentityKeychainItemClass
    let persistentReference: Data
}

struct ClientIdentityImportRollbackToken: Hashable, Sendable {
    let identityPersistentReference: Data
    let createdItems: [ClientIdentityKeychainItemReference]

    init(
        identityPersistentReference: Data = Data(),
        createdItems: [ClientIdentityKeychainItemReference]
    ) {
        self.identityPersistentReference = identityPersistentReference
        self.createdItems = createdItems
    }

    var isEmpty: Bool {
        createdItems.isEmpty
    }
}

struct PersistedClientIdentityReference: Hashable, Sendable {
    let persistentReference: Data
    let rollbackToken: ClientIdentityImportRollbackToken
}

struct ClientIdentityImportResult: Hashable, Sendable {
    let metadata: ClientIdentityMetadata
    let rollbackToken: ClientIdentityImportRollbackToken?
}

protocol PKCS12IdentityImporting {
    associatedtype Identity

    func importIdentity(from data: Data, passphrase: String) throws -> ImportedClientIdentity<Identity>
}

protocol SecIdentityPersistentReferenceResolving {
    associatedtype Identity

    func persistIdentity(_ identity: Identity) throws -> PersistedClientIdentityReference
    func rollbackPersistence(_ token: ClientIdentityImportRollbackToken) throws
    func resolveIdentity(persistentReference: Data) throws -> ResolvedClientIdentity<Identity>?
}

protocol ClientIdentityReferenceBindingStoring {
    func persistentReference(for profileID: ConnectionProfile.ID) throws -> Data?
    func allPersistentReferences() throws -> [Data]
    func setPersistentReference(_ persistentReference: Data, for profileID: ConnectionProfile.ID) throws
    func removePersistentReference(for profileID: ConnectionProfile.ID) throws
}

protocol ConnectionClientIdentityStoring {
    func importAndBind(
        data: Data,
        passphrase: String,
        profileID: ConnectionProfile.ID,
        scheme: String,
        now: Date
    ) throws -> ClientIdentityMetadata
    func importAndBindTransaction(
        data: Data,
        passphrase: String,
        profileID: ConnectionProfile.ID,
        scheme: String,
        now: Date
    ) throws -> ClientIdentityImportResult
    func rollbackImportedIdentity(_ token: ClientIdentityImportRollbackToken) throws
    func persistentReference(for profileID: ConnectionProfile.ID) throws -> Data?
    func restorePersistentReference(_ persistentReference: Data?, for profileID: ConnectionProfile.ID) throws
    func removeBinding(for profileID: ConnectionProfile.ID) throws
}

extension ConnectionClientIdentityStoring {
    func importAndBindTransaction(
        data: Data,
        passphrase: String,
        profileID: ConnectionProfile.ID,
        scheme: String,
        now: Date
    ) throws -> ClientIdentityImportResult {
        ClientIdentityImportResult(
            metadata: try importAndBind(
                data: data,
                passphrase: passphrase,
                profileID: profileID,
                scheme: scheme,
                now: now
            ),
            rollbackToken: nil
        )
    }

    func rollbackImportedIdentity(_ token: ClientIdentityImportRollbackToken) throws {}
}

protocol ClientIdentityCredentialResolving: Sendable {
    func credential(for profile: ConnectionProfile) throws -> URLCredential
}

struct ClientIdentityValidator {
    static func validate<Identity>(
        scheme: String,
        expectedMetadata: ClientIdentityMetadata?,
        resolvedIdentity: ResolvedClientIdentity<Identity>,
        now: Date = Date()
    ) throws -> Identity {
        guard scheme.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "https" else {
            throw ClientIdentityStoreError.nonHTTPS
        }
        guard resolvedIdentity.hasPrivateKey else {
            throw ClientIdentityStoreError.missingPrivateKey
        }
        guard now >= resolvedIdentity.metadata.notBefore else {
            throw ClientIdentityStoreError.notYetValid(resolvedIdentity.metadata.notBefore)
        }
        guard now <= resolvedIdentity.metadata.notAfter else {
            throw ClientIdentityStoreError.expired(resolvedIdentity.metadata.notAfter)
        }

        if let expectedMetadata {
            let expectedFingerprint = canonicalFingerprint(expectedMetadata.sha256Fingerprint)
            let actualFingerprint = canonicalFingerprint(resolvedIdentity.metadata.sha256Fingerprint)
            guard expectedFingerprint == actualFingerprint else {
                throw ClientIdentityStoreError.fingerprintMismatch(
                    expected: expectedMetadata.sha256Fingerprint,
                    actual: resolvedIdentity.metadata.sha256Fingerprint
                )
            }
        }

        return resolvedIdentity.identity
    }

    private static func canonicalFingerprint(_ fingerprint: String) -> String {
        fingerprint
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ":", with: "")
            .uppercased()
    }
}

final class ClientIdentityStore<Importer, Resolver, BindingStore>
where Importer: PKCS12IdentityImporting,
      Resolver: SecIdentityPersistentReferenceResolving,
      BindingStore: ClientIdentityReferenceBindingStoring,
      Importer.Identity == Resolver.Identity {
    private let importer: Importer
    private let resolver: Resolver
    private let bindingStore: BindingStore

    init(importer: Importer, resolver: Resolver, bindingStore: BindingStore) {
        self.importer = importer
        self.resolver = resolver
        self.bindingStore = bindingStore
    }

    func importAndBind(
        data: Data,
        passphrase: String,
        profileID: ConnectionProfile.ID,
        scheme: String,
        now: Date = Date()
    ) throws -> ClientIdentityMetadata {
        try importAndBindTransaction(
            data: data,
            passphrase: passphrase,
            profileID: profileID,
            scheme: scheme,
            now: now
        ).metadata
    }

    func importAndBindTransaction(
        data: Data,
        passphrase: String,
        profileID: ConnectionProfile.ID,
        scheme: String,
        now: Date = Date()
    ) throws -> ClientIdentityImportResult {
        guard scheme.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "https" else {
            throw ClientIdentityStoreError.nonHTTPS
        }

        let importedIdentity = try importer.importIdentity(from: data, passphrase: passphrase)
        var previousReference: Data?
        var persistence: PersistedClientIdentityReference?
        var bindingMutationAttempted = false

        do {
            _ = try ClientIdentityValidator.validate(
                scheme: scheme,
                expectedMetadata: importedIdentity.metadata,
                resolvedIdentity: ResolvedClientIdentity(
                    identity: importedIdentity.identity,
                    metadata: importedIdentity.metadata,
                    hasPrivateKey: importedIdentity.hasPrivateKey
                ),
                now: now
            )
            persistence = try resolver.persistIdentity(importedIdentity.identity)
            try importedIdentity.cleanup()
            previousReference = try bindingStore.persistentReference(for: profileID)
            guard let persistence else {
                throw ClientIdentityStoreError.staleReference
            }
            guard let resolvedIdentity = try resolver.resolveIdentity(
                persistentReference: persistence.persistentReference
            ) else {
                throw ClientIdentityStoreError.staleReference
            }

            _ = try ClientIdentityValidator.validate(
                scheme: scheme,
                expectedMetadata: importedIdentity.metadata,
                resolvedIdentity: resolvedIdentity,
                now: now
            )
            bindingMutationAttempted = true
            try bindingStore.setPersistentReference(persistence.persistentReference, for: profileID)
            return ClientIdentityImportResult(
                metadata: resolvedIdentity.metadata,
                rollbackToken: persistence.rollbackToken.isEmpty ? nil : persistence.rollbackToken
            )
        } catch {
            var rollbackErrors: [Error] = []
            if bindingMutationAttempted {
                do {
                    try restorePersistentReference(previousReference, for: profileID)
                } catch {
                    rollbackErrors.append(error)
                }
            }
            if let persistence, !persistence.rollbackToken.isEmpty {
                do {
                    try rollbackImportedIdentity(persistence.rollbackToken)
                } catch {
                    rollbackErrors.append(error)
                }
            }
            do {
                try importedIdentity.cleanup()
            } catch {
                rollbackErrors.append(error)
            }
            guard rollbackErrors.isEmpty else {
                throw ClientIdentityStoreError.transactionRollbackFailed(
                    original: error.localizedDescription,
                    rollback: rollbackErrors.map { $0.localizedDescription }.joined(separator: "; ")
                )
            }
            throw error
        }
    }

    func rollbackImportedIdentity(_ token: ClientIdentityImportRollbackToken) throws {
        guard !token.isEmpty else { return }
        if !token.identityPersistentReference.isEmpty,
           try bindingStore.allPersistentReferences().contains(token.identityPersistentReference) {
            throw ClientIdentityStoreError.rollbackIdentityStillBound
        }
        try resolver.rollbackPersistence(token)
    }

    func resolveIdentity(
        for profileID: ConnectionProfile.ID,
        scheme: String,
        expectedMetadata: ClientIdentityMetadata?,
        now: Date = Date()
    ) throws -> Resolver.Identity {
        guard scheme.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "https" else {
            throw ClientIdentityStoreError.nonHTTPS
        }
        guard let persistentReference = try bindingStore.persistentReference(for: profileID),
              let resolvedIdentity = try resolver.resolveIdentity(persistentReference: persistentReference) else {
            throw ClientIdentityStoreError.staleReference
        }

        return try ClientIdentityValidator.validate(
            scheme: scheme,
            expectedMetadata: expectedMetadata,
            resolvedIdentity: resolvedIdentity,
            now: now
        )
    }

    func removeBinding(for profileID: ConnectionProfile.ID) throws {
        try bindingStore.removePersistentReference(for: profileID)
    }

    func persistentReference(for profileID: ConnectionProfile.ID) throws -> Data? {
        try bindingStore.persistentReference(for: profileID)
    }

    func restorePersistentReference(
        _ persistentReference: Data?,
        for profileID: ConnectionProfile.ID
    ) throws {
        if let persistentReference {
            try bindingStore.setPersistentReference(persistentReference, for: profileID)
        } else {
            try bindingStore.removePersistentReference(for: profileID)
        }
    }
}

extension ClientIdentityStore: ConnectionClientIdentityStoring {}

struct SecurityPKCS12IdentityImporter: PKCS12IdentityImporting {
    func importIdentity(from data: Data, passphrase: String) throws -> ImportedClientIdentity<SecIdentity> {
        let retainedPassphrase = passphrase as CFString
        var format = SecExternalFormat.formatPKCS12
        var itemType = SecExternalItemType.itemTypeAggregate
        var parameters = SecItemImportExportKeyParameters(
            version: UInt32(SEC_KEY_IMPORT_EXPORT_PARAMS_VERSION),
            flags: [],
            passphrase: Unmanaged.passUnretained(retainedPassphrase),
            alertTitle: nil,
            alertPrompt: nil,
            accessRef: nil,
            keyUsage: nil,
            keyAttributes: nil
        )
        var importedItems: CFArray?
        let status = SecItemImport(
            data as CFData,
            nil,
            &format,
            &itemType,
            [],
            &parameters,
            nil,
            &importedItems
        )

        if status == errSecAuthFailed || status == errSecPkcs12VerifyFailure {
            throw ClientIdentityStoreError.wrongPassword
        }
        guard status == errSecSuccess else {
            throw ClientIdentityStoreError.importFailure(status)
        }
        guard let rawIdentity = (importedItems as? [CFTypeRef])?.first(where: {
            CFGetTypeID($0) == SecIdentityGetTypeID()
        }) else {
            throw ClientIdentityStoreError.importFailure(errSecDecode)
        }
        let identity: SecIdentity = rawIdentity as! SecIdentity
        return try Self.importedIdentity(identity)
    }

    private static func importedIdentity(_ identity: SecIdentity) throws -> ImportedClientIdentity<SecIdentity> {
        var certificate: SecCertificate?
        let certificateStatus = SecIdentityCopyCertificate(identity, &certificate)
        guard certificateStatus == errSecSuccess, let certificate else {
            throw ClientIdentityStoreError.importFailure(certificateStatus)
        }

        var privateKey: SecKey?
        let privateKeyStatus = SecIdentityCopyPrivateKey(identity, &privateKey)
        let hasPrivateKey = privateKeyStatus == errSecSuccess && privateKey != nil

        return ImportedClientIdentity(
            identity: identity,
            metadata: try SecurityClientIdentityMetadataReader.metadata(for: certificate),
            hasPrivateKey: hasPrivateKey
        )
    }
}

struct KeychainSecIdentityPersistentReferenceResolver: SecIdentityPersistentReferenceResolving {
    func persistIdentity(_ identity: SecIdentity) throws -> PersistedClientIdentityReference {
        let components = try identityComponents(identity)
        var createdItems: [ClientIdentityKeychainItemReference] = []
        do {
            let persistedCertificateComponent = try persistComponent(
                itemClass: kSecClassCertificate,
                rollbackItemClass: .certificate,
                valueReference: components.certificate
            )
            if persistedCertificateComponent.wasCreated {
                createdItems.append(persistedCertificateComponent.reference)
            }

            let privateKey = try persistComponent(
                itemClass: kSecClassKey,
                rollbackItemClass: .privateKey,
                valueReference: components.privateKey
            )
            if privateKey.wasCreated {
                createdItems.append(privateKey.reference)
            }

            let storedCertificate = try certificate(
                persistentReference: persistedCertificateComponent.reference.persistentReference
            )
            var storedIdentity: SecIdentity?
            let identityStatus = SecIdentityCreateWithCertificate(
                nil,
                storedCertificate,
                &storedIdentity
            )
            guard identityStatus == errSecSuccess, let storedIdentity else {
                throw ClientIdentityStoreError.keychainFailure(identityStatus)
            }
            guard let identityPersistentReference = try persistentReference(
                itemClass: kSecClassIdentity,
                valueReference: storedIdentity
            ) else {
                throw ClientIdentityStoreError.staleReference
            }

            return PersistedClientIdentityReference(
                persistentReference: identityPersistentReference,
                rollbackToken: ClientIdentityImportRollbackToken(
                    identityPersistentReference: identityPersistentReference,
                    createdItems: createdItems
                )
            )
        } catch {
            do {
                try rollbackPersistence(
                    ClientIdentityImportRollbackToken(createdItems: createdItems)
                )
            } catch let rollbackError {
                throw ClientIdentityStoreError.transactionRollbackFailed(
                    original: error.localizedDescription,
                    rollback: rollbackError.localizedDescription
                )
            }
            throw error
        }
    }

    func rollbackPersistence(_ token: ClientIdentityImportRollbackToken) throws {
        var errors: [Error] = []
        for item in token.createdItems.reversed() {
            let itemClass: CFString = switch item.itemClass {
            case .certificate: kSecClassCertificate
            case .privateKey: kSecClassKey
            }
            let query: [String: Any] = [
                kSecClass as String: itemClass,
                kSecValuePersistentRef as String: item.persistentReference,
                kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip
            ]
            let status = SecItemDelete(query as CFDictionary)
            guard KeychainItemStatusPolicy.deletionSucceeded(status) else {
                errors.append(ClientIdentityStoreError.keychainFailure(status))
                continue
            }
        }
        guard errors.isEmpty else {
            throw ClientIdentityStoreError.rollbackFailure(
                errors.map { $0.localizedDescription }.joined(separator: "; ")
            )
        }
    }

    func resolveIdentity(persistentReference: Data) throws -> ResolvedClientIdentity<SecIdentity>? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecValuePersistentRef as String: persistentReference,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if KeychainItemStatusPolicy.isAbsent(status) {
            return nil
        }
        guard status == errSecSuccess, let item else {
            throw ClientIdentityStoreError.keychainFailure(status)
        }
        let identity: SecIdentity = item as! SecIdentity

        var certificate: SecCertificate?
        let certificateStatus = SecIdentityCopyCertificate(identity, &certificate)
        guard certificateStatus == errSecSuccess, let certificate else {
            throw ClientIdentityStoreError.staleReference
        }

        var privateKey: SecKey?
        let privateKeyStatus = SecIdentityCopyPrivateKey(identity, &privateKey)
        let hasPrivateKey = privateKeyStatus == errSecSuccess && privateKey != nil

        return ResolvedClientIdentity(
            identity: identity,
            metadata: try SecurityClientIdentityMetadataReader.metadata(for: certificate),
            hasPrivateKey: hasPrivateKey
        )
    }

    private func identityComponents(_ identity: SecIdentity) throws -> (certificate: SecCertificate, privateKey: SecKey) {
        var certificate: SecCertificate?
        let certificateStatus = SecIdentityCopyCertificate(identity, &certificate)
        guard certificateStatus == errSecSuccess, let certificate else {
            throw ClientIdentityStoreError.keychainFailure(certificateStatus)
        }

        var privateKey: SecKey?
        let privateKeyStatus = SecIdentityCopyPrivateKey(identity, &privateKey)
        guard privateKeyStatus == errSecSuccess, let privateKey else {
            throw ClientIdentityStoreError.missingPrivateKey
        }
        return (certificate, privateKey)
    }

    private func persistComponent(
        itemClass: CFString,
        rollbackItemClass: ClientIdentityKeychainItemClass,
        valueReference: CFTypeRef
    ) throws -> (reference: ClientIdentityKeychainItemReference, wasCreated: Bool) {
        let query: [String: Any] = [
            kSecClass as String: itemClass,
            kSecValueRef as String: valueReference,
            kSecReturnPersistentRef as String: true,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip,
        ]
        var item: CFTypeRef?
        let status = SecItemAdd(query as CFDictionary, &item)
        if status == errSecSuccess, let persistentReference = item as? Data {
            return (
                ClientIdentityKeychainItemReference(
                    itemClass: rollbackItemClass,
                    persistentReference: persistentReference
                ),
                true
            )
        }
        guard status == errSecDuplicateItem,
              let persistentReference = try persistentReference(
                  itemClass: itemClass,
                  valueReference: valueReference
              ) else {
            throw ClientIdentityStoreError.keychainFailure(status)
        }
        return (
            ClientIdentityKeychainItemReference(
                itemClass: rollbackItemClass,
                persistentReference: persistentReference
            ),
            false
        )
    }

    private func persistentReference(
        itemClass: CFString,
        valueReference: CFTypeRef
    ) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: itemClass,
            kSecValueRef as String: valueReference,
            kSecReturnPersistentRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let reference = item as? Data else {
            throw ClientIdentityStoreError.keychainFailure(status)
        }
        return reference
    }

    private func certificate(persistentReference: Data) throws -> SecCertificate {
        let query: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValuePersistentRef as String: persistentReference,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let item else {
            throw ClientIdentityStoreError.keychainFailure(status)
        }
        return item as! SecCertificate
    }
}

final class KeychainClientIdentityReferenceBindingStore: ClientIdentityReferenceBindingStoring {
    static let service = "net.pokwer.TransmissionRemoteMac.ClientIdentityReference.v1"
    static let accountNamespace = "stable-v1"

    private static let itemLabel = "TransmissionRemoteMac Client Identity Reference"

    func persistentReference(for profileID: ConnectionProfile.ID) throws -> Data? {
        var query = Self.identityQuery(for: profileID)
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if KeychainItemStatusPolicy.isAbsent(status) {
            return nil
        }
        guard status == errSecSuccess, let persistentReference = item as? Data else {
            throw ClientIdentityStoreError.keychainFailure(status)
        }
        return persistentReference
    }

    func allPersistentReferences() throws -> [Data] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if KeychainItemStatusPolicy.isAbsent(status) {
            return []
        }
        guard status == errSecSuccess else {
            throw ClientIdentityStoreError.keychainFailure(status)
        }
        if let references = item as? [Data] {
            return references
        }
        if let reference = item as? Data {
            return [reference]
        }
        throw ClientIdentityStoreError.keychainFailure(errSecDecode)
    }

    func setPersistentReference(_ persistentReference: Data, for profileID: ConnectionProfile.ID) throws {
        let query = Self.identityQuery(for: profileID)
        let attributes = [kSecValueData as String: persistentReference]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        if status == errSecItemNotFound {
            var item = query
            item[kSecAttrLabel as String] = Self.itemLabel
            item[kSecValueData as String] = persistentReference
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw ClientIdentityStoreError.keychainFailure(addStatus)
            }
            return
        }

        guard status == errSecSuccess else {
            throw ClientIdentityStoreError.keychainFailure(status)
        }
    }

    func removePersistentReference(for profileID: ConnectionProfile.ID) throws {
        let status = SecItemDelete(Self.identityQuery(for: profileID) as CFDictionary)
        guard KeychainItemStatusPolicy.deletionSucceeded(status) else {
            throw ClientIdentityStoreError.keychainFailure(status)
        }
    }

    static func account(for profileID: ConnectionProfile.ID) -> String {
        "\(accountNamespace):\(profileID.uuidString)"
    }

    private static func identityQuery(for profileID: ConnectionProfile.ID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: profileID)
        ]
    }
}

private enum SecurityClientIdentityMetadataReader {
    static func metadata(for certificate: SecCertificate) throws -> ClientIdentityMetadata {
        let subject = stringValue(for: kSecOIDX509V1SubjectName, in: certificate)
        let issuer = stringValue(for: kSecOIDX509V1IssuerName, in: certificate)
        guard let notBefore = dateValue(for: kSecOIDX509V1ValidityNotBefore, in: certificate),
              let notAfter = dateValue(for: kSecOIDX509V1ValidityNotAfter, in: certificate) else {
            throw ClientIdentityStoreError.importFailure(errSecDecode)
        }

        let displayName = SecCertificateCopySubjectSummary(certificate) as String? ?? subject
        let fingerprint = SHA256.hash(data: SecCertificateCopyData(certificate) as Data)
            .map { String(format: "%02X", $0) }
            .joined()

        return ClientIdentityMetadata(
            displayName: displayName,
            sha256Fingerprint: fingerprint,
            subject: subject,
            issuer: issuer,
            notBefore: notBefore,
            notAfter: notAfter
        )
    }

    private static func dateValue(for oid: CFString, in certificate: SecCertificate) -> Date? {
        propertyValue(for: oid, in: certificate) as? Date
    }

    private static func stringValue(for oid: CFString, in certificate: SecCertificate) -> String {
        flattenedString(from: propertyValue(for: oid, in: certificate))
    }

    private static func propertyValue(for oid: CFString, in certificate: SecCertificate) -> Any? {
        let keys = [oid] as CFArray
        guard let values = SecCertificateCopyValues(certificate, keys, nil) as? [String: Any],
              let property = values[oid as String] as? [String: Any] else {
            return nil
        }
        return property[kSecPropertyKeyValue as String]
    }

    private static func flattenedString(from value: Any?) -> String {
        if let string = value as? String {
            return string
        }
        if let properties = value as? [[String: Any]] {
            return properties.compactMap { property in
                let label = property[kSecPropertyKeyLabel as String] as? String
                    ?? property[kSecPropertyKeyLocalizedLabel as String] as? String
                let value = flattenedString(from: property[kSecPropertyKeyValue as String])
                guard !value.isEmpty else { return nil }
                return label.map { "\($0)=\(value)" } ?? value
            }.joined(separator: ", ")
        }
        if let dictionary = value as? [String: Any] {
            return flattenedString(from: dictionary[kSecPropertyKeyValue as String])
        }
        return value.map(String.init(describing:)) ?? ""
    }
}

enum ClientIdentityStoreError: LocalizedError, Equatable {
    case wrongPassword
    case importFailure(OSStatus)
    case staleReference
    case missingPrivateKey
    case expired(Date)
    case notYetValid(Date)
    case fingerprintMismatch(expected: String, actual: String)
    case nonHTTPS
    case keychainFailure(OSStatus)
    case rollbackFailure(String)
    case rollbackIdentityStillBound
    case transactionRollbackFailed(original: String, rollback: String)
    case performanceIsolation

    var errorDescription: String? {
        switch self {
        case .wrongPassword:
            "The PKCS#12 password is incorrect."
        case .importFailure(let status):
            "The PKCS#12 client identity could not be imported (status \(status))."
        case .staleReference:
            "The saved client identity is no longer available in the Keychain."
        case .missingPrivateKey:
            "The selected client identity does not contain a private key."
        case .expired(let expiryDate):
            "The selected client identity expired on \(expiryDate.formatted())."
        case .notYetValid(let startDate):
            "The selected client identity is not valid until \(startDate.formatted())."
        case .fingerprintMismatch:
            "The saved client identity no longer matches its certificate fingerprint."
        case .nonHTTPS:
            "A client identity can only be used with an HTTPS server."
        case .keychainFailure(let status):
            "Client identity Keychain access failed with status \(status)."
        case .rollbackFailure(let details):
            "Client identity Keychain rollback failed (\(details))."
        case .rollbackIdentityStillBound:
            "Client identity Keychain rollback was refused because the identity is still bound to a profile."
        case .transactionRollbackFailed(let original, let rollback):
            "Client identity update failed (\(original)); Keychain rollback also failed (\(rollback))."
        case .performanceIsolation:
            "Client identity Keychain access is disabled during isolated performance proof."
        }
    }
}

struct KeychainClientIdentityCredentialResolver: ClientIdentityCredentialResolving, @unchecked Sendable {
    private let environment: [String: String]
    private let store = ClientIdentityStore(
        importer: SecurityPKCS12IdentityImporter(),
        resolver: KeychainSecIdentityPersistentReferenceResolver(),
        bindingStore: KeychainClientIdentityReferenceBindingStore()
    )

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
    }

    func credential(for profile: ConnectionProfile) throws -> URLCredential {
#if DEBUG
        guard environment[PerformancePasswordStoreIsolation.modeEnvironmentKey] == nil else {
            throw ClientIdentityStoreError.performanceIsolation
        }
#endif
        guard profile.scheme.lowercased() == "https", profile.hasClientIdentity else {
            throw ClientIdentityStoreError.nonHTTPS
        }
        let identity = try store.resolveIdentity(
            for: profile.id,
            scheme: profile.scheme,
            expectedMetadata: profile.clientIdentityMetadataForTransport
        )
        var certificate: SecCertificate?
        let status = SecIdentityCopyCertificate(identity, &certificate)
        guard status == errSecSuccess, let certificate else {
            throw ClientIdentityStoreError.staleReference
        }
        return URLCredential(
            identity: identity,
            certificates: [certificate],
            persistence: .forSession
        )
    }
}
