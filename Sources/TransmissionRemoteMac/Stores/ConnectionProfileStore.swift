// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation

struct ConnectionProfileCollection: Codable, Equatable {
    private enum CodingKeys: String, CodingKey {
        case profiles
        case selectedProfileID
    }

    var profiles: [ConnectionProfile]
    var selectedProfileID: ConnectionProfile.ID

    init(profiles: [ConnectionProfile] = [.localDefault], selectedProfileID: ConnectionProfile.ID? = nil) throws {
        let normalizedProfiles = try profiles.map { try $0.normalized() }
        guard !normalizedProfiles.isEmpty else {
            throw ConnectionProfileStoreError.emptyProfileList
        }

        try Self.validateUniqueIdentifiers(normalizedProfiles)
        try Self.validateUniqueNames(normalizedProfiles)

        self.profiles = normalizedProfiles
        if let selectedProfileID, normalizedProfiles.contains(where: { $0.id == selectedProfileID }) {
            self.selectedProfileID = selectedProfileID
        } else {
            self.selectedProfileID = normalizedProfiles[0].id
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            profiles: container.decode([ConnectionProfile].self, forKey: .profiles),
            selectedProfileID: container.decodeIfPresent(
                ConnectionProfile.ID.self,
                forKey: .selectedProfileID
            )
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(profiles, forKey: .profiles)
        try container.encode(selectedProfileID, forKey: .selectedProfileID)
    }

    var selectedProfile: ConnectionProfile {
        profiles.first { $0.id == selectedProfileID } ?? profiles[0]
    }

    private static func validateUniqueNames(_ profiles: [ConnectionProfile]) throws {
        var names = Set<String>()
        for profile in profiles {
            let key = profile.name.lowercased()
            guard names.insert(key).inserted else {
                throw ConnectionProfileStoreError.duplicateProfileName(profile.name)
            }
        }
    }

    private static func validateUniqueIdentifiers(_ profiles: [ConnectionProfile]) throws {
        var identifiers = Set<ConnectionProfile.ID>()
        for profile in profiles where !identifiers.insert(profile.id).inserted {
            throw ConnectionProfileStoreError.duplicateProfileIdentifier(profile.id)
        }
    }
}

protocol ConnectionProfileFileWriting {
    func write(_ data: Data, to fileURL: URL) throws
}

struct AtomicConnectionProfileFileWriter: ConnectionProfileFileWriting {
    func write(_ data: Data, to fileURL: URL) throws {
        try data.write(to: fileURL, options: .atomic)
    }
}

struct ConnectionProfileSecretStores {
    let passwordStore: any ConnectionPasswordStoring
    let proxyPasswordStore: any ConnectionProxyPasswordStoring
    let clientIdentityStore: any ConnectionClientIdentityStoring

    static var keychain: ConnectionProfileSecretStores {
        ConnectionProfileSecretStores(
            passwordStore: KeychainPasswordStore(),
            proxyPasswordStore: KeychainProxyPasswordStore(),
            clientIdentityStore: ClientIdentityStore(
                importer: SecurityPKCS12IdentityImporter(),
                resolver: KeychainSecIdentityPersistentReferenceResolver(),
                bindingStore: KeychainClientIdentityReferenceBindingStore()
            )
        )
    }
}

final class ConnectionProfileStore {
    private let fileURL: URL
    private let passwordStore: ConnectionPasswordStoring
    private let proxyPasswordStore: ConnectionProxyPasswordStoring
    private let clientIdentityStore: any ConnectionClientIdentityStoring
    private let fileWriter: any ConnectionProfileFileWriting
    private let decoder = JSONDecoder()
    private let encoder: JSONEncoder
    private var passwordSnapshot: [ConnectionProfile.ID: String] = [:]
    private var proxyPasswordSnapshot: [ConnectionProfile.ID: String] = [:]

