// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation
import XCTest
@testable import TransmissionRemoteMac

final class ClientIdentityStoreTests: XCTestCase {
    private let profileID = UUID(uuidString: "A16E7D7A-7E66-40F4-B910-D623DB7E9411")!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testMetadataEncodingContainsOnlyPublicCertificateFacts() throws {
        let metadata = makeMetadata(fingerprint: "PUBLIC-FINGERPRINT")
        let encoded = try JSONEncoder().encode(metadata)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        XCTAssertEqual(
            Set(object.keys),
            ["displayName", "sha256Fingerprint", "subject", "issuer", "notBefore", "notAfter"]
        )
        let json = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(json.localizedCaseInsensitiveContains("path"))
        XCTAssertFalse(json.localizedCaseInsensitiveContains("passphrase"))
        XCTAssertFalse(json.localizedCaseInsensitiveContains("password"))
        XCTAssertFalse(json.localizedCaseInsensitiveContains("persistentReference"))
        XCTAssertFalse(json.localizedCaseInsensitiveContains("identityBytes"))
    }

    func testBindingIdentityUsesStableAppOwnedNamespace() {
        XCTAssertEqual(
            KeychainClientIdentityReferenceBindingStore.service,
            "net.pokwer.TransmissionRemoteMac.ClientIdentityReference.v1"
        )
        XCTAssertEqual(
            KeychainClientIdentityReferenceBindingStore.account(for: profileID),
            "stable-v1:A16E7D7A-7E66-40F4-B910-D623DB7E9411"
        )
    }

    func testValidatorAcceptsValidityWindowBoundaries() throws {
        let metadata = makeMetadata(
            notBefore: now,
            notAfter: now.addingTimeInterval(60)
        )
        let resolved = ResolvedClientIdentity(identity: FakeIdentity(id: 1), metadata: metadata, hasPrivateKey: true)

        XCTAssertEqual(
            try ClientIdentityValidator.validate(
                scheme: "https",
                expectedMetadata: metadata,
                resolvedIdentity: resolved,
                now: now
            ),
            FakeIdentity(id: 1)
        )
        XCTAssertNoThrow(
            try ClientIdentityValidator.validate(
                scheme: "HTTPS",
                expectedMetadata: metadata,
                resolvedIdentity: resolved,
                now: metadata.notAfter
            )
        )
    }

    func testValidatorRejectsNotYetValidAndExpiredCertificates() {
        let future = makeMetadata(
            notBefore: now.addingTimeInterval(1),
            notAfter: now.addingTimeInterval(60)
        )
        XCTAssertThrowsError(
            try ClientIdentityValidator.validate(
                scheme: "https",
                expectedMetadata: future,
                resolvedIdentity: ResolvedClientIdentity(
                    identity: FakeIdentity(id: 1),
                    metadata: future,
                    hasPrivateKey: true
                ),
                now: now
            )
        ) { error in
            XCTAssertEqual(error as? ClientIdentityStoreError, .notYetValid(future.notBefore))
        }

        let expired = makeMetadata(
            notBefore: now.addingTimeInterval(-60),
            notAfter: now.addingTimeInterval(-1)
        )
        XCTAssertThrowsError(
            try ClientIdentityValidator.validate(
                scheme: "https",
                expectedMetadata: expired,
                resolvedIdentity: ResolvedClientIdentity(
                    identity: FakeIdentity(id: 1),
                    metadata: expired,
                    hasPrivateKey: true
                ),
                now: now
            )
        ) { error in
            XCTAssertEqual(error as? ClientIdentityStoreError, .expired(expired.notAfter))
        }
    }

    func testHTTPSGateRunsBeforeImporterOrResolver() {
        let importer = FakeImporter(result: .success(importedIdentity()))
        let resolver = FakeResolver()
        let bindings = MemoryBindingStore()
        let store = ClientIdentityStore(importer: importer, resolver: resolver, bindingStore: bindings)

        XCTAssertThrowsError(
            try store.importAndBind(
                data: Data([0x01]),
                passphrase: "secret",
                profileID: profileID,
                scheme: "http",
                now: now
            )
        ) { error in
            XCTAssertEqual(error as? ClientIdentityStoreError, .nonHTTPS)
        }
        XCTAssertEqual(importer.importCount, 0)
        XCTAssertEqual(resolver.resolveCount, 0)
    }

