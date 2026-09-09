// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation

struct SettingsPortabilityDocument: Codable, Equatable, Sendable {
    static let schemaIdentifier = "net.pokwer.TransmissionRemoteMac.settings"
    static let legacySchemaVersion = 4
    static let currentSchemaVersion = 5

    var schemaIdentifier: String
    var schemaVersion: Int
    var profiles: [PortableConnectionProfile]
    var selectedProfileID: UUID?
    var applicationPreferences: PortableApplicationPreferences

    init(
        schemaIdentifier: String = Self.schemaIdentifier,
        schemaVersion: Int = Self.currentSchemaVersion,
        profiles: [PortableConnectionProfile],
        selectedProfileID: UUID?,
        applicationPreferences: PortableApplicationPreferences
    ) {
        self.schemaIdentifier = schemaIdentifier
        self.schemaVersion = schemaVersion
        self.profiles = profiles
        self.selectedProfileID = selectedProfileID
        self.applicationPreferences = applicationPreferences
    }
}

enum PortableCredentialRequirement: String, Codable, Equatable, Sendable {
    case none
    case reenterAfterImport
}

struct PortableConnectionProfile: Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var scheme: String
    var host: String
    var port: Int
    var rpcPath: String
    var username: String
    var askPasswordAtConnect: Bool
    var rpcCredentialRequirement: PortableCredentialRequirement
    var pathMappings: [PortablePathMapping]
    var connectOnLaunch: Bool
    var autoReconnect: Bool
    var requestTimeoutSeconds: Int
    var transferPreferences: PortableProfileTransferPreferences
    var proxy: PortableProxySettings
    var clientCertificate: PortableClientCertificateMetadata?

    init(
        id: UUID,
        name: String,
        scheme: String,
        host: String,
        port: Int,
        rpcPath: String,
        username: String,
        askPasswordAtConnect: Bool = false,
        rpcCredentialRequirement: PortableCredentialRequirement,
        pathMappings: [PortablePathMapping],
        connectOnLaunch: Bool,
        autoReconnect: Bool,
        requestTimeoutSeconds: Int,
        transferPreferences: PortableProfileTransferPreferences,
        proxy: PortableProxySettings,
        clientCertificate: PortableClientCertificateMetadata?
    ) {
        self.id = id
        self.name = name
        self.scheme = scheme
        self.host = host
        self.port = port
        self.rpcPath = rpcPath
        self.username = username
        self.askPasswordAtConnect = askPasswordAtConnect
        self.rpcCredentialRequirement = rpcCredentialRequirement
        self.pathMappings = pathMappings
        self.connectOnLaunch = connectOnLaunch
        self.autoReconnect = autoReconnect
        self.requestTimeoutSeconds = requestTimeoutSeconds
        self.transferPreferences = transferPreferences
        self.proxy = proxy
        self.clientCertificate = clientCertificate
    }
}

struct PortablePathMapping: Codable, Equatable, Sendable {
    var remotePathPrefix: String
    var localPathPrefix: String
}

/// Per-profile presets are portable. Destination histories are deliberately
/// absent because remote paths can expose private machine and share layouts.
struct PortableProfileTransferPreferences: Codable, Equatable, Sendable {
    var downloadSpeedPresetsKBps: [Int]
    var uploadSpeedPresetsKBps: [Int]
    var destinationHistoryLimit: Int
}

struct PortableProxySettings: Codable, Equatable, Sendable {
    var transport: ProxyTransport
    var host: String
    var port: Int
    var authenticationEnabled: Bool
    var username: String
    var credentialRequirement: PortableCredentialRequirement
}

/// Public certificate facts only. The subject, issuer, display name, private key,
/// PKCS#12 data, and Keychain binding are deliberately outside the export schema.
struct PortableClientCertificateMetadata: Codable, Equatable, Sendable {
    var sha256Fingerprint: String
    var notBeforeUnixSeconds: Int64
    var notAfterUnixSeconds: Int64
}

