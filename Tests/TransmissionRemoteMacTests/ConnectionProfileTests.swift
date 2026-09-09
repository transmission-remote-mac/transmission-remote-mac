// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import XCTest
@testable import TransmissionRemoteMac

final class ConnectionProfileTests: XCTestCase {
    func testDraftValidationNormalizesConnectionFields() throws {
        var draft = ConnectionProfileDraft()
        draft.name = "  NAS box  "
        draft.scheme = "HTTPS"
        draft.host = " transmission.local "
        draft.port = " 443 "
        draft.rpcPath = "rpc"
        draft.username = "user"
        draft.password = "pass"
        draft.pathMappings = [
            PathMappingDraft(remotePathPrefix: " /downloads/ ", localPathPrefix: " /Volumes/Downloads/ ")
        ]
        draft.connectOnLaunch = false
        draft.autoReconnect = true
        draft.requestTimeoutSeconds = " 45 "

        let profile = try draft.validatedProfile()

        XCTAssertEqual(profile.name, "NAS box")
        XCTAssertEqual(profile.scheme, "https")
        XCTAssertEqual(profile.host, "transmission.local")
        XCTAssertEqual(profile.port, 443)
        XCTAssertEqual(profile.rpcPath, "/rpc")
        XCTAssertEqual(profile.username, "user")
        XCTAssertEqual(profile.password, "pass")
        XCTAssertEqual(profile.pathMappings, [
            PathMapping(remotePathPrefix: "/downloads", localPathPrefix: "/Volumes/Downloads")
        ])
        XCTAssertFalse(profile.connectOnLaunch)
        XCTAssertTrue(profile.autoReconnect)
        XCTAssertEqual(profile.requestTimeoutSeconds, 45)
        XCTAssertEqual(profile.endpoint.absoluteString, "https://transmission.local:443/rpc")
    }

    func testBlankRPCPathDefaultsToTransmissionRPC() throws {
        var draft = ConnectionProfileDraft()
        draft.name = "Local"
        draft.host = "127.0.0.1"
        draft.rpcPath = "  "

        let profile = try draft.validatedProfile()

        XCTAssertEqual(profile.rpcPath, "/transmission/rpc")
        XCTAssertEqual(profile.endpoint.path, "/transmission/rpc")
    }

    func testAskPasswordAtConnectClearsStoredPassword() throws {
        var draft = ConnectionProfileDraft()
        draft.name = "Remote"
        draft.host = "example.test"
        draft.username = "user"
        draft.password = "do-not-persist"
        draft.askPasswordAtConnect = true

        let profile = try draft.validatedProfile()

        XCTAssertTrue(profile.askPasswordAtConnect)
        XCTAssertEqual(profile.password, "")
    }

    func testValidationRejectsInvalidFields() {
        XCTAssertThrowsError(try ConnectionProfile.validated(name: "", host: "127.0.0.1")) { error in
            XCTAssertEqual(error as? ConnectionProfileValidationError, .nameRequired)
        }

        XCTAssertThrowsError(try ConnectionProfile.validated(name: "Bad", scheme: "ftp", host: "127.0.0.1")) { error in
            XCTAssertEqual(error as? ConnectionProfileValidationError, .invalidScheme("ftp"))
        }

        XCTAssertThrowsError(try ConnectionProfile.validated(name: "Bad", host: "")) { error in
            XCTAssertEqual(error as? ConnectionProfileValidationError, .hostRequired)
        }

        XCTAssertThrowsError(try ConnectionProfile.validated(name: "Bad", host: "http://127.0.0.1")) { error in
            XCTAssertEqual(error as? ConnectionProfileValidationError, .invalidHost("http://127.0.0.1"))
        }

        XCTAssertThrowsError(try ConnectionProfile.validated(name: "Bad", host: "127.0.0.1", port: 0)) { error in
            XCTAssertEqual(error as? ConnectionProfileValidationError, .portOutOfRange(0))
        }

        var draft = ConnectionProfileDraft()
        draft.port = "nine"
        XCTAssertThrowsError(try draft.validatedProfile()) { error in
            XCTAssertEqual(error as? ConnectionProfileValidationError, .invalidPort("nine"))
        }

        draft.port = "9091"
        draft.requestTimeoutSeconds = "soon"
        XCTAssertThrowsError(try draft.validatedProfile()) { error in
            XCTAssertEqual(error as? ConnectionProfileValidationError, .invalidRequestTimeout("soon"))
        }

        draft.requestTimeoutSeconds = "0"
        XCTAssertThrowsError(try draft.validatedProfile()) { error in
            XCTAssertEqual(error as? ConnectionProfileValidationError, .requestTimeoutOutOfRange(0))
        }

        draft.requestTimeoutSeconds = "301"
        XCTAssertThrowsError(try draft.validatedProfile()) { error in
            XCTAssertEqual(error as? ConnectionProfileValidationError, .requestTimeoutOutOfRange(301))
        }
    }

    func testCollectionInitializerPreservesExplicitSelectedProfile() throws {
        let local = try ConnectionProfile.validated(
            id: UUID(),
            name: "Local",
            host: "127.0.0.1"
        )
        let remote = try ConnectionProfile.validated(
            id: UUID(),
            name: "Remote",
            scheme: "https",
            host: "transmission.example",
            port: 443
        )
        let collection = try ConnectionProfileCollection(
            profiles: [local, remote], selectedProfileID: remote.id
        )

        XCTAssertEqual(collection.profiles, [local, remote])
        XCTAssertEqual(collection.selectedProfileID, remote.id)
        XCTAssertEqual(collection.selectedProfile, remote)
    }

    func testCollectionRejectsDuplicateNames() throws {
        let first = try ConnectionProfile.validated(
            id: UUID(),
            name: "Server",
            host: "one.example"
        )
        let second = try ConnectionProfile.validated(
            id: UUID(),
            name: "server",
            host: "two.example"
        )

        XCTAssertThrowsError(try ConnectionProfileCollection(profiles: [first, second])) { error in
            XCTAssertEqual(error as? ConnectionProfileStoreError, .duplicateProfileName("server"))
        }
    }