    func testResolveRejectsStalePersistentReferenceUsingFakes() throws {
        let bindings = MemoryBindingStore()
        try bindings.setPersistentReference(Data([0xA1]), for: profileID)
        let store = ClientIdentityStore(
            importer: FakeImporter(result: .success(importedIdentity())),
            resolver: FakeResolver(),
            bindingStore: bindings
        )

        XCTAssertThrowsError(
            try store.resolveIdentity(
                for: profileID,
                scheme: "https",
                expectedMetadata: makeMetadata(),
                now: now
            )
        ) { error in
            XCTAssertEqual(error as? ClientIdentityStoreError, .staleReference)
        }
    }

    func testResolveRejectsFingerprintMismatchUsingFakes() throws {
        let reference = Data([0xA1])
        let bindings = MemoryBindingStore()
        try bindings.setPersistentReference(reference, for: profileID)
        let resolver = FakeResolver()
        resolver.resolvedByReference[reference] = ResolvedClientIdentity(
            identity: FakeIdentity(id: 1),
            metadata: makeMetadata(fingerprint: "ACTUAL"),
            hasPrivateKey: true
        )
        let store = ClientIdentityStore(
            importer: FakeImporter(result: .success(importedIdentity())),
            resolver: resolver,
            bindingStore: bindings
        )

        XCTAssertThrowsError(
            try store.resolveIdentity(
                for: profileID,
                scheme: "https",
                expectedMetadata: makeMetadata(fingerprint: "EXPECTED"),
                now: now
            )
        ) { error in
            XCTAssertEqual(
                error as? ClientIdentityStoreError,
                .fingerprintMismatch(expected: "EXPECTED", actual: "ACTUAL")
            )
        }
    }

    func testResolveWithoutMetadataStillUsesOnlyTheProfileBoundReference() throws {
        let reference = Data([0xA1])
        let bindings = MemoryBindingStore()
        try bindings.setPersistentReference(reference, for: profileID)
        let resolver = FakeResolver()
        resolver.resolvedByReference[reference] = ResolvedClientIdentity(
            identity: FakeIdentity(id: 7),
            metadata: makeMetadata(fingerprint: "BOUND"),
            hasPrivateKey: true
        )
        let store = ClientIdentityStore(
            importer: FakeImporter(result: .success(importedIdentity())),
            resolver: resolver,
            bindingStore: bindings
        )

        let identity = try store.resolveIdentity(
            for: profileID,
            scheme: "https",
            expectedMetadata: nil,
            now: now
        )

        XCTAssertEqual(identity, FakeIdentity(id: 7))
        XCTAssertEqual(resolver.requestedReferences, [reference])
    }

    func testImportBindsOnlyAfterReferenceResolvesAndValidates() throws {
        let reference = Data([0xA1])
        let imported = importedIdentity()
        let importer = FakeImporter(result: .success(imported))
        let resolver = FakeResolver()
        resolver.referenceByIdentity[imported.identity] = reference
        resolver.resolvedByReference[reference] = ResolvedClientIdentity(
            identity: imported.identity,
            metadata: imported.metadata,
            hasPrivateKey: true
        )
        let bindings = MemoryBindingStore()
        let store = ClientIdentityStore(importer: importer, resolver: resolver, bindingStore: bindings)

        let metadata = try store.importAndBind(
            data: Data([0x01]),
            passphrase: "one-use-passphrase",
            profileID: profileID,
            scheme: "https",
            now: now
        )

        XCTAssertEqual(metadata, imported.metadata)
        XCTAssertEqual(try bindings.persistentReference(for: profileID), reference)
        XCTAssertTrue(importer.receivedExpectedPassphrase)
    }