    init(
        fileURL: URL = ConnectionProfileStore.defaultFileURL(),
        passwordStore: ConnectionPasswordStoring? = nil,
        proxyPasswordStore: ConnectionProxyPasswordStoring? = nil,
        clientIdentityStore: (any ConnectionClientIdentityStoring)? = nil,
        fileWriter: any ConnectionProfileFileWriting = AtomicConnectionProfileFileWriter()
    ) {
        let defaultSecretStores: ConnectionProfileSecretStores?
        if passwordStore == nil || proxyPasswordStore == nil || clientIdentityStore == nil {
            defaultSecretStores = Self.defaultSecretStores()
        } else {
            defaultSecretStores = nil
        }

        self.fileURL = fileURL
        self.passwordStore = passwordStore ?? defaultSecretStores!.passwordStore
        self.proxyPasswordStore = proxyPasswordStore ?? defaultSecretStores!.proxyPasswordStore
        self.clientIdentityStore = clientIdentityStore ?? defaultSecretStores!.clientIdentityStore
        self.fileWriter = fileWriter
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    private static func defaultSecretStores() -> ConnectionProfileSecretStores {
#if DEBUG
        if let isolatedStore = PerformancePasswordStoreIsolation.activateIfRequested() {
            return isolatedStore
        }
#endif
        return .keychain
    }

    var hasPersistedProfiles: Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }

    func load() throws -> ConnectionProfileCollection {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return try ConnectionProfileCollection()
        }

        let data = try Data(contentsOf: fileURL)
        let loadedPasswords = try loadPasswords(
            into: decoder.decode(ConnectionProfileCollection.self, from: data)
        )
        let loadedProxyPasswords = try loadProxyPasswords(into: loadedPasswords.collection)
        let collection = loadedProxyPasswords.collection
        passwordSnapshot = loadedPasswords.passwords
        proxyPasswordSnapshot = loadedProxyPasswords.passwords
        if Self.requiresMigration(data) {
            try writeCollection(collection)
        }
        return try ConnectionProfileCollection(
            profiles: collection.profiles,
            selectedProfileID: collection.selectedProfileID
        )
    }

    func save(_ collection: ConnectionProfileCollection) throws {
        var normalizedCollection = try ConnectionProfileCollection(
            profiles: collection.profiles,
            selectedProfileID: collection.selectedProfileID
        )
        let savedProfiles = try savedProfilesByID()
        var transaction = ConnectionProfileSaveTransaction()

        do {
            let nextPasswordSnapshot = try syncPasswords(
                for: normalizedCollection,
                savedProfileIDs: Set(savedProfiles.keys),
                transaction: &transaction
            )
            let nextProxyPasswordSnapshot = try syncProxyPasswords(
                for: normalizedCollection,
                savedProfiles: savedProfiles,
                transaction: &transaction
            )
            let identityEditStateCommits = try syncClientIdentityBindings(
                in: &normalizedCollection,
                savedProfiles: savedProfiles,
                transaction: &transaction
            )
            try writeCollection(normalizedCollection)
            for commit in identityEditStateCommits {
                commit.state.markApplied(metadata: commit.metadata)
            }
            passwordSnapshot = nextPasswordSnapshot
            proxyPasswordSnapshot = nextProxyPasswordSnapshot
        } catch {
            let rollbackErrors = rollback(transaction)
            if !rollbackErrors.isEmpty {
                throw ConnectionProfileStoreError.transactionRollbackFailed(
                    original: error.localizedDescription,
                    rollback: rollbackErrors.map(\.localizedDescription).joined(separator: "; ")
                )
            }
            throw error
        }
    }