struct PortableApplicationPreferences: Codable, Equatable, Sendable {
    var polling: PortablePollingPreferences
    var behavior: ApplicationBehaviorPreferences
    var interaction: ApplicationInteractionPreferences
    var intake: IntakeAutomationPreferences
    var peerResolution: PeerResolutionPreferences
    var watchFolder: RedactedPortableWatchFolderConfiguration
    var workspace: UIWorkspacePreferences
    var torrentTable: PortableTorrentTablePreferences
    var tableColumnCustomizations: PortableTableColumnCustomizations? = nil
}

struct PortablePollingPreferences: Codable, Equatable, Sendable {
    var foregroundIntervalSeconds: Int
    var backgroundIntervalSeconds: Int
    var backgroundPolicy: BackgroundPollingPolicy
    var adaptiveIdleEnabled: Bool

    init(
        foregroundIntervalSeconds: Int,
        backgroundIntervalSeconds: Int,
        backgroundPolicy: BackgroundPollingPolicy,
        adaptiveIdleEnabled: Bool = false
    ) {
        self.foregroundIntervalSeconds = foregroundIntervalSeconds
        self.backgroundIntervalSeconds = backgroundIntervalSeconds
        self.backgroundPolicy = backgroundPolicy
        self.adaptiveIdleEnabled = adaptiveIdleEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        foregroundIntervalSeconds = try container.decode(Int.self, forKey: .foregroundIntervalSeconds)
        backgroundIntervalSeconds = try container.decode(Int.self, forKey: .backgroundIntervalSeconds)
        backgroundPolicy = try container.decode(BackgroundPollingPolicy.self, forKey: .backgroundPolicy)
        adaptiveIdleEnabled = try container.decodeIfPresent(Bool.self, forKey: .adaptiveIdleEnabled) ?? false
    }
}

struct PortableTorrentTablePreferences: Codable, Equatable, Sendable {
    var visibleColumnIDs: [String]
    var sortColumnID: String
    var sortDirection: PortableSortDirection
}

enum PortableSortDirection: String, Codable, Equatable, Sendable {
    case ascending
    case descending
}

/// The native settings represented by the portability document. Existing model
/// types remain the source of truth; this snapshot does not create parallel
/// persistence schemas.
struct SettingsExportPreferences: Equatable, Sendable {
    var polling: PollingPreferences
    var behavior: ApplicationBehaviorPreferences
    var interaction: ApplicationInteractionPreferences
    var intake: IntakeAutomationPreferences
    var peerResolution: PeerResolutionPreferences
    var watchFolderConfiguration: WatchFolderConfiguration
    var workspace: UIWorkspacePreferences
    var visibleTorrentColumns: Set<TorrentTableColumnID>
    var torrentSort: TorrentTableSortPreference
    var tableColumnCustomizations: PortableTableColumnCustomizations?

    init(
        polling: PollingPreferences = .defaults,
        behavior: ApplicationBehaviorPreferences = .defaults,
        interaction: ApplicationInteractionPreferences = .defaults,
        intake: IntakeAutomationPreferences = .defaults,
        peerResolution: PeerResolutionPreferences = .defaults,
        watchFolderConfiguration: WatchFolderConfiguration = .defaults,
        workspace: UIWorkspacePreferences = .defaults,
        visibleTorrentColumns: Set<TorrentTableColumnID> = Set(
            TorrentTableColumnID.allCases.filter(\.isVisibleByDefault)
        ),
        torrentSort: TorrentTableSortPreference = TorrentTableDefaults.sort,
        tableColumnCustomizations: PortableTableColumnCustomizations? = nil
    ) {
        self.polling = polling
        self.behavior = behavior
        self.interaction = interaction
        self.intake = intake
        self.peerResolution = peerResolution
        self.watchFolderConfiguration = watchFolderConfiguration
        self.workspace = workspace
        self.visibleTorrentColumns = visibleTorrentColumns
        self.torrentSort = torrentSort
        self.tableColumnCustomizations = tableColumnCustomizations
    }
}

struct SettingsExportSnapshot {
    var profiles: [ConnectionProfile]
    var selectedProfileID: UUID?
    var applicationPreferences: SettingsExportPreferences
    var clientCertificateMetadataByProfileID: [UUID: ClientIdentityMetadata]