    func testFailedPostPersistenceValidationRollsBackOnlyNewlyCreatedItems() throws {
        let reference = Data([0xA1])
        let imported = importedIdentity()
        let createdCertificate = ClientIdentityKeychainItemReference(
            itemClass: .certificate,
            persistentReference: Data([0xC1])
        )
        let sharedPrivateKey = ClientIdentityKeychainItemReference(
            itemClass: .privateKey,
            persistentReference: Data([0xD1])
        )
        let resolver = FakeResolver()
        resolver.referenceByIdentity[imported.identity] = reference
        resolver.rollbackTokenByIdentity[imported.identity] = ClientIdentityImportRollbackToken(
            createdItems: [createdCertificate]
        )
        resolver.preexistingItems = [sharedPrivateKey]
        let bindings = MemoryBindingStore()
        let store = ClientIdentityStore(
            importer: FakeImporter(result: .success(imported)),
            resolver: resolver,
            bindingStore: bindings
        )

        XCTAssertThrowsError(
            try store.importAndBindTransaction(
                data: Data([0x01]),
                passphrase: "one-use-passphrase",
                profileID: profileID,
                scheme: "https",
                now: now
            )
        ) { error in
            XCTAssertEqual(error as? ClientIdentityStoreError, .staleReference)
        }

        XCTAssertEqual(resolver.rollbackTokens, [ClientIdentityImportRollbackToken(createdItems: [createdCertificate])])
        XCTAssertEqual(resolver.preexistingItems, Set([sharedPrivateKey]))
        XCTAssertTrue(resolver.createdItems.isEmpty)
        XCTAssertNil(try bindings.persistentReference(for: profileID))
    }

    func testBindingFailureRestoresPreviousReferenceAndRollsBackCreatedItems() throws {
        let reference = Data([0xA1])
        let previousReference = Data([0x99])
        let temporaryImport = FakeTemporaryImportMaterial()
        let imported = importedIdentity(cleanup: temporaryImport.cleanup)
        let createdItems = [
            ClientIdentityKeychainItemReference(
                itemClass: .certificate,
                persistentReference: Data([0xC1])
            ),
            ClientIdentityKeychainItemReference(
                itemClass: .privateKey,
                persistentReference: Data([0xD1])
            ),
        ]
        let resolver = FakeResolver()
        resolver.referenceByIdentity[imported.identity] = reference
        resolver.rollbackTokenByIdentity[imported.identity] = ClientIdentityImportRollbackToken(
            createdItems: createdItems
        )
        resolver.resolvedByReference[reference] = ResolvedClientIdentity(
            identity: imported.identity,
            metadata: imported.metadata,
            hasPrivateKey: true
        )
        let bindings = MemoryBindingStore()
        try bindings.setPersistentReference(previousReference, for: profileID)
        bindings.nextSetErrorAfterMutation = ClientIdentityTransactionTestError.bindingDenied
        let store = ClientIdentityStore(
            importer: FakeImporter(result: .success(imported)),
            resolver: resolver,
            bindingStore: bindings
        )

        XCTAssertThrowsError(
            try store.importAndBindTransaction(
                data: Data([0x01]),
                passphrase: "one-use-passphrase",
                profileID: profileID,
                scheme: "https",
                now: now
            )
        ) { error in
            XCTAssertEqual(error as? ClientIdentityTransactionTestError, .bindingDenied)
        }

        XCTAssertEqual(try bindings.persistentReference(for: profileID), previousReference)
        XCTAssertEqual(
            resolver.rollbackTokens,
            [ClientIdentityImportRollbackToken(createdItems: createdItems)]
        )
        XCTAssertFalse(temporaryImport.isPresent)
        XCTAssertEqual(temporaryImport.cleanupCount, 1)
        XCTAssertTrue(resolver.createdItems.isEmpty)
    }

    func testProfilePersistenceFailureRemovesNewDefaultItemsButPreservesPreexistingSharedMaterial() throws {
        let reference = Data([0xA1])
        let createdCertificate = ClientIdentityKeychainItemReference(
            itemClass: .certificate,
            persistentReference: Data([0xC1])
        )
        let sharedPrivateKey = ClientIdentityKeychainItemReference(
            itemClass: .privateKey,
            persistentReference: Data([0xD1])
        )
        let temporaryImport = FakeTemporaryImportMaterial()
        let imported = importedIdentity(cleanup: temporaryImport.cleanup)
        let token = ClientIdentityImportRollbackToken(
            identityPersistentReference: reference,
            createdItems: [createdCertificate]
        )
        let resolver = FakeResolver()
        resolver.referenceByIdentity[imported.identity] = reference
        resolver.rollbackTokenByIdentity[imported.identity] = token
        resolver.resolvedByReference[reference] = ResolvedClientIdentity(
            identity: imported.identity,
            metadata: imported.metadata,
            hasPrivateKey: true
        )
        resolver.preexistingItems = [sharedPrivateKey]
        let bindings = MemoryBindingStore()
        let store = ClientIdentityStore(
            importer: FakeImporter(result: .success(imported)),
            resolver: resolver,
            bindingStore: bindings
        )

        let result = try store.importAndBindTransaction(
            data: Data([0x01]),
            passphrase: "one-use-passphrase",
            profileID: profileID,
            scheme: "https",
            now: now
        )
        try store.restorePersistentReference(nil, for: profileID)
        try store.rollbackImportedIdentity(try XCTUnwrap(result.rollbackToken))

        XCTAssertFalse(temporaryImport.isPresent)
        XCTAssertEqual(temporaryImport.cleanupCount, 1)
        XCTAssertTrue(resolver.createdItems.isEmpty)
        XCTAssertEqual(resolver.preexistingItems, [sharedPrivateKey])
        XCTAssertNil(try bindings.persistentReference(for: profileID))
    }