    private func syncClientIdentityBindings(
        in collection: inout ConnectionProfileCollection,
        savedProfiles: [ConnectionProfile.ID: ConnectionProfile],
        transaction: inout ConnectionProfileSaveTransaction
    ) throws -> [ClientIdentityEditStateCommit] {
        var editStateCommits: [ClientIdentityEditStateCommit] = []
        let currentProfileIDs = Set(collection.profiles.map(\.id))
        let deletedProfileIDs = savedProfiles.keys
            .filter { !currentProfileIDs.contains($0) }
            .sorted(by: Self.sortProfileIDs)

        for profileID in deletedProfileIDs {
            let previousReference = try clientIdentityStore.persistentReference(for: profileID)
            guard previousReference != nil else { continue }
            transaction.record(.clientIdentity(profileID: profileID, previousReference: previousReference))
            try clientIdentityStore.removeBinding(for: profileID)
        }

        for index in collection.profiles.indices {
            var profile = collection.profiles[index]
            guard let editState = profile.clientIdentityEditState else { continue }
            let identityState = editState.snapshot

            if let pendingImport = identityState.pendingImport {
                let previousReference = try clientIdentityStore.persistentReference(for: profile.id)
                let importResult = try clientIdentityStore.importAndBindTransaction(
                    data: pendingImport.pkcs12Data,
                    passphrase: pendingImport.passphrase,
                    profileID: profile.id,
                    scheme: profile.scheme,
                    now: Date()
                )
                if let rollbackToken = importResult.rollbackToken {
                    transaction.record(.clientIdentityMaterial(rollbackToken))
                }
                transaction.record(
                    .clientIdentity(profileID: profile.id, previousReference: previousReference)
                )
                let metadata = importResult.metadata
                profile.clientIdentityMetadata = metadata
                profile.clientIdentityEditState = nil
                collection.profiles[index] = profile
                editStateCommits.append(ClientIdentityEditStateCommit(state: editState, metadata: metadata))
                continue
            }

            guard identityState.removeOnApply else { continue }
            let previousReference = try clientIdentityStore.persistentReference(for: profile.id)
            if previousReference != nil {
                transaction.record(
                    .clientIdentity(profileID: profile.id, previousReference: previousReference)
                )
                try clientIdentityStore.removeBinding(for: profile.id)
            }
            profile.clientIdentityMetadata = nil
            profile.clientIdentityEditState = nil
            collection.profiles[index] = profile
            editStateCommits.append(ClientIdentityEditStateCommit(state: editState, metadata: nil))
        }

        return editStateCommits
    }

    private func rollback(_ transaction: ConnectionProfileSaveTransaction) -> [Error] {
        var errors: [Error] = []
        for action in transaction.rollbackActions.reversed() {
            do {
                switch action {
                case .password(let profileID, let previousPassword):
                    try restorePassword(previousPassword, for: profileID)
                case .proxyPassword(let profileID, let previousPassword):
                    try restoreProxyPassword(previousPassword, for: profileID)
                case .clientIdentity(let profileID, let previousReference):
                    try clientIdentityStore.restorePersistentReference(previousReference, for: profileID)
                case .clientIdentityMaterial(let token):
                    try clientIdentityStore.rollbackImportedIdentity(token)
                }
            } catch {
                errors.append(error)
            }
        }
        return errors
    }

    private func loadPasswords(
        into collection: ConnectionProfileCollection
    ) throws -> (collection: ConnectionProfileCollection, passwords: [ConnectionProfile.ID: String]) {
        var passwords: [ConnectionProfile.ID: String] = [:]
        let profiles = try collection.profiles.map { profile in
            var profile = profile
            if profile.askPasswordAtConnect {
                profile.password = ""
            } else if profile.password.isEmpty {
                profile.password = try passwordStore.password(for: profile.id) ?? ""
            } else {
                try passwordStore.setPassword(profile.password, for: profile.id)
            }
            passwords[profile.id] = profile.password
            return profile
        }
        return (
            try ConnectionProfileCollection(profiles: profiles, selectedProfileID: collection.selectedProfileID),
            passwords
        )
    }