    init(
        profiles: [ConnectionProfile],
        selectedProfileID: UUID?,
        applicationPreferences: SettingsExportPreferences,
        clientCertificateMetadataByProfileID: [UUID: ClientIdentityMetadata] = [:]
    ) {
        self.profiles = profiles
        self.selectedProfileID = selectedProfileID
        self.applicationPreferences = applicationPreferences
        self.clientCertificateMetadataByProfileID = clientCertificateMetadataByProfileID
    }
}

enum SettingsProfileCollisionPolicy: Equatable, Sendable {
    case skipExisting
    case updateMatchingIdentifier
}

struct SettingsProfileImportSkip: Equatable, Sendable {
    var profileID: UUID
    var reason: SettingsProfileImportSkipReason
}

enum SettingsProfileImportSkipReason: Equatable, Sendable {
    case unchanged
    case identifierCollision
    case nameCollision(existingProfileID: UUID)
}

enum SettingsApplicationPreferencesImportAction: Equatable, Sendable {
    case apply(PortableApplicationPreferences)
    case skipUnchanged
}

/// A read-only decision record. Only SettingsPortabilityCoordinator may commit it.
struct SettingsImportPlan: Equatable, Sendable {
    var profileAdditions: [PortableConnectionProfile]
    var profileUpdates: [PortableConnectionProfile]
    var profileSkips: [SettingsProfileImportSkip]
    var selectedProfileID: UUID?
    var applicationPreferences: SettingsApplicationPreferencesImportAction
}

enum SettingsPortabilityError: LocalizedError, Equatable {
    case malformedDocument
    case invalidSchemaIdentifier(String)
    case unsupportedSchemaVersion(Int)
    case forbiddenField(String)
    case duplicateProfileIdentifier(UUID)
    case duplicateProfileName(String)
    case selectedProfileMissing(UUID)
    case invalidProfile(UUID, String)
    case invalidClientCertificate(UUID)
    case clientCertificateRequiresHTTPS(UUID)
    case invalidApplicationPreferences(String)
    case settingsDocumentTooLarge
    case tableColumnCustomizationTooLarge(String)
    case invalidTableColumnCustomization(String)
    case requiredTableColumnHidden(String)
    case duplicateExistingProfileIdentifier(UUID)

    var errorDescription: String? {
        switch self {
        case .malformedDocument:
            "The settings document is malformed."
        case .invalidSchemaIdentifier(let identifier):
            "The settings schema is not supported: \(identifier)"
        case .unsupportedSchemaVersion(let version):
            "The settings schema version is not supported: \(version)"
        case .forbiddenField(let field):
            "The settings document contains a forbidden field: \(field)"
        case .duplicateProfileIdentifier(let id):
            "The settings document repeats profile identifier \(id.uuidString)."
        case .duplicateProfileName(let name):
            "The settings document repeats profile name \(name)."
        case .selectedProfileMissing(let id):
            "The selected profile is missing from the settings document: \(id.uuidString)"
        case .invalidProfile(let id, let message):
            "Profile \(id.uuidString) is invalid: \(message)"
        case .invalidClientCertificate(let id):
            "Profile \(id.uuidString) contains invalid public certificate metadata."
        case .clientCertificateRequiresHTTPS(let id):
            "Profile \(id.uuidString) can describe a client certificate only for HTTPS."
        case .invalidApplicationPreferences(let message):
            "Application preferences are invalid: \(message)"
        case .settingsDocumentTooLarge:
            "The settings document is too large."
        case .tableColumnCustomizationTooLarge(let tableName):
            "The \(tableName) table customization is too large."
        case .invalidTableColumnCustomization(let tableName):
            "The \(tableName) table customization is invalid."
        case .requiredTableColumnHidden(let tableName):
            "The required \(tableName) table column cannot be hidden."
        case .duplicateExistingProfileIdentifier(let id):
            "Existing profiles repeat identifier \(id.uuidString)."
        }
    }
}