    func testCollectionRejectsDuplicateIdentifiersFromInitializerAndDecoder() throws {
        let identifier = UUID()
        let first = try ConnectionProfile.validated(
            id: identifier,
            name: "One",
            host: "one.example"
        )
        let second = try ConnectionProfile.validated(
            id: identifier,
            name: "Two",
            host: "two.example"
        )

        XCTAssertThrowsError(try ConnectionProfileCollection(profiles: [first, second])) { error in
            XCTAssertEqual(
                error as? ConnectionProfileStoreError,
                .duplicateProfileIdentifier(identifier)
            )
        }

        let encoder = JSONEncoder()
        let object: [String: Any] = [
            "profiles": try [first, second].map {
                try JSONSerialization.jsonObject(with: encoder.encode($0))
            },
            "selectedProfileID": identifier.uuidString,
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(
            try JSONDecoder().decode(ConnectionProfileCollection.self, from: data)
        ) { error in
            XCTAssertEqual(
                error as? ConnectionProfileStoreError,
                .duplicateProfileIdentifier(identifier)
            )
        }
    }

    func testPathMappingDraftIdentitySurvivesFieldEditing() {
        var draft = PathMappingDraft(remotePathPrefix: "/remote", localPathPrefix: "/local")
        let identifier = draft.id

        draft.remotePathPrefix = "/changed"
        draft.localPathPrefix = "/Volumes/Changed"

        XCTAssertEqual(draft.id, identifier)
    }

    func testPathMappingRejectsRelativeLocalPathAndExpandsTilde() throws {
        XCTAssertThrowsError(
            try PathMapping.validated(remotePathPrefix: "/remote", localPathPrefix: "relative/path")
        ) { error in
            XCTAssertEqual(
                error as? ConnectionProfileValidationError,
                .pathMappingLocalPathMustBeAbsolute("relative/path")
            )
        }

        let expanded = try PathMapping.validated(
            remotePathPrefix: "/remote",
            localPathPrefix: "~/Downloads"
        )
        XCTAssertTrue(expanded.localPathPrefix.hasPrefix("/"))
        XCTAssertTrue(expanded.localPathPrefix.hasSuffix("/Downloads"))
    }

    func testStoreReportsNoPersistedProfilesWhenFileIsMissing() throws {
        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directoryURL.appendingPathComponent("profiles.json")
        let store = ConnectionProfileStore(fileURL: fileURL, passwordStore: MemoryPasswordStore())

        XCTAssertFalse(store.hasPersistedProfiles)

        _ = try store.load()

        XCTAssertFalse(store.hasPersistedProfiles)
    }

    func testStoreReportsPersistedProfilesAfterSuccessfulSave() throws {
        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directoryURL.appendingPathComponent("profiles.json")
        let store = ConnectionProfileStore(fileURL: fileURL, passwordStore: MemoryPasswordStore())
        let profile = try ConnectionProfile.validated(
            id: UUID(),
            name: "Remote",
            host: "transmission.example"
        )
        let collection = try ConnectionProfileCollection(profiles: [profile], selectedProfileID: profile.id)

        XCTAssertFalse(store.hasPersistedProfiles)

        try store.save(collection)

        XCTAssertTrue(store.hasPersistedProfiles)
    }

    func testStoreRoundTripsProfilesToDisk() throws {
        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directoryURL.appendingPathComponent("profiles.json")
        let passwordStore = MemoryPasswordStore()
        let store = ConnectionProfileStore(fileURL: fileURL, passwordStore: passwordStore)

        let profile = try ConnectionProfile.validated(
            id: UUID(),
            name: "Remote",
            scheme: "https",
            host: "transmission.example",
            port: 443,
            rpcPath: "custom/rpc",
            username: "user",
            password: "pass",
            pathMappings: [
                PathMapping(remotePathPrefix: "/downloads", localPathPrefix: "/Volumes/Downloads")
            ],
            connectOnLaunch: false,
            autoReconnect: true,
            requestTimeoutSeconds: 45
        )
        let collection = try ConnectionProfileCollection(profiles: [profile], selectedProfileID: profile.id)

        try store.save(collection)
        let loaded = try store.load()
        let savedJSON = try String(contentsOf: fileURL, encoding: .utf8)

        XCTAssertEqual(loaded, collection)
        XCTAssertEqual(try passwordStore.password(for: profile.id), "pass")
        XCTAssertEqual(loaded.selectedProfile.pathMappings, profile.pathMappings)
        XCTAssertFalse(loaded.selectedProfile.connectOnLaunch)
        XCTAssertEqual(loaded.selectedProfile.requestTimeoutSeconds, 45)
        XCTAssertTrue(savedJSON.contains("pathMappings"))
        XCTAssertTrue(savedJSON.contains("connectOnLaunch"))
        XCTAssertTrue(savedJSON.contains("requestTimeoutSeconds"))
        XCTAssertFalse(savedJSON.contains("pass"))
        XCTAssertFalse(savedJSON.contains("password"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testStoreDeletesPasswordWhenAskPasswordAtConnectIsEnabled() throws {
        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directoryURL.appendingPathComponent("profiles.json")
        let passwordStore = MemoryPasswordStore()
        let store = ConnectionProfileStore(fileURL: fileURL, passwordStore: passwordStore)
        let profile = try ConnectionProfile.validated(
            id: UUID(),
            name: "Remote",
            host: "transmission.example",
            username: "user",
            password: "pass"
        )
        var collection = try ConnectionProfileCollection(profiles: [profile], selectedProfileID: profile.id)
        try store.save(collection)

        var askProfile = profile
        askProfile.askPasswordAtConnect = true
        askProfile.password = ""
        collection = try ConnectionProfileCollection(profiles: [askProfile], selectedProfileID: profile.id)
        try store.save(collection)
        let loaded = try store.load()

        XCTAssertNil(try passwordStore.password(for: profile.id))
        XCTAssertEqual(loaded.selectedProfile.password, "")
    }

    func testStoreDoesNotRewriteUnchangedPasswordWhenSavingAfterLoad() throws {
        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directoryURL.appendingPathComponent("profiles.json")
        let passwordStore = MemoryPasswordStore()
        let store = ConnectionProfileStore(fileURL: fileURL, passwordStore: passwordStore)
        let profile = try ConnectionProfile.validated(
            id: UUID(),
            name: "Remote",
            host: "transmission.example",
            username: "user",
            password: "pass"
        )
        let collection = try ConnectionProfileCollection(profiles: [profile], selectedProfileID: profile.id)

        try store.save(collection)
        let loaded = try store.load()
        passwordStore.resetWrites()

        try store.save(loaded)

        XCTAssertEqual(passwordStore.writes, [])
        XCTAssertEqual(try passwordStore.password(for: profile.id), "pass")
    }

    func testStoreUpdatesChangedPasswordWhenSavingAfterLoad() throws {
        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directoryURL.appendingPathComponent("profiles.json")
        let passwordStore = MemoryPasswordStore()
        let store = ConnectionProfileStore(fileURL: fileURL, passwordStore: passwordStore)
        let profile = try ConnectionProfile.validated(
            id: UUID(),
            name: "Remote",
            host: "transmission.example",
            username: "user",
            password: "old-pass"
        )
        let collection = try ConnectionProfileCollection(profiles: [profile], selectedProfileID: profile.id)
        try store.save(collection)
        var loaded = try store.load()
        var changedProfile = loaded.selectedProfile
        changedProfile.password = "new-pass"
        loaded = try ConnectionProfileCollection(profiles: [changedProfile], selectedProfileID: profile.id)
        passwordStore.resetWrites()

        try store.save(loaded)

        XCTAssertEqual(passwordStore.writes, [.set(profile.id, "new-pass")])
        XCTAssertEqual(try passwordStore.password(for: profile.id), "new-pass")
    }

    func testStoreRemovesDeletedAndClearedPasswords() throws {
        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directoryURL.appendingPathComponent("profiles.json")
        let passwordStore = MemoryPasswordStore()
        let store = ConnectionProfileStore(fileURL: fileURL, passwordStore: passwordStore)
        let clearedProfile = try ConnectionProfile.validated(
            id: UUID(),
            name: "Keep",
            host: "keep.example",
            username: "user",
            password: "keep-pass"
        )
        let deletedProfile = try ConnectionProfile.validated(
            id: UUID(),
            name: "Delete",
            host: "delete.example",
            username: "user",
            password: "delete-pass"
        )
        let collection = try ConnectionProfileCollection(
            profiles: [clearedProfile, deletedProfile],
            selectedProfileID: clearedProfile.id
        )
        try store.save(collection)
        var loaded = try store.load()
        var cleared = loaded.selectedProfile
        cleared.password = ""
        loaded = try ConnectionProfileCollection(profiles: [cleared], selectedProfileID: cleared.id)
        passwordStore.resetWrites()

        try store.save(loaded)

        XCTAssertEqual(
            Set(passwordStore.writes),
            Set([.remove(clearedProfile.id), .remove(deletedProfile.id)])
        )
        XCTAssertEqual(passwordStore.writes.count, 2)
        XCTAssertNil(try passwordStore.password(for: clearedProfile.id))
        XCTAssertNil(try passwordStore.password(for: deletedProfile.id))
    }

    func testStoreKeepsPersistedProfileWhenDeletedPasswordCleanupFails() throws {
        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directoryURL.appendingPathComponent("profiles.json")
        let passwordStore = MemoryPasswordStore()
        let store = ConnectionProfileStore(fileURL: fileURL, passwordStore: passwordStore)
        let keptProfile = try ConnectionProfile.validated(
            id: UUID(),
            name: "Keep",
            host: "keep.example"
        )
        let deletedProfile = try ConnectionProfile.validated(
            id: UUID(),
            name: "Delete",
            host: "delete.example",
            username: "user",
            password: "delete-pass"
        )
        let collection = try ConnectionProfileCollection(
            profiles: [keptProfile, deletedProfile],
            selectedProfileID: keptProfile.id
        )
        try store.save(collection)
        var loaded = try store.load()
        loaded = try ConnectionProfileCollection(
            profiles: loaded.profiles.filter { $0.id != deletedProfile.id },
            selectedProfileID: loaded.selectedProfileID
        )
        let persistedBeforeFailure = try Data(contentsOf: fileURL)
        passwordStore.removeError = TestPasswordStoreError.cleanupDenied

        XCTAssertThrowsError(try store.save(loaded)) { error in
            XCTAssertEqual(error as? TestPasswordStoreError, .cleanupDenied)
        }

        XCTAssertEqual(try Data(contentsOf: fileURL), persistedBeforeFailure)
        XCTAssertEqual(try passwordStore.password(for: deletedProfile.id), "delete-pass")
        let persistedCollection = try JSONDecoder().decode(
            ConnectionProfileCollection.self,
            from: persistedBeforeFailure
        )
        XCTAssertTrue(persistedCollection.profiles.contains(where: { $0.id == deletedProfile.id }))
    }

    func testStoreRollsBackNewSecretsAndIdentityBindingWhenProfileWriteFails() throws {
        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fileURL = directoryURL.appendingPathComponent("profiles.json")
        let events = ConnectionProfileTransactionEventRecorder()
        let passwordStore = MemoryPasswordStore(eventRecorder: events)
        let proxyPasswordStore = MemoryConnectionProxyPasswordStore(eventRecorder: events)
        let identityStore = MemoryConnectionClientIdentityStore(
            metadata: makeClientIdentityMetadata(),
            eventRecorder: events
        )
        let fileWriter = ControllableConnectionProfileFileWriter(eventRecorder: events)
        fileWriter.error = TestConnectionProfileFileWriterError.writeDenied
        let store = ConnectionProfileStore(
            fileURL: fileURL,
            passwordStore: passwordStore,
            proxyPasswordStore: proxyPasswordStore,
            clientIdentityStore: identityStore,
            fileWriter: fileWriter
        )
        let editState = ClientIdentityEditState(
            pendingImport: PendingClientIdentityImport(
                sourceFileName: "client.p12",
                pkcs12Data: Data([0x01]),
                passphrase: "identity-passphrase"
            )
        )
        let profile = try ConnectionProfile.validated(
            name: "Transactional",
            scheme: "https",
            host: "transmission.example",
            port: 443,
            username: "rpc-user",
            password: "rpc-secret",
            proxySettings: ProxySettings(
                transport: .https,
                host: "proxy.example",
                port: 8443,
                authenticationEnabled: true,
                username: "proxy-user"
            ),
            proxyPassword: "proxy-secret",
            clientIdentityEditState: editState
        )

        XCTAssertThrowsError(try store.save(try ConnectionProfileCollection(profiles: [profile]))) { error in
            XCTAssertEqual(error as? TestConnectionProfileFileWriterError, .writeDenied)
        }

        XCTAssertNil(try passwordStore.password(for: profile.id))
        XCTAssertNil(try proxyPasswordStore.password(for: profile.id))
        XCTAssertNil(try identityStore.persistentReference(for: profile.id))
        XCTAssertTrue(identityStore.createdMaterial.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        let identityState = editState.snapshot
        XCTAssertNotNil(identityState.pendingImport)
        XCTAssertFalse(identityState.didApply)
        XCTAssertEqual(events.events, [
            .rpcSet(profile.id, "rpc-secret"),
            .proxySet(profile.id, "proxy-secret"),
            .identityImport(profile.id),
            .fileWrite,
            .identityRestore(profile.id, nil),
            .identityMaterialRollback(identityStore.rollbackTokens[0]),
            .proxyRemove(profile.id),
            .rpcRemove(profile.id),
        ])
    }

    func testProfileWriteFailureDoesNotDeletePreexistingClientIdentityMaterial() throws {
        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fileURL = directoryURL.appendingPathComponent("profiles.json")
        let identityStore = MemoryConnectionClientIdentityStore(metadata: makeClientIdentityMetadata())
        identityStore.importCreatesNewMaterial = false
        let sharedMaterial = ClientIdentityKeychainItemReference(
            itemClass: .privateKey,
            persistentReference: Data([0xD1])
        )
        identityStore.preexistingMaterial = [sharedMaterial]
        let fileWriter = ControllableConnectionProfileFileWriter()
        fileWriter.error = TestConnectionProfileFileWriterError.writeDenied
        let store = ConnectionProfileStore(
            fileURL: fileURL,
            passwordStore: MemoryPasswordStore(),
            proxyPasswordStore: MemoryConnectionProxyPasswordStore(),
            clientIdentityStore: identityStore,
            fileWriter: fileWriter
        )
        let editState = ClientIdentityEditState(
            pendingImport: PendingClientIdentityImport(
                sourceFileName: "shared.p12",
                pkcs12Data: Data([0x01]),
                passphrase: "identity-passphrase"
            )
        )
        let profile = try ConnectionProfile.validated(
            name: "Shared identity",
            scheme: "https",
            host: "transmission.example",
            clientIdentityEditState: editState
        )

        XCTAssertThrowsError(try store.save(try ConnectionProfileCollection(profiles: [profile]))) { error in
            XCTAssertEqual(error as? TestConnectionProfileFileWriterError, .writeDenied)
        }

        XCTAssertEqual(identityStore.preexistingMaterial, Set([sharedMaterial]))
        XCTAssertTrue(identityStore.rollbackTokens.isEmpty)
        XCTAssertNil(try identityStore.persistentReference(for: profile.id))
    }

    func testProfileWriteRollbackFailureReportsOriginalAndCleanupErrors() throws {
        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fileURL = directoryURL.appendingPathComponent("profiles.json")
        let identityStore = MemoryConnectionClientIdentityStore(metadata: makeClientIdentityMetadata())
        identityStore.rollbackError = TestClientIdentityStoreError.rollbackDenied
        let fileWriter = ControllableConnectionProfileFileWriter()
        fileWriter.error = TestConnectionProfileFileWriterError.writeDenied
        let store = ConnectionProfileStore(
            fileURL: fileURL,
            passwordStore: MemoryPasswordStore(),
            proxyPasswordStore: MemoryConnectionProxyPasswordStore(),
            clientIdentityStore: identityStore,
            fileWriter: fileWriter
        )
        let profile = try ConnectionProfile.validated(
            name: "Rollback failure",
            scheme: "https",
            host: "transmission.example",
            clientIdentityEditState: ClientIdentityEditState(
                pendingImport: PendingClientIdentityImport(
                    sourceFileName: "client.p12",
                    pkcs12Data: Data([0x01]),
                    passphrase: "identity-passphrase"
                )
            )
        )

        XCTAssertThrowsError(try store.save(try ConnectionProfileCollection(profiles: [profile]))) { error in
            guard let storeError = error as? ConnectionProfileStoreError,
                  case .transactionRollbackFailed(let original, let rollback) = storeError else {
                return XCTFail("Expected connection profile transaction rollback failure")
            }
            XCTAssertTrue(original.contains("writeDenied"))
            XCTAssertTrue(rollback.contains("rollbackDenied"))
        }

        XCTAssertNil(try identityStore.persistentReference(for: profile.id))
        XCTAssertFalse(identityStore.createdMaterial.isEmpty)
        XCTAssertEqual(identityStore.rollbackTokens.count, 1)
    }

    func testStoreRestoresDeletedSecretsAndBindingWhenProfileWriteFails() throws {
        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fileURL = directoryURL.appendingPathComponent("profiles.json")
        let events = ConnectionProfileTransactionEventRecorder()
        let passwordStore = MemoryPasswordStore(eventRecorder: events)
        let proxyPasswordStore = MemoryConnectionProxyPasswordStore(eventRecorder: events)
        let identityStore = MemoryConnectionClientIdentityStore(
            metadata: makeClientIdentityMetadata(),
            eventRecorder: events
        )
        let fileWriter = ControllableConnectionProfileFileWriter(eventRecorder: events)
        let store = ConnectionProfileStore(
            fileURL: fileURL,
            passwordStore: passwordStore,
            proxyPasswordStore: proxyPasswordStore,
            clientIdentityStore: identityStore,
            fileWriter: fileWriter
        )
        let previousReference = Data([0xA1, 0xB2])
        let profile = try ConnectionProfile.validated(
            name: "Transactional",
            scheme: "https",
            host: "transmission.example",
            port: 443,
            username: "rpc-user",
            password: "rpc-secret",
            proxySettings: ProxySettings(
                transport: .socks5,
                host: "proxy.example",
                port: 1080,
                authenticationEnabled: true,
                username: "proxy-user"
            ),
            proxyPassword: "proxy-secret",
            clientIdentityMetadata: makeClientIdentityMetadata()
        )
        identityStore.seedReference(previousReference, for: profile.id)
        try store.save(try ConnectionProfileCollection(profiles: [profile]))
        var collection = try store.load()
        let persistedBeforeFailure = try Data(contentsOf: fileURL)
        events.reset()
        fileWriter.error = TestConnectionProfileFileWriterError.writeDenied
        var changedProfile = collection.selectedProfile
        changedProfile.askPasswordAtConnect = true
        changedProfile.password = ""
        changedProfile.proxySettings = .direct
        changedProfile.proxyPassword = ""
        let editState = ClientIdentityEditState(removeOnApply: true)
        changedProfile.clientIdentityEditState = editState
        collection = try ConnectionProfileCollection(profiles: [changedProfile], selectedProfileID: profile.id)

        XCTAssertThrowsError(try store.save(collection)) { error in
            XCTAssertEqual(error as? TestConnectionProfileFileWriterError, .writeDenied)
        }

        XCTAssertEqual(try passwordStore.password(for: profile.id), "rpc-secret")
        XCTAssertEqual(try proxyPasswordStore.password(for: profile.id), "proxy-secret")
        XCTAssertEqual(try identityStore.persistentReference(for: profile.id), previousReference)
        XCTAssertEqual(try Data(contentsOf: fileURL), persistedBeforeFailure)
        let identityState = editState.snapshot
        XCTAssertTrue(identityState.removeOnApply)
        XCTAssertFalse(identityState.didApply)
        XCTAssertEqual(events.events, [
            .rpcRemove(profile.id),
            .proxyRemove(profile.id),
            .identityRemove(profile.id),
            .fileWrite,
            .identityRestore(profile.id, previousReference),
            .proxySet(profile.id, "proxy-secret"),
            .rpcSet(profile.id, "rpc-secret"),
        ])
    }

    func testStoreMigratesLegacyJSONPasswordIntoPasswordStore() throws {
        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directoryURL.appendingPathComponent("profiles.json")
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let profileID = UUID()
        let selectedID = profileID.uuidString
        try """
        {
          "profiles" : [
            {
              "autoReconnect" : false,
              "askPasswordAtConnect" : false,
              "host" : "transmission.example",
              "id" : "\(selectedID)",
              "name" : "Remote",
              "password" : "legacy-pass",
              "port" : 9091,
              "rpcPath" : "/transmission/rpc",
              "scheme" : "http",
              "username" : "user"
            }
          ],
          "selectedProfileID" : "\(selectedID)"
        }
        """.write(to: fileURL, atomically: true, encoding: .utf8)
        let passwordStore = MemoryPasswordStore()
        let store = ConnectionProfileStore(fileURL: fileURL, passwordStore: passwordStore)

        let loaded = try store.load()
        let migratedJSON = try String(contentsOf: fileURL, encoding: .utf8)

        XCTAssertEqual(loaded.selectedProfile.password, "legacy-pass")
        XCTAssertTrue(loaded.selectedProfile.connectOnLaunch)
        XCTAssertEqual(loaded.selectedProfile.requestTimeoutSeconds, 30)
        XCTAssertEqual(try passwordStore.password(for: profileID), "legacy-pass")
        XCTAssertFalse(migratedJSON.contains("legacy-pass"))
        XCTAssertFalse(migratedJSON.contains("password"))
        XCTAssertTrue(migratedJSON.contains("\"connectOnLaunch\" : true"))
        XCTAssertTrue(migratedJSON.contains("\"requestTimeoutSeconds\" : 30"))
    }

    func testStoreMigratesMissingConnectionPreferencesToDefaults() throws {
        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directoryURL.appendingPathComponent("profiles.json")
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let profileID = UUID()
        try """
        {
          "profiles" : [
            {
              "autoReconnect" : false,
              "askPasswordAtConnect" : false,
              "host" : "transmission.example",
              "id" : "\(profileID.uuidString)",
              "name" : "Remote",
              "port" : 9091,
              "rpcPath" : "/transmission/rpc",
              "scheme" : "http",
              "username" : ""
            }
          ],
          "selectedProfileID" : "\(profileID.uuidString)"
        }
        """.write(to: fileURL, atomically: true, encoding: .utf8)
        let store = ConnectionProfileStore(fileURL: fileURL, passwordStore: MemoryPasswordStore())

        let loaded = try store.load()
        let migratedJSON = try String(contentsOf: fileURL, encoding: .utf8)

        XCTAssertTrue(loaded.selectedProfile.connectOnLaunch)
        XCTAssertEqual(loaded.selectedProfile.requestTimeoutSeconds, 30)
        XCTAssertTrue(migratedJSON.contains("\"connectOnLaunch\" : true"))
        XCTAssertTrue(migratedJSON.contains("\"requestTimeoutSeconds\" : 30"))
    }

    func testLegacyProfileDecodeDefaultsProxyTransportToDirect() throws {
        let profileID = UUID()
        let data = try XCTUnwrap(
            """
            {
              "id" : "\(profileID.uuidString)",
              "name" : "Remote",
              "scheme" : "https",
              "host" : "transmission.example",
              "port" : 443,
              "rpcPath" : "/transmission/rpc",
              "username" : "user"
            }
            """.data(using: .utf8)
        )

        let profile = try JSONDecoder().decode(ConnectionProfile.self, from: data)

        XCTAssertEqual(profile.proxySettings, .direct)
        XCTAssertEqual(try profile.normalized().proxySettings, .direct)
        XCTAssertEqual(profile.proxyPassword, "")
    }

    func testStoreRoundTripsProxyPasswordOnlyThroughDedicatedSecretStore() throws {
        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fileURL = directoryURL.appendingPathComponent("profiles.json")
        let proxyPasswordStore = MemoryConnectionProxyPasswordStore()
        let store = ConnectionProfileStore(
            fileURL: fileURL,
            passwordStore: MemoryPasswordStore(),
            proxyPasswordStore: proxyPasswordStore
        )
        let profileID = UUID()
        let profile = try ConnectionProfile.validated(
            id: profileID,
            name: "Proxied",
            host: "transmission.example",
            proxySettings: ProxySettings(
                transport: .https,
                host: "proxy.example",
                port: 8443,
                authenticationEnabled: true,
                username: "proxy-user"
            ),
            proxyPassword: "proxy-secret"
        )
        let collection = try ConnectionProfileCollection(profiles: [profile])

        try store.save(collection)
        let loaded = try store.load()
        let json = try String(contentsOf: fileURL, encoding: .utf8)

        XCTAssertEqual(loaded.selectedProfile.id, profileID)
        XCTAssertEqual(loaded.selectedProfile.proxyPassword, "proxy-secret")
        XCTAssertEqual(try proxyPasswordStore.password(for: profileID), "proxy-secret")
        XCTAssertFalse(json.contains("proxy-secret"))
        XCTAssertFalse(json.localizedCaseInsensitiveContains("proxyPassword"))
    }

    func testStoreDoesNotRewriteUnchangedProxyPasswordAfterApplyStyleSave() throws {
        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fileURL = directoryURL.appendingPathComponent("profiles.json")
        let proxyPasswordStore = MemoryConnectionProxyPasswordStore()
        let store = ConnectionProfileStore(
            fileURL: fileURL,
            passwordStore: MemoryPasswordStore(),
            proxyPasswordStore: proxyPasswordStore
        )
        let profile = try ConnectionProfile.validated(
            name: "Proxied",
            host: "transmission.example",
            proxySettings: ProxySettings(
                transport: .http,
                host: "proxy.example",
                port: 3128,
                authenticationEnabled: true,
                username: "proxy-user"
            ),
            proxyPassword: "unchanged-secret"
        )
        try store.save(try ConnectionProfileCollection(profiles: [profile]))
        var loaded = try store.load()
        var renamed = loaded.selectedProfile
        renamed.name = "Renamed"
        loaded = try ConnectionProfileCollection(profiles: [renamed], selectedProfileID: profile.id)
        proxyPasswordStore.resetWrites()

        try store.save(loaded)

        XCTAssertEqual(proxyPasswordStore.writes, [])
        XCTAssertEqual(try proxyPasswordStore.password(for: profile.id), "unchanged-secret")
    }

    func testStoreRemovesProxyPasswordWhenProxyAuthenticationIsDisabled() throws {
        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fileURL = directoryURL.appendingPathComponent("profiles.json")
        let proxyPasswordStore = MemoryConnectionProxyPasswordStore()
        let store = ConnectionProfileStore(
            fileURL: fileURL,
            passwordStore: MemoryPasswordStore(),
            proxyPasswordStore: proxyPasswordStore
        )
        let profile = try ConnectionProfile.validated(
            name: "Proxied",
            host: "transmission.example",
            proxySettings: ProxySettings(
                transport: .socks5,
                host: "proxy.example",
                port: 1080,
                authenticationEnabled: true,
                username: "proxy-user"
            ),
            proxyPassword: "remove-me"
        )
        try store.save(try ConnectionProfileCollection(profiles: [profile]))
        var loaded = try store.load()
        var direct = loaded.selectedProfile
        direct.proxySettings = .direct
        direct.proxyPassword = ""
        loaded = try ConnectionProfileCollection(profiles: [direct], selectedProfileID: profile.id)
        proxyPasswordStore.resetWrites()

        try store.save(loaded)

        XCTAssertEqual(proxyPasswordStore.writes, [.remove(profile.id)])
        XCTAssertNil(try proxyPasswordStore.password(for: profile.id))
    }

    func testLegacyProfileDecodeDefaultsToNoClientIdentity() throws {
        let profileID = UUID()
        let data = try XCTUnwrap(
            """
            {
              "id" : "\(profileID.uuidString)",
              "name" : "Remote",
              "scheme" : "https",
              "host" : "transmission.example",
              "port" : 443,
              "rpcPath" : "/transmission/rpc",
              "username" : ""
            }
            """.data(using: .utf8)
        )

        let profile = try JSONDecoder().decode(ConnectionProfile.self, from: data)

        XCTAssertNil(profile.clientIdentityMetadata)
        XCTAssertNil(profile.clientIdentityEditState)
        XCTAssertFalse(profile.hasClientIdentity)
    }

    func testHTTPProfileCannotEnableClientIdentity() {
        let metadata = makeClientIdentityMetadata()
        XCTAssertThrowsError(
            try ConnectionProfile.validated(
                name: "Invalid Mutual TLS",
                scheme: "http",
                host: "transmission.example",
                clientIdentityMetadata: metadata
            )
        ) { error in
            XCTAssertEqual(error as? ConnectionProfileValidationError, .clientIdentityRequiresHTTPS)
        }

        let editState = ClientIdentityEditState(
            pendingImport: PendingClientIdentityImport(
                sourceFileName: "client.p12",
                pkcs12Data: Data([0x01])
            )
        )
        XCTAssertThrowsError(
            try ConnectionProfile.validated(
                name: "Invalid Pending Mutual TLS",
                scheme: "http",
                host: "transmission.example",
                clientIdentityEditState: editState
            )
        ) { error in
            XCTAssertEqual(error as? ConnectionProfileValidationError, .clientIdentityRequiresHTTPS)
        }
    }

    func testPendingClientIdentityChangesRequireConnectionRestartBeforePersistence() {
        let existingMetadata = makeClientIdentityMetadata()
        let current = ConnectionProfile(
            name: "Remote",
            scheme: "https",
            host: "transmission.example",
            clientIdentityMetadata: existingMetadata
        )
        var replacement = current
        replacement.clientIdentityEditState = ClientIdentityEditState(
            pendingImport: PendingClientIdentityImport(
                sourceFileName: "replacement.p12",
                pkcs12Data: Data([0x01])
            )
        )
        var removal = current
        removal.clientIdentityEditState = ClientIdentityEditState(removeOnApply: true)

        XCTAssertTrue(current.requiresConnectionRestart(comparedTo: replacement))
        XCTAssertTrue(current.requiresConnectionRestart(comparedTo: removal))
    }

    func testChangingDraftIdentifierDoesNotCopyAnotherProfilesIdentityBinding() {
        let profile = ConnectionProfile(
            name: "Original",
            scheme: "https",
            host: "transmission.example",
            clientIdentityMetadata: makeClientIdentityMetadata()
        )
        var draft = ConnectionProfileDraft(profile: profile)

        draft.id = UUID()

        XCTAssertNil(draft.clientIdentityMetadata)
        XCTAssertNil(draft.pendingClientIdentityImport)
        XCTAssertFalse(draft.removeClientIdentityOnApply)
    }

    func testDraftResetDiscardsUnappliedPKCS12DataAndPassphrase() {
        let profile = ConnectionProfile(
            name: "Remote",
            scheme: "https",
            host: "transmission.example"
        )
        var draft = ConnectionProfileDraft(profile: profile)
        draft.stageClientIdentityImport(
            fileName: "client.p12",
            data: Data("PKCS12-PRIVATE-BYTES".utf8)
        )
        draft.pendingClientIdentityImport?.passphrase = "ONE-USE-PASSPHRASE"

        draft.reset(to: profile)

        XCTAssertNil(draft.pendingClientIdentityImport)
        XCTAssertNil(draft.clientIdentityMetadata)
    }

    func testStoreImportsClientIdentityOnApplyAndPersistsOnlyPublicMetadata() throws {
        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fileURL = directoryURL.appendingPathComponent("profiles.json")
        let identityStore = MemoryConnectionClientIdentityStore(metadata: makeClientIdentityMetadata())
        let store = ConnectionProfileStore(
            fileURL: fileURL,
            passwordStore: MemoryPasswordStore(),
            proxyPasswordStore: MemoryConnectionProxyPasswordStore(),
            clientIdentityStore: identityStore
        )
        let editState = ClientIdentityEditState(
            pendingImport: PendingClientIdentityImport(
                sourceFileName: "client.p12",
                pkcs12Data: Data("PKCS12-PRIVATE-BYTES".utf8),
                passphrase: "ONE-USE-PASSPHRASE"
            )
        )
        let profile = try ConnectionProfile.validated(
            name: "Mutual TLS",
            scheme: "https",
            host: "transmission.example",
            port: 443,
            clientIdentityEditState: editState
        )

        try store.save(try ConnectionProfileCollection(profiles: [profile]))
        let loaded = try store.load()
        let json = try String(contentsOf: fileURL, encoding: .utf8)

        XCTAssertEqual(loaded.selectedProfile.clientIdentityMetadata, makeClientIdentityMetadata())
        XCTAssertEqual(profile.effectiveClientIdentityMetadata, makeClientIdentityMetadata())
        XCTAssertNil(editState.snapshot.pendingImport)
        XCTAssertTrue(profile.hasClientIdentity)
        XCTAssertEqual(identityStore.importedProfileIDs, [profile.id])
        XCTAssertFalse(identityStore.createdMaterial.isEmpty)
        XCTAssertTrue(identityStore.rollbackTokens.isEmpty)
        XCTAssertFalse(json.contains("PKCS12-PRIVATE-BYTES"))
        XCTAssertFalse(json.contains("ONE-USE-PASSPHRASE"))
        XCTAssertFalse(json.localizedCaseInsensitiveContains("persistentReference"))
        XCTAssertFalse(json.localizedCaseInsensitiveContains("clientIdentityEditState"))
    }

    func testFailedClientIdentityImportLeavesDraftAndPersistedProfilesUntouched() throws {
        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fileURL = directoryURL.appendingPathComponent("profiles.json")
        let identityStore = MemoryConnectionClientIdentityStore(metadata: makeClientIdentityMetadata())
        identityStore.importError = ClientIdentityStoreError.wrongPassword
        let store = ConnectionProfileStore(
            fileURL: fileURL,
            passwordStore: MemoryPasswordStore(),
            proxyPasswordStore: MemoryConnectionProxyPasswordStore(),
            clientIdentityStore: identityStore
        )
        let editState = ClientIdentityEditState(
            pendingImport: PendingClientIdentityImport(
                sourceFileName: "client.p12",
                pkcs12Data: Data([0x01]),
                passphrase: "wrong"
            )
        )
        let profile = try ConnectionProfile.validated(
            name: "Mutual TLS",
            scheme: "https",
            host: "transmission.example",
            clientIdentityEditState: editState
        )

        XCTAssertThrowsError(try store.save(try ConnectionProfileCollection(profiles: [profile]))) { error in
            XCTAssertEqual(error as? ClientIdentityStoreError, .wrongPassword)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        let identityState = editState.snapshot
        XCTAssertNotNil(identityState.pendingImport)
        XCTAssertFalse(identityState.didApply)
    }

    func testStoreRemovesClientIdentityBindingOnlyWhenRemovalIsApplied() throws {
        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fileURL = directoryURL.appendingPathComponent("profiles.json")
        let identityStore = MemoryConnectionClientIdentityStore(metadata: makeClientIdentityMetadata())
        let store = ConnectionProfileStore(
            fileURL: fileURL,
            passwordStore: MemoryPasswordStore(),
            proxyPasswordStore: MemoryConnectionProxyPasswordStore(),
            clientIdentityStore: identityStore
        )
        let profile = try ConnectionProfile.validated(
            name: "Mutual TLS",
            scheme: "https",
            host: "transmission.example",
            clientIdentityMetadata: makeClientIdentityMetadata()
        )
        identityStore.seedReference(Data([0xA1]), for: profile.id)
        try store.save(try ConnectionProfileCollection(profiles: [profile]))
        var draft = ConnectionProfileDraft(profile: profile)
        draft.removeClientIdentity()
        let removedProfile = try draft.validatedProfile()

        try store.save(try ConnectionProfileCollection(profiles: [removedProfile]))
        let loaded = try store.load()

        XCTAssertNil(try identityStore.persistentReference(for: profile.id))
        XCTAssertNil(loaded.selectedProfile.clientIdentityMetadata)
        XCTAssertFalse(removedProfile.hasClientIdentity)
    }

    func testProfileDeletionFailureKeepsProfileAndClientIdentityBinding() throws {
        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fileURL = directoryURL.appendingPathComponent("profiles.json")
        let identityStore = MemoryConnectionClientIdentityStore(metadata: makeClientIdentityMetadata())
        let store = ConnectionProfileStore(
            fileURL: fileURL,
            passwordStore: MemoryPasswordStore(),
            proxyPasswordStore: MemoryConnectionProxyPasswordStore(),
            clientIdentityStore: identityStore
        )
        let keptProfile = try ConnectionProfile.validated(name: "Keep", host: "keep.example")
        let deletedProfile = try ConnectionProfile.validated(
            name: "Delete",
            scheme: "https",
            host: "delete.example",
            clientIdentityMetadata: makeClientIdentityMetadata()
        )
        identityStore.seedReference(Data([0xA1]), for: deletedProfile.id)
        var collection = try ConnectionProfileCollection(profiles: [keptProfile, deletedProfile])
        try store.save(collection)
        collection = try ConnectionProfileCollection(
            profiles: collection.profiles.filter { $0.id != deletedProfile.id },
            selectedProfileID: collection.selectedProfileID
        )
        let persistedBeforeFailure = try Data(contentsOf: fileURL)
        identityStore.removeError = TestClientIdentityStoreError.cleanupDenied

        XCTAssertThrowsError(try store.save(collection)) { error in
            XCTAssertEqual(error as? TestClientIdentityStoreError, .cleanupDenied)
        }
        XCTAssertEqual(try Data(contentsOf: fileURL), persistedBeforeFailure)
        XCTAssertEqual(try identityStore.persistentReference(for: deletedProfile.id), Data([0xA1]))
    }

    private func makeClientIdentityMetadata() -> ClientIdentityMetadata {
        ClientIdentityMetadata(
            displayName: "RPC Client",
            sha256Fingerprint: "AABBCC",
            subject: "CN=rpc-client",
            issuer: "CN=test-ca",
            notBefore: Date(timeIntervalSince1970: 1_700_000_000),
            notAfter: Date(timeIntervalSince1970: 2_000_000_000)
        )
    }
}

private enum PasswordStoreWrite: Hashable {
    case set(ConnectionProfile.ID, String)
    case remove(ConnectionProfile.ID)
}

private enum TestPasswordStoreError: Error, Equatable {
    case cleanupDenied
}

private enum ConnectionProfileTransactionEvent: Equatable {
    case rpcSet(ConnectionProfile.ID, String)
    case rpcRemove(ConnectionProfile.ID)
    case proxySet(ConnectionProfile.ID, String)
    case proxyRemove(ConnectionProfile.ID)
    case identityImport(ConnectionProfile.ID)
    case identityRemove(ConnectionProfile.ID)
    case identityRestore(ConnectionProfile.ID, Data?)
    case identityMaterialRollback(ClientIdentityImportRollbackToken)
    case fileWrite
}

private final class ConnectionProfileTransactionEventRecorder {
    private(set) var events: [ConnectionProfileTransactionEvent] = []

    func record(_ event: ConnectionProfileTransactionEvent) {
        events.append(event)
    }

    func reset() {
        events.removeAll()
    }
}

private enum TestConnectionProfileFileWriterError: LocalizedError, Equatable {
    case writeDenied

    var errorDescription: String? {
        String(describing: self)
    }
}

private final class ControllableConnectionProfileFileWriter: ConnectionProfileFileWriting {
    private let eventRecorder: ConnectionProfileTransactionEventRecorder?
    var error: Error?

    init(eventRecorder: ConnectionProfileTransactionEventRecorder? = nil) {
        self.eventRecorder = eventRecorder
    }

    func write(_ data: Data, to fileURL: URL) throws {
        eventRecorder?.record(.fileWrite)
        if let error {
            throw error
        }
        try data.write(to: fileURL, options: .atomic)
    }
}

private final class MemoryPasswordStore: ConnectionPasswordStoring {
    private var passwords: [ConnectionProfile.ID: String] = [:]
    private let eventRecorder: ConnectionProfileTransactionEventRecorder?
    private(set) var writes: [PasswordStoreWrite] = []
    var removeError: Error?

    init(eventRecorder: ConnectionProfileTransactionEventRecorder? = nil) {
        self.eventRecorder = eventRecorder
    }

    func password(for profileID: ConnectionProfile.ID) throws -> String? {
        passwords[profileID]
    }

    func setPassword(_ password: String, for profileID: ConnectionProfile.ID) throws {
        passwords[profileID] = password
        writes.append(.set(profileID, password))
        eventRecorder?.record(.rpcSet(profileID, password))
    }

    func removePassword(for profileID: ConnectionProfile.ID) throws {
        if let removeError {
            throw removeError
        }
        passwords.removeValue(forKey: profileID)
        writes.append(.remove(profileID))
        eventRecorder?.record(.rpcRemove(profileID))
    }

    func resetWrites() {
        writes.removeAll()
    }
}

private enum ProxyPasswordStoreWrite: Equatable {
    case set(ConnectionProfile.ID, String)
    case remove(ConnectionProfile.ID)
}

private final class MemoryConnectionProxyPasswordStore: ConnectionProxyPasswordStoring {
    private var passwords: [ConnectionProfile.ID: String] = [:]
    private let eventRecorder: ConnectionProfileTransactionEventRecorder?
    private(set) var writes: [ProxyPasswordStoreWrite] = []

    init(eventRecorder: ConnectionProfileTransactionEventRecorder? = nil) {
        self.eventRecorder = eventRecorder
    }

    func password(for profileID: ConnectionProfile.ID) throws -> String? {
        passwords[profileID]
    }

    func setPassword(_ password: String, for profileID: ConnectionProfile.ID) throws {
        passwords[profileID] = password
        writes.append(.set(profileID, password))
        eventRecorder?.record(.proxySet(profileID, password))
    }

    func removePassword(for profileID: ConnectionProfile.ID) throws {
        passwords.removeValue(forKey: profileID)
        writes.append(.remove(profileID))
        eventRecorder?.record(.proxyRemove(profileID))
    }

    func resetWrites() {
        writes.removeAll()
    }
}

private enum TestClientIdentityStoreError: LocalizedError, Equatable {
    case cleanupDenied
    case rollbackDenied

    var errorDescription: String? {
        String(describing: self)
    }
}

private final class MemoryConnectionClientIdentityStore: ConnectionClientIdentityStoring {
    private let metadata: ClientIdentityMetadata
    private let eventRecorder: ConnectionProfileTransactionEventRecorder?
    private var references: [ConnectionProfile.ID: Data] = [:]
    private(set) var importedProfileIDs: [ConnectionProfile.ID] = []
    var importCreatesNewMaterial = true
    var preexistingMaterial: Set<ClientIdentityKeychainItemReference> = []
    private(set) var createdMaterial: Set<ClientIdentityKeychainItemReference> = []
    private(set) var rollbackTokens: [ClientIdentityImportRollbackToken] = []
    var importError: Error?
    var removeError: Error?
    var rollbackError: Error?

    init(
        metadata: ClientIdentityMetadata,
        eventRecorder: ConnectionProfileTransactionEventRecorder? = nil
    ) {
        self.metadata = metadata
        self.eventRecorder = eventRecorder
    }

    func importAndBind(
        data: Data,
        passphrase: String,
        profileID: ConnectionProfile.ID,
        scheme: String,
        now: Date
    ) throws -> ClientIdentityMetadata {
        try performImportAndBind(profileID: profileID)
    }

    func importAndBindTransaction(
        data: Data,
        passphrase: String,
        profileID: ConnectionProfile.ID,
        scheme: String,
        now: Date
    ) throws -> ClientIdentityImportResult {
        let metadata = try performImportAndBind(profileID: profileID)
        guard importCreatesNewMaterial else {
            return ClientIdentityImportResult(metadata: metadata, rollbackToken: nil)
        }
        let token = ClientIdentityImportRollbackToken(
            createdItems: [
                ClientIdentityKeychainItemReference(
                    itemClass: .certificate,
                    persistentReference: Data(profileID.uuidString.utf8)
                )
            ]
        )
        createdMaterial.formUnion(token.createdItems)
        return ClientIdentityImportResult(metadata: metadata, rollbackToken: token)
    }

    func rollbackImportedIdentity(_ token: ClientIdentityImportRollbackToken) throws {
        rollbackTokens.append(token)
        eventRecorder?.record(.identityMaterialRollback(token))
        if let rollbackError {
            throw rollbackError
        }
        createdMaterial.subtract(token.createdItems)
    }

    private func performImportAndBind(profileID: ConnectionProfile.ID) throws -> ClientIdentityMetadata {
        if let importError {
            throw importError
        }
        importedProfileIDs.append(profileID)
        references[profileID] = Data([0xB1])
        eventRecorder?.record(.identityImport(profileID))
        return metadata
    }

    func persistentReference(for profileID: ConnectionProfile.ID) throws -> Data? {
        references[profileID]
    }

    func restorePersistentReference(
        _ persistentReference: Data?,
        for profileID: ConnectionProfile.ID
    ) throws {
        references[profileID] = persistentReference
        eventRecorder?.record(.identityRestore(profileID, persistentReference))
    }

    func removeBinding(for profileID: ConnectionProfile.ID) throws {
        if let removeError {
            throw removeError
        }
        references.removeValue(forKey: profileID)
        eventRecorder?.record(.identityRemove(profileID))
    }

    func seedReference(_ reference: Data, for profileID: ConnectionProfile.ID) {
        references[profileID] = reference
    }
}