    private func syncPasswords(
        for collection: ConnectionProfileCollection,
        savedProfileIDs: Set<ConnectionProfile.ID>,
        transaction: inout ConnectionProfileSaveTransaction
    ) throws -> [ConnectionProfile.ID: String] {
        var nextPasswordSnapshot = passwordSnapshot
        let currentProfileIDs = Set(collection.profiles.map(\.id))
        let deletedProfileIDs = savedProfileIDs
            .subtracting(currentProfileIDs)
            .sorted(by: Self.sortProfileIDs)
        for profileID in deletedProfileIDs {
            try applyPassword(nil, for: profileID, transaction: &transaction)
            nextPasswordSnapshot.removeValue(forKey: profileID)
        }

        for profile in collection.profiles {
            let password = profile.askPasswordAtConnect ? "" : profile.password
            guard nextPasswordSnapshot[profile.id] != password else { continue }

            try applyPassword(password.isEmpty ? nil : password, for: profile.id, transaction: &transaction)
            nextPasswordSnapshot[profile.id] = password
        }

        return nextPasswordSnapshot
    }

    private func applyPassword(
        _ password: String?,
        for profileID: ConnectionProfile.ID,
        transaction: inout ConnectionProfileSaveTransaction
    ) throws {
        let previousPassword = try passwordStore.password(for: profileID)
        guard previousPassword != password else { return }
        transaction.record(.password(profileID: profileID, previousPassword: previousPassword))
        if let password {
            try passwordStore.setPassword(password, for: profileID)
        } else {
            try passwordStore.removePassword(for: profileID)
        }
    }

    private func restorePassword(_ password: String?, for profileID: ConnectionProfile.ID) throws {
        if let password {
            try passwordStore.setPassword(password, for: profileID)
        } else {
            try passwordStore.removePassword(for: profileID)
        }
    }

    private func loadProxyPasswords(
        into collection: ConnectionProfileCollection
    ) throws -> (collection: ConnectionProfileCollection, passwords: [ConnectionProfile.ID: String]) {
        var passwords: [ConnectionProfile.ID: String] = [:]
        let profiles = try collection.profiles.map { profile in
            var profile = profile
            guard profile.proxySettings.authenticationEnabled else {
                profile.proxyPassword = ""
                passwords[profile.id] = ""
                return profile
            }

            if profile.proxyPassword.isEmpty {
                profile.proxyPassword = try proxyPasswordStore.password(for: profile.id) ?? ""
            } else {
                try proxyPasswordStore.setPassword(profile.proxyPassword, for: profile.id)
            }
            passwords[profile.id] = profile.proxyPassword
            return profile
        }
        return (
            try ConnectionProfileCollection(profiles: profiles, selectedProfileID: collection.selectedProfileID),
            passwords
        )
    }

    private func syncProxyPasswords(
        for collection: ConnectionProfileCollection,
        savedProfiles: [ConnectionProfile.ID: ConnectionProfile],
        transaction: inout ConnectionProfileSaveTransaction
    ) throws -> [ConnectionProfile.ID: String] {
        var nextPasswordSnapshot = proxyPasswordSnapshot
        let currentProfileIDs = Set(collection.profiles.map(\.id))
        let deletedProfileIDs = savedProfiles.keys
            .filter { !currentProfileIDs.contains($0) }
            .sorted(by: Self.sortProfileIDs)

        for profileID in deletedProfileIDs {
            let savedProfile = savedProfiles[profileID]!
            if savedProfile.proxySettings.authenticationEnabled {
                try applyProxyPassword(nil, for: profileID, transaction: &transaction)
            }
            nextPasswordSnapshot.removeValue(forKey: profileID)
        }

        for profile in collection.profiles {
            let savedProfileHadAuthentication = savedProfiles[profile.id]?.proxySettings.authenticationEnabled == true
            guard profile.proxySettings.authenticationEnabled else {
                if nextPasswordSnapshot[profile.id].map({ !$0.isEmpty }) == true || savedProfileHadAuthentication {
                    try applyProxyPassword(nil, for: profile.id, transaction: &transaction)
                }
                nextPasswordSnapshot[profile.id] = ""
                continue
            }

            let password = profile.proxyPassword
            guard nextPasswordSnapshot[profile.id] != password else { continue }

            if password.isEmpty {
                if nextPasswordSnapshot[profile.id] != nil || savedProfileHadAuthentication {
                    try applyProxyPassword(nil, for: profile.id, transaction: &transaction)
                }
            } else {
                try applyProxyPassword(password, for: profile.id, transaction: &transaction)
            }
            nextPasswordSnapshot[profile.id] = password
        }

        return nextPasswordSnapshot
    }