    func testPreexistingSharedIdentityProducesNoRollbackToken() throws {
        let reference = Data([0xA1])
        let imported = importedIdentity()
        let resolver = FakeResolver()
        resolver.referenceByIdentity[imported.identity] = reference
        resolver.resolvedByReference[reference] = ResolvedClientIdentity(
            identity: imported.identity,
            metadata: imported.metadata,
            hasPrivateKey: true
        )
        let bindings = MemoryBindingStore()
        let store = ClientIdentityStore(
            importer: FakeImporter(result: .success(imported)),
            resolver: resolver,
            bindingStore: bindings
        )

        let result = try store.importAndBindTransaction(
            data: Data([0x01]),
            passphrase: "one-use-passphrase",
            profileID: profileID,
            scheme: "https",
            now: now
        )

        XCTAssertNil(result.rollbackToken)
        XCTAssertTrue(resolver.rollbackTokens.isEmpty)
        XCTAssertEqual(try bindings.persistentReference(for: profileID), reference)
    }

    func testRollbackFailureReportsOriginalBindingFailure() throws {
        let reference = Data([0xA1])
        let imported = importedIdentity()
        let token = ClientIdentityImportRollbackToken(
            createdItems: [
                ClientIdentityKeychainItemReference(
                    itemClass: .privateKey,
                    persistentReference: Data([0xD1])
                )
            ]
        )
        let resolver = FakeResolver()
        resolver.referenceByIdentity[imported.identity] = reference
        resolver.rollbackTokenByIdentity[imported.identity] = token
        resolver.resolvedByReference[reference] = ResolvedClientIdentity(
            identity: imported.identity,
            metadata: imported.metadata,
            hasPrivateKey: true
        )
        resolver.rollbackError = ClientIdentityTransactionTestError.rollbackDenied
        let bindings = MemoryBindingStore()
        bindings.nextSetErrorAfterMutation = ClientIdentityTransactionTestError.bindingDenied
        let store = ClientIdentityStore(
            importer: FakeImporter(result: .success(imported)),
            resolver: resolver,
            bindingStore: bindings
        )

        XCTAssertThrowsError(
            try store.importAndBindTransaction(
                data: Data([0x01]),
                passphrase: "one-use-passphrase",
                profileID: profileID,
                scheme: "https",
                now: now
            )
        ) { error in
            guard let storeError = error as? ClientIdentityStoreError,
                  case .transactionRollbackFailed(let original, let rollback) = storeError else {
                return XCTFail("Expected a client identity transaction rollback error")
            }
            XCTAssertTrue(original.contains("bindingDenied"))
            XCTAssertTrue(rollback.contains("rollbackDenied"))
        }
    }