    private func applyProxyPassword(
        _ password: String?,
        for profileID: ConnectionProfile.ID,
        transaction: inout ConnectionProfileSaveTransaction
    ) throws {
        let previousPassword = try proxyPasswordStore.password(for: profileID)
        guard previousPassword != password else { return }
        transaction.record(.proxyPassword(profileID: profileID, previousPassword: previousPassword))
        if let password {
            try proxyPasswordStore.setPassword(password, for: profileID)
        } else {
            try proxyPasswordStore.removePassword(for: profileID)
        }
    }

    private func restoreProxyPassword(_ password: String?, for profileID: ConnectionProfile.ID) throws {
        if let password {
            try proxyPasswordStore.setPassword(password, for: profileID)
        } else {
            try proxyPasswordStore.removePassword(for: profileID)
        }
    }

    private func savedProfilesByID() throws -> [ConnectionProfile.ID: ConnectionProfile] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [:] }
        let data = try Data(contentsOf: fileURL)
        let collection = try decoder.decode(ConnectionProfileCollection.self, from: data)
        return Dictionary(uniqueKeysWithValues: collection.profiles.map { ($0.id, $0) })
    }

    private func writeCollection(_ collection: ConnectionProfileCollection) throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let data = try encoder.encode(collection)
        try fileWriter.write(data, to: fileURL)
    }

    private static func sortProfileIDs(_ lhs: ConnectionProfile.ID, _ rhs: ConnectionProfile.ID) -> Bool {
        lhs.uuidString < rhs.uuidString
    }

    private static func requiresMigration(_ data: Data) -> Bool {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let profiles = root["profiles"] as? [[String: Any]]
        else {
            return false
        }

        return profiles.contains { profile in
            profile["password"] != nil
                || profile["connectOnLaunch"] == nil
                || profile["requestTimeoutSeconds"] == nil
                || Self.transferPreferencesRequireMigration(in: profile)
                || profile["proxySettings"] == nil
        }
    }

    private static func transferPreferencesRequireMigration(in profile: [String: Any]) -> Bool {
        guard
            let storedObject = profile["transferPreferences"] as? [String: Any],
            JSONSerialization.isValidJSONObject(storedObject),
            let storedData = try? JSONSerialization.data(
                withJSONObject: storedObject,
                options: [.sortedKeys]
            ),
            let preferences = try? JSONDecoder().decode(
                ProfileTransferPreferences.self,
                from: storedData
            ),
            let encodedData = try? JSONEncoder().encode(preferences),
            let encodedObject = try? JSONSerialization.jsonObject(with: encodedData),
            let canonicalData = try? JSONSerialization.data(
                withJSONObject: encodedObject,
                options: [.sortedKeys]
            )
        else {
            return true
        }

        return storedData != canonicalData
    }

    static func defaultFileURL() -> URL {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return applicationSupport
            .appendingPathComponent("TransmissionRemoteMac", isDirectory: true)
            .appendingPathComponent("ConnectionProfiles.json")
    }
}

#if DEBUG
enum PerformancePasswordStoreIsolation {
    static let compiledMarker = "TRM_PERFORMANCE_PASSWORD_STORE_ISOLATION_V1"
    static let modeEnvironmentKey = "TRANSMISSION_REMOTE_MAC_PERFORMANCE_ISOLATION"
    static let homeEnvironmentKey = "TRANSMISSION_REMOTE_MAC_PERFORMANCE_HOME"
    static let tokenEnvironmentKey = "TRANSMISSION_REMOTE_MAC_PERFORMANCE_TOKEN"
    static let requestMarkerName = ".transmission-remote-mac-performance-isolation"
    static let activationProofName = ".transmission-remote-mac-performance-password-store-active"