    func testRollbackRefusesToDeleteCreatedMaterialStillBoundToAnotherProfile() throws {
        let reference = Data([0xA1])
        let imported = importedIdentity()
        let token = ClientIdentityImportRollbackToken(
            identityPersistentReference: reference,
            createdItems: [
                ClientIdentityKeychainItemReference(
                    itemClass: .privateKey,
                    persistentReference: Data([0xD1])
                )
            ]
        )
        let resolver = FakeResolver()
        resolver.referenceByIdentity[imported.identity] = reference
        resolver.rollbackTokenByIdentity[imported.identity] = token
        resolver.resolvedByReference[reference] = ResolvedClientIdentity(
            identity: imported.identity,
            metadata: imported.metadata,
            hasPrivateKey: true
        )
        let bindings = MemoryBindingStore()
        let store = ClientIdentityStore(
            importer: FakeImporter(result: .success(imported)),
            resolver: resolver,
            bindingStore: bindings
        )
        let result = try store.importAndBindTransaction(
            data: Data([0x01]),
            passphrase: "one-use-passphrase",
            profileID: profileID,
            scheme: "https",
            now: now
        )
        let sharedProfileID = UUID(uuidString: "E29D6811-FE00-45CF-A307-75EA12BB82B0")!
        try bindings.setPersistentReference(reference, for: sharedProfileID)
        try bindings.removePersistentReference(for: profileID)

        XCTAssertThrowsError(try store.rollbackImportedIdentity(try XCTUnwrap(result.rollbackToken))) { error in
            XCTAssertEqual(error as? ClientIdentityStoreError, .rollbackIdentityStillBound)
        }
        XCTAssertTrue(resolver.rollbackTokens.isEmpty)
        XCTAssertEqual(resolver.createdItems, Set(token.createdItems))
    }

    func testInvalidImportedCertificateIsRejectedBeforeKeychainPersistence() throws {
        let expiredMetadata = makeMetadata(
            notBefore: now.addingTimeInterval(-120),
            notAfter: now.addingTimeInterval(-60)
        )
        let temporaryImport = FakeTemporaryImportMaterial()
        let importer = FakeImporter(
            result: .success(
                ImportedClientIdentity(
                    identity: FakeIdentity(id: 1),
                    metadata: expiredMetadata,
                    hasPrivateKey: true,
                    cleanup: temporaryImport.cleanup
                )
            )
        )
        let resolver = FakeResolver()
        let bindings = MemoryBindingStore()
        let store = ClientIdentityStore(importer: importer, resolver: resolver, bindingStore: bindings)

        XCTAssertThrowsError(
            try store.importAndBind(
                data: Data([0x01]),
                passphrase: "one-use-passphrase",
                profileID: profileID,
                scheme: "https",
                now: now
            )
        ) { error in
            XCTAssertEqual(error as? ClientIdentityStoreError, .expired(expiredMetadata.notAfter))
        }
        XCTAssertEqual(resolver.persistentReferenceCount, 0)
        XCTAssertFalse(temporaryImport.isPresent)
        XCTAssertEqual(temporaryImport.cleanupCount, 1)
        XCTAssertNil(try bindings.persistentReference(for: profileID))
    }

    func testMissingPrivateKeyIsRejected() {
        let metadata = makeMetadata()
        let resolved = ResolvedClientIdentity(
            identity: FakeIdentity(id: 1),
            metadata: metadata,
            hasPrivateKey: false
        )

        XCTAssertThrowsError(
            try ClientIdentityValidator.validate(
                scheme: "https",
                expectedMetadata: metadata,
                resolvedIdentity: resolved,
                now: now
            )
        ) { error in
            XCTAssertEqual(error as? ClientIdentityStoreError, .missingPrivateKey)
        }
    }

    func testRemovingBindingDoesNotAskResolverToDeleteIdentity() throws {
        let bindings = MemoryBindingStore()
        try bindings.setPersistentReference(Data([0xA1]), for: profileID)
        let resolver = FakeResolver()
        let store = ClientIdentityStore(
            importer: FakeImporter(result: .success(importedIdentity())),
            resolver: resolver,
            bindingStore: bindings
        )

        try store.removeBinding(for: profileID)

        XCTAssertNil(try bindings.persistentReference(for: profileID))
        XCTAssertEqual(resolver.resolveCount, 0)
    }

#if DEBUG
    func testCredentialResolverRejectsPerformanceProofBeforeKeychainAccess() {
        let profile = ConnectionProfile(
            id: profileID,
            name: "Performance proof",
            scheme: "https",
            host: "transmission.example",
            port: 443,
            clientIdentityMetadata: makeMetadata()
        )
        let resolver = KeychainClientIdentityCredentialResolver(environment: [
            PerformancePasswordStoreIsolation.modeEnvironmentKey: "1"
        ])

        XCTAssertThrowsError(try resolver.credential(for: profile)) { error in
            XCTAssertEqual(error as? ClientIdentityStoreError, .performanceIsolation)
        }
    }
#endif