    static func activateIfRequested(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        resolvedHomePath: String = NSHomeDirectory(),
        fileManager: FileManager = .default
    ) -> ConnectionProfileSecretStores? {
        guard environment[modeEnvironmentKey] != nil else { return nil }
        do {
            let context = try validatedContext(
                environment: environment,
                resolvedHomePath: resolvedHomePath,
                fileManager: fileManager
            )
            let proof = "\(compiledMarker)\n\(context.token)\n"
            try proof.write(to: context.proofURL, atomically: true, encoding: .utf8)
            return ConnectionProfileSecretStores(
                passwordStore: PerformanceIsolationPasswordStore(),
                proxyPasswordStore: PerformanceIsolationPasswordStore(),
                clientIdentityStore: PerformanceIsolationClientIdentityStore()
            )
        } catch {
            let passwordStore = RejectedPerformanceIsolationPasswordStore(error: error)
            return ConnectionProfileSecretStores(
                passwordStore: passwordStore,
                proxyPasswordStore: passwordStore,
                clientIdentityStore: RejectedPerformanceIsolationClientIdentityStore(error: error)
            )
        }
    }

    private static func validatedContext(
        environment: [String: String],
        resolvedHomePath: String,
        fileManager: FileManager
    ) throws -> (token: String, proofURL: URL) {
        guard environment[modeEnvironmentKey] == "1" else {
            throw PerformancePasswordStoreIsolationError.invalidMode
        }
        guard
            let declaredHomePath = environment[homeEnvironmentKey],
            let temporaryPath = environment["TMPDIR"],
            let token = environment[tokenEnvironmentKey],
            token.count >= 32
        else {
            throw PerformancePasswordStoreIsolationError.missingIsolationContext
        }

        let declaredHome = canonicalURL(for: declaredHomePath)
        let resolvedHome = canonicalURL(for: resolvedHomePath)
        let expectedTemporaryDirectory = declaredHome.appendingPathComponent("tmp", isDirectory: true)
        let temporaryDirectory = canonicalURL(for: temporaryPath)
        guard
            declaredHome.path != "/",
            declaredHome == resolvedHome,
            temporaryDirectory == expectedTemporaryDirectory,
            fileManager.fileExists(atPath: expectedTemporaryDirectory.path)
        else {
            throw PerformancePasswordStoreIsolationError.invalidIsolatedHome
        }

        let markerURL = declaredHome.appendingPathComponent(requestMarkerName, isDirectory: false)
        let markerToken: String
        do {
            markerToken = try String(contentsOf: markerURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw PerformancePasswordStoreIsolationError.requestMarkerUnavailable
        }
        guard markerToken == token else {
            throw PerformancePasswordStoreIsolationError.markerMismatch
        }
        do {
            try fileManager.removeItem(at: markerURL)
        } catch {
            throw PerformancePasswordStoreIsolationError.requestMarkerUnavailable
        }
        return (
            token,
            declaredHome.appendingPathComponent(activationProofName, isDirectory: false)
        )
    }

    private static func canonicalURL(for path: String) -> URL {
        URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
    }
}

private final class PerformanceIsolationPasswordStore:
    ConnectionPasswordStoring,
    ConnectionProxyPasswordStoring {
    private var passwords: [ConnectionProfile.ID: String] = [:]

    func password(for profileID: ConnectionProfile.ID) throws -> String? {
        passwords[profileID]
    }

    func setPassword(_ password: String, for profileID: ConnectionProfile.ID) throws {
        passwords[profileID] = password
    }

    func removePassword(for profileID: ConnectionProfile.ID) throws {
        passwords.removeValue(forKey: profileID)
    }
}

private final class PerformanceIsolationClientIdentityStore: ConnectionClientIdentityStoring {
    private var references: [ConnectionProfile.ID: Data] = [:]

    func importAndBind(
        data: Data,
        passphrase: String,
        profileID: ConnectionProfile.ID,
        scheme: String,
        now: Date
    ) throws -> ClientIdentityMetadata {
        throw ClientIdentityStoreError.performanceIsolation
    }

    func persistentReference(for profileID: ConnectionProfile.ID) throws -> Data? {
        references[profileID]
    }

    func restorePersistentReference(
        _ persistentReference: Data?,
        for profileID: ConnectionProfile.ID
    ) throws {
        references[profileID] = persistentReference
    }

    func removeBinding(for profileID: ConnectionProfile.ID) throws {
        references.removeValue(forKey: profileID)
    }
}

private struct RejectedPerformanceIsolationPasswordStore:
    ConnectionPasswordStoring,
    ConnectionProxyPasswordStoring {
    let error: Error

    func password(for profileID: ConnectionProfile.ID) throws -> String? { throw error }
    func setPassword(_ password: String, for profileID: ConnectionProfile.ID) throws { throw error }
    func removePassword(for profileID: ConnectionProfile.ID) throws { throw error }
}

private struct RejectedPerformanceIsolationClientIdentityStore: ConnectionClientIdentityStoring {
    let error: Error

    func importAndBind(
        data: Data,
        passphrase: String,
        profileID: ConnectionProfile.ID,
        scheme: String,
        now: Date
    ) throws -> ClientIdentityMetadata {
        throw error
    }

    func persistentReference(for profileID: ConnectionProfile.ID) throws -> Data? { throw error }

    func restorePersistentReference(
        _ persistentReference: Data?,
        for profileID: ConnectionProfile.ID
    ) throws {
        throw error
    }

    func removeBinding(for profileID: ConnectionProfile.ID) throws { throw error }
}

enum PerformancePasswordStoreIsolationError: LocalizedError, Equatable {
    case invalidMode
    case missingIsolationContext
    case invalidIsolatedHome
    case markerMismatch
    case requestMarkerUnavailable

    var errorDescription: String? {
        "Performance secret-store isolation was requested but its temporary-home proof was invalid."
    }
}
#endif

enum ConnectionProfileStoreError: LocalizedError, Equatable {
    case emptyProfileList
    case duplicateProfileIdentifier(ConnectionProfile.ID)
    case duplicateProfileName(String)
    case unknownProfile(ConnectionProfile.ID)
    case transactionRollbackFailed(original: String, rollback: String)

    var errorDescription: String? {
        switch self {
        case .emptyProfileList: "At least one connection profile is required"
        case .duplicateProfileIdentifier(let id): "Connection profile identifier already exists: \(id)"
        case .duplicateProfileName(let name): "Connection profile name already exists: \(name)"
        case .unknownProfile(let id): "Connection profile does not exist: \(id)"
        case .transactionRollbackFailed(let original, let rollback):
            "Connection profile save failed (\(original)); secret rollback also failed (\(rollback))"
        }
    }
}

private struct ClientIdentityEditStateCommit {
    let state: ClientIdentityEditState
    let metadata: ClientIdentityMetadata?
}

private enum ConnectionProfileSecretRollbackAction {
    case password(profileID: ConnectionProfile.ID, previousPassword: String?)
    case proxyPassword(profileID: ConnectionProfile.ID, previousPassword: String?)
    case clientIdentity(profileID: ConnectionProfile.ID, previousReference: Data?)
    case clientIdentityMaterial(ClientIdentityImportRollbackToken)
}

private struct ConnectionProfileSaveTransaction {
    private(set) var rollbackActions: [ConnectionProfileSecretRollbackAction] = []

    mutating func record(_ action: ConnectionProfileSecretRollbackAction) {
        rollbackActions.append(action)
    }
}