    private func makeMetadata(
        fingerprint: String = "AABBCC",
        notBefore: Date? = nil,
        notAfter: Date? = nil
    ) -> ClientIdentityMetadata {
        ClientIdentityMetadata(
            displayName: "Client Certificate",
            sha256Fingerprint: fingerprint,
            subject: "CN=client.example",
            issuer: "CN=Test Issuer",
            notBefore: notBefore ?? now.addingTimeInterval(-60),
            notAfter: notAfter ?? now.addingTimeInterval(60)
        )
    }

    private func importedIdentity(
        cleanup: @escaping () throws -> Void = {}
    ) -> ImportedClientIdentity<FakeIdentity> {
        ImportedClientIdentity(
            identity: FakeIdentity(id: 1),
            metadata: makeMetadata(),
            hasPrivateKey: true,
            cleanup: cleanup
        )
    }
}

private struct FakeIdentity: Hashable {
    let id: Int
}

private final class FakeTemporaryImportMaterial {
    private(set) var isPresent = true
    private(set) var cleanupCount = 0

    func cleanup() {
        cleanupCount += 1
        isPresent = false
    }
}

private enum ClientIdentityTransactionTestError: LocalizedError, Equatable {
    case bindingDenied
    case rollbackDenied

    var errorDescription: String? {
        String(describing: self)
    }
}

private final class FakeImporter: PKCS12IdentityImporting {
    private let result: Result<ImportedClientIdentity<FakeIdentity>, Error>
    private(set) var importCount = 0
    private(set) var receivedExpectedPassphrase = false

    init(result: Result<ImportedClientIdentity<FakeIdentity>, Error>) {
        self.result = result
    }

    func importIdentity(from data: Data, passphrase: String) throws -> ImportedClientIdentity<FakeIdentity> {
        importCount += 1
        receivedExpectedPassphrase = passphrase == "one-use-passphrase"
        return try result.get()
    }
}

private final class FakeResolver: SecIdentityPersistentReferenceResolving {
    var referenceByIdentity: [FakeIdentity: Data] = [:]
    var rollbackTokenByIdentity: [FakeIdentity: ClientIdentityImportRollbackToken] = [:]
    var resolvedByReference: [Data: ResolvedClientIdentity<FakeIdentity>] = [:]
    var preexistingItems: Set<ClientIdentityKeychainItemReference> = []
    private(set) var createdItems: Set<ClientIdentityKeychainItemReference> = []
    private(set) var rollbackTokens: [ClientIdentityImportRollbackToken] = []
    var rollbackError: Error?
    private(set) var resolveCount = 0
    private(set) var persistentReferenceCount = 0
    private(set) var requestedReferences: [Data] = []

    func persistIdentity(_ identity: FakeIdentity) throws -> PersistedClientIdentityReference {
        persistentReferenceCount += 1
        guard let reference = referenceByIdentity[identity] else {
            throw ClientIdentityStoreError.staleReference
        }
        let token = rollbackTokenByIdentity[identity]
            ?? ClientIdentityImportRollbackToken(createdItems: [])
        createdItems.formUnion(token.createdItems)
        return PersistedClientIdentityReference(
            persistentReference: reference,
            rollbackToken: token
        )
    }

    func rollbackPersistence(_ token: ClientIdentityImportRollbackToken) throws {
        rollbackTokens.append(token)
        if let rollbackError {
            throw rollbackError
        }
        createdItems.subtract(token.createdItems)
    }

    func resolveIdentity(persistentReference: Data) throws -> ResolvedClientIdentity<FakeIdentity>? {
        resolveCount += 1
        requestedReferences.append(persistentReference)
        return resolvedByReference[persistentReference]
    }
}

private final class MemoryBindingStore: ClientIdentityReferenceBindingStoring {
    private var references: [ConnectionProfile.ID: Data] = [:]
    var nextSetErrorAfterMutation: Error?

    func persistentReference(for profileID: ConnectionProfile.ID) throws -> Data? {
        references[profileID]
    }

    func allPersistentReferences() throws -> [Data] {
        Array(references.values)
    }

    func setPersistentReference(_ persistentReference: Data, for profileID: ConnectionProfile.ID) throws {
        references[profileID] = persistentReference
        if let error = nextSetErrorAfterMutation {
            nextSetErrorAfterMutation = nil
            throw error
        }
    }

    func removePersistentReference(for profileID: ConnectionProfile.ID) throws {
        references.removeValue(forKey: profileID)
    }
}
