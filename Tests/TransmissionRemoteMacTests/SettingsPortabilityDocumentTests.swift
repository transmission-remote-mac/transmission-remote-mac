// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation
import XCTest
@testable import TransmissionRemoteMac

final class SettingsPortabilityDocumentTests: XCTestCase {
    func testLegacySchemaFourDocumentMigratesVisibilityIntoCompleteTableDefaults() throws {
        let workspace = UIWorkspacePreferences(
            filterPane: WorkspaceVisibilityPreference(isVisible: false),
            statusSummary: WorkspaceVisibilityPreference(isVisible: false),
            secondaryTables: SecondaryTableWorkspacePreferences(
                files: SecondaryTableLayoutPreference(
                    hiddenColumnIDs: [SecondaryTableColumnID.Files.priority],
                    sortPreference: SecondaryTableDefaults.fileSort
                ),
                peers: SecondaryTableLayoutPreference(
                    hiddenColumnIDs: [SecondaryTableColumnID.Peers.client],
                    sortPreference: SecondaryTableDefaults.peerSort
                ),
                trackers: SecondaryTableLayoutPreference(
                    hiddenColumnIDs: [SecondaryTableColumnID.Trackers.status],
                    sortPreference: SecondaryTableDefaults.trackerSort
                )
            )
        )
        var legacyDocument = try SettingsPortabilityService.makeDocument(
            snapshot: SettingsExportSnapshot(
                profiles: [],
                selectedProfileID: nil,
                applicationPreferences: SettingsExportPreferences(
                    workspace: workspace,
                    visibleTorrentColumns: [.name, .done, .uploaded]
                )
            )
        )
        legacyDocument.schemaVersion = SettingsPortabilityDocument.legacySchemaVersion
        legacyDocument.applicationPreferences.tableColumnCustomizations = nil

        let migrated = try SettingsPortabilityService.decodeAndValidate(
            JSONEncoder().encode(legacyDocument)
        )
        let tableValue = try XCTUnwrap(
            migrated.applicationPreferences.tableColumnCustomizations
        )
        let tableSnapshot = try TableColumnCustomizationPortabilityService.validated(tableValue)

        XCTAssertEqual(migrated.schemaVersion, SettingsPortabilityDocument.currentSchemaVersion)
        XCTAssertEqual(tableSnapshot.visibleTorrentColumns, [.name, .done, .uploaded])
        XCTAssertEqual(
            tableSnapshot.hiddenFileColumnIDs,
            [SecondaryTableColumnID.Files.priority]
        )
        XCTAssertEqual(
            tableSnapshot.hiddenPeerColumnIDs,
            [SecondaryTableColumnID.Peers.client]
        )
        XCTAssertEqual(
            tableSnapshot.hiddenTrackerColumnIDs,
            [SecondaryTableColumnID.Trackers.status]
        )
        XCTAssertFalse(migrated.applicationPreferences.workspace.filterPane.isVisible)
        XCTAssertFalse(migrated.applicationPreferences.workspace.statusSummary.isVisible)
    }

    func testCurrentDocumentRejectsMissingCompleteTableState() throws {
        var document = try SettingsPortabilityService.makeDocument(
            snapshot: SettingsExportSnapshot(
                profiles: [],
                selectedProfileID: nil,
                applicationPreferences: SettingsExportPreferences()
            )
        )
        document.applicationPreferences.tableColumnCustomizations = nil

        XCTAssertThrowsError(try SettingsPortabilityService.validated(document)) { error in
            guard let portabilityError = error as? SettingsPortabilityError,
                  case .invalidApplicationPreferences = portabilityError else {
                return XCTFail("Expected missing complete table state, got \(error)")
            }
        }
    }

    func testDecodeRejectsOversizedDocumentBeforeParsing() {
        let data = Data(
            repeating: 0x20,
            count: SettingsPortabilityService.maximumDocumentByteCount + 1
        )

        XCTAssertThrowsError(try SettingsPortabilityService.decodeAndValidate(data)) { error in
            XCTAssertEqual(error as? SettingsPortabilityError, .settingsDocumentTooLarge)
        }
    }

    func testPollingPortabilityMigratesMissingAdaptiveIdleFlagAndRoundTripsEnabledState() throws {
        let legacy = Data(
            #"{"foregroundIntervalSeconds":5,"backgroundIntervalSeconds":20,"backgroundPolicy":"pollSlowly"}"#.utf8
        )
        let migrated = try JSONDecoder().decode(PortablePollingPreferences.self, from: legacy)
        XCTAssertFalse(migrated.adaptiveIdleEnabled)

        let enabled = PortablePollingPreferences(
            foregroundIntervalSeconds: 5,
            backgroundIntervalSeconds: 20,
            backgroundPolicy: .pollSlowly,
            adaptiveIdleEnabled: true
        )
        let roundTrip = try JSONDecoder().decode(
            PortablePollingPreferences.self,
            from: JSONEncoder().encode(enabled)
        )
        XCTAssertEqual(roundTrip, enabled)
    }

    func testImportUpdatePreservesPrivateDestinationRulesExcludedFromPortableDocument() throws {
        let rules = try AddTorrentDestinationRulesSnapshot(
            defaultDestination: "/private/default",
            rules: [
                try AddTorrentDestinationRule(
                    label: "Private video",
                    destination: "/private/video",
                    extensions: ["mkv"]
                )
            ]
        )
        let existing = try ConnectionProfile.validated(
            name: "Existing",
            host: "old.example",
            transferPreferences: ProfileTransferPreferences(
                addDestinationRules: rules
            )
        )
        let portable = try XCTUnwrap(
            SettingsPortabilityService.makeDocument(
                snapshot: SettingsExportSnapshot(
                    profiles: [existing],
                    selectedProfileID: existing.id,
                    applicationPreferences: .init()
                )
            ).profiles.first
        )
        var changedPortable = portable
        changedPortable.host = "replacement.example"

        let imported = try SettingsPortabilityService.importedConnectionProfile(
            from: changedPortable,
            replacing: existing
        )

        XCTAssertEqual(imported.host, "replacement.example")
        XCTAssertEqual(imported.transferPreferences.addDestinationRules, rules)
    }

    func testPeerResolutionExportPreservesSwitchesWithoutDatabaseContentsOrCustomSource() throws {
        let customSource = "https://country.example/private-source-7b42/ranges.csv.gz?token=query-secret-43ec"
        let preferences = SettingsExportPreferences(
            peerResolution: PeerResolutionPreferences(
                resolveHostNames: true,
                resolveCountries: true,
                showCountryFlags: true,
                countryDatabaseSourceURL: customSource
            )
        )

        let data = try SettingsPortabilityService.encode(snapshot: SettingsExportSnapshot(
            profiles: [],
            selectedProfileID: nil,
            applicationPreferences: preferences
        ))
        let document = try SettingsPortabilityService.decodeAndValidate(data)
        let imported = try SettingsPortabilityService.importedPreferences(
            from: document.applicationPreferences
        )
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertEqual(preferences.peerResolution.countryDatabaseSourceURL, customSource)
        XCTAssertEqual(document.applicationPreferences.peerResolution.countryDatabaseSourceURL, "")
        XCTAssertEqual(imported.peerResolution, PeerResolutionPreferences(
            resolveHostNames: true,
            resolveCountries: true,
            showCountryFlags: true
        ))
        XCTAssertTrue(json.contains("\"peerResolution\""))
        XCTAssertFalse(json.contains("country.example"))
        XCTAssertFalse(json.contains("private-source-7b42"))
        XCTAssertFalse(json.contains("query-secret-43ec"))
        XCTAssertFalse(json.localizedCaseInsensitiveContains("country-ranges"))
        XCTAssertFalse(json.localizedCaseInsensitiveContains("dbip-country-lite"))
    }

    func testCountrySourceRedactionDoesNotBlockExportForUnusableLocalURL() throws {
        let preferences = SettingsExportPreferences(
            peerResolution: PeerResolutionPreferences(
                resolveHostNames: true,
                resolveCountries: false,
                showCountryFlags: false,
                countryDatabaseSourceURL: "http://country.example/private-source"
            )
        )

        let document = try SettingsPortabilityService.makeDocument(snapshot: SettingsExportSnapshot(
            profiles: [],
            selectedProfileID: nil,
            applicationPreferences: preferences
        ))

        XCTAssertEqual(document.applicationPreferences.peerResolution.countryDatabaseSourceURL, "")
        XCTAssertTrue(document.applicationPreferences.peerResolution.resolveHostNames)
        XCTAssertEqual(preferences.peerResolution.countryDatabaseSourceURL, "http://country.example/private-source")
    }

    func testExplicitValidCountrySourceCanStillBeImported() throws {
        var document = try SettingsPortabilityService.makeDocument(
            snapshot: SettingsExportSnapshot(
                profiles: [],
                selectedProfileID: nil,
                applicationPreferences: .init()
            )
        )
        let customSource = "https://country.example/custom-ranges.csv.gz?access=custom-token"
        document.applicationPreferences.peerResolution.countryDatabaseSourceURL = customSource
        let validated = try SettingsPortabilityService.decodeAndValidate(JSONEncoder().encode(document))

        let imported = try SettingsPortabilityService.importedPreferences(
            from: validated.applicationPreferences
        )

        XCTAssertEqual(imported.peerResolution.countryDatabaseSourceURL, customSource)
        XCTAssertFalse(imported.peerResolution.resolveCountries)
        XCTAssertFalse(imported.peerResolution.showCountryFlags)
    }

    func testInvalidCountryDatabaseSourceCannotBeImported() throws {
        var document = try SettingsPortabilityService.makeDocument(
            snapshot: SettingsExportSnapshot(
                profiles: [],
                selectedProfileID: nil,
                applicationPreferences: .init()
            )
        )
        document.applicationPreferences.peerResolution.countryDatabaseSourceURL = "http://country.example/ranges.csv"

        XCTAssertThrowsError(
            try SettingsPortabilityService.importedPreferences(from: document.applicationPreferences)
        )
    }

    func testRoundTripPreservesAskPasswordPolicySeparatelyFromCredentialReentry() throws {
        let profile = try ConnectionProfile.validated(
            name: "Prompted",
            host: "transmission.example",
            username: "rpc-user",
            askPasswordAtConnect: true
        )

        let data = try SettingsPortabilityService.encode(
            snapshot: SettingsExportSnapshot(
                profiles: [profile],
                selectedProfileID: profile.id,
                applicationPreferences: SettingsExportPreferences()
            )
        )
        let portable = try XCTUnwrap(
            SettingsPortabilityService.decodeAndValidate(data).profiles.first
        )

        XCTAssertTrue(portable.askPasswordAtConnect)
        XCTAssertEqual(portable.rpcCredentialRequirement, .none)
    }

    func testExportIsDeterministicAndContainsOnlyRedactedCertificateMetadata() throws {
        let firstID = try XCTUnwrap(UUID(uuidString: "00000000-0000-4000-8000-000000000001"))
        let secondID = try XCTUnwrap(UUID(uuidString: "00000000-0000-4000-8000-000000000002"))
        let sensitiveValues = [
            "RPC-PASSWORD-SENTINEL",
            "PROXY-PASSWORD-SENTINEL",
            "PKCS12-PASSPHRASE-SENTINEL",
            "KEYCHAIN-PERSISTENT-REFERENCE-SENTINEL",
            "CERTIFICATE-SUBJECT-SENTINEL",
            "CERTIFICATE-ISSUER-SENTINEL",
            "CERTIFICATE-DISPLAY-NAME-SENTINEL",
            "ADD-DESTINATION-HISTORY-SENTINEL",
            "MOVE-DESTINATION-HISTORY-SENTINEL",
            "WATCH-BOOKMARK-SENTINEL",
            "PRIVATE-KEY-SENTINEL",
        ]
        let first = try ConnectionProfile.validated(
            id: firstID,
            name: "First",
            scheme: "https",
            host: "first.example",
            port: 443,
            username: "rpc-user",
            password: sensitiveValues[0],
            pathMappings: [
                PathMapping(remotePathPrefix: "/z", localPathPrefix: "/Volumes/Z"),
                PathMapping(remotePathPrefix: "/a", localPathPrefix: "/Volumes/A"),
            ],
            transferPreferences: ProfileTransferPreferences(
                downloadSpeedPresetsKBps: [125, 500],
                uploadSpeedPresetsKBps: [25, 75],
                destinationHistoryLimit: 4,
                addDestinationHistory: [sensitiveValues[7]],
                moveDestinationHistory: [sensitiveValues[8]]
            ),
            proxySettings: ProxySettings(
                transport: .socks5,
                host: "proxy.example",
                port: 1080,
                authenticationEnabled: true,
                username: "proxy-user"
            ),
            proxyPassword: sensitiveValues[1],
            clientIdentityEditState: ClientIdentityEditState(
                pendingImport: PendingClientIdentityImport(
                    sourceFileName: "identity.p12",
                    pkcs12Data: Data("\(sensitiveValues[3])|\(sensitiveValues[10])".utf8),
                    passphrase: sensitiveValues[2]
                )
            )
        )
        let second = try ConnectionProfile.validated(
            id: secondID,
            name: "Second",
            host: "second.example"
        )
        let metadata = ClientIdentityMetadata(
            displayName: sensitiveValues[6],
            sha256Fingerprint: String(repeating: "ab:", count: 31) + "ab",
            subject: sensitiveValues[4],
            issuer: sensitiveValues[5],
            notBefore: Date(timeIntervalSince1970: 1_700_000_000),
            notAfter: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let preferences = SettingsExportPreferences(
            watchFolderConfiguration: WatchFolderConfiguration(
                isEnabled: true,
                sourceBookmarkData: Data(sensitiveValues[9].utf8),
                remoteDestination: "/incoming",
                scanIntervalSeconds: 30,
                successPolicy: .moveSource,
                submissionPolicy: .submitDirectly,
                processedFolderBookmarkData: Data(sensitiveValues[9].utf8)
            )
        )

        let ascending = try SettingsPortabilityService.encode(
            snapshot: SettingsExportSnapshot(
                profiles: [first, second],
                selectedProfileID: secondID,
                applicationPreferences: preferences,
                clientCertificateMetadataByProfileID: [firstID: metadata]
            )
        )
        let descending = try SettingsPortabilityService.encode(
            snapshot: SettingsExportSnapshot(
                profiles: [second, first],
                selectedProfileID: secondID,
                applicationPreferences: preferences,
                clientCertificateMetadataByProfileID: [firstID: metadata]
            )
        )
        let json = try XCTUnwrap(String(data: ascending, encoding: .utf8))
        let document = try SettingsPortabilityService.decodeAndValidate(ascending)

        XCTAssertEqual(ascending, descending)
        XCTAssertEqual(document.profiles.map(\.id), [firstID, secondID])
        XCTAssertEqual(document.selectedProfileID, secondID)
        XCTAssertEqual(
            document.profiles[0].pathMappings.map(\.remotePathPrefix),
            ["/a", "/z"]
        )
        XCTAssertFalse(document.profiles[0].askPasswordAtConnect)
        XCTAssertEqual(document.profiles[0].rpcCredentialRequirement, .reenterAfterImport)
        XCTAssertEqual(document.profiles[0].proxy.credentialRequirement, .reenterAfterImport)
        XCTAssertEqual(
            document.profiles[0].transferPreferences.downloadSpeedPresetsKBps,
            [125, 500]
        )
        XCTAssertEqual(document.profiles[0].transferPreferences.destinationHistoryLimit, 4)
        XCTAssertFalse(document.applicationPreferences.watchFolder.isEnabled)
        XCTAssertTrue(document.applicationPreferences.watchFolder.requiresSourceFolderSelection)
        XCTAssertTrue(document.applicationPreferences.watchFolder.requiresProcessedFolderSelection)
        XCTAssertEqual(
            document.applicationPreferences.watchFolder.submissionPolicy,
            .submitDirectly
        )
        XCTAssertEqual(
            document.profiles[0].clientCertificate?.sha256Fingerprint,
            String(repeating: "AB", count: 32)
        )
        for value in sensitiveValues {
            XCTAssertFalse(json.contains(value), "Export leaked sensitive value: \(value)")
        }
        XCTAssertTrue(json.contains("\"askPasswordAtConnect\""))
        XCTAssertFalse(json.contains("\"password\""))
        XCTAssertFalse(json.contains("\"proxyPassword\""))
        XCTAssertFalse(json.localizedCaseInsensitiveContains("passphrase"))
        XCTAssertFalse(json.localizedCaseInsensitiveContains("persistentReference"))
        XCTAssertFalse(json.localizedCaseInsensitiveContains("privateKey"))
        XCTAssertFalse(json.contains("addDestinationHistory"))
        XCTAssertFalse(json.contains("moveDestinationHistory"))
        XCTAssertFalse(json.contains("bookmark"))
        XCTAssertFalse(json.contains("failureQueue"))
        XCTAssertFalse(json.contains("processingState"))

        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: ascending) as? [String: Any])
        let profiles = try XCTUnwrap(root["profiles"] as? [[String: Any]])
        let certificate = try XCTUnwrap(profiles[0]["clientCertificate"] as? [String: Any])
        XCTAssertEqual(
            Set(certificate.keys),
            Set(["sha256Fingerprint", "notBeforeUnixSeconds", "notAfterUnixSeconds"])
        )
    }

    func testDecodeRejectsUnknownFutureVersionsBeforeImport() throws {
        let data = try XCTUnwrap(
            """
            {
              "schemaIdentifier": "net.pokwer.TransmissionRemoteMac.settings",
              "schemaVersion": 999
            }
            """.data(using: .utf8)
        )

        XCTAssertThrowsError(try SettingsPortabilityService.decodeAndValidate(data)) { error in
            XCTAssertEqual(error as? SettingsPortabilityError, .unsupportedSchemaVersion(999))
        }
    }

    func testDecodeRejectsForbiddenSensitiveFieldsEvenWhenSchemaWouldIgnoreThem() throws {
        let data = try XCTUnwrap(
            """
            {
              "schemaIdentifier": "net.pokwer.TransmissionRemoteMac.settings",
              "schemaVersion": 1,
              "rpcPassword": "SECRET-SENTINEL"
            }
            """.data(using: .utf8)
        )

        XCTAssertThrowsError(try SettingsPortabilityService.decodeAndValidate(data)) { error in
            XCTAssertEqual(error as? SettingsPortabilityError, .forbiddenField("$.rpcPassword"))
        }
    }

    func testDecodeRejectsSecurityScopedBookmarkFields() throws {
        let fields = ["bookmarkData", "sourceBookmarkData", "securityScopedBookmark"]

        for field in fields {
            let data = Data(
                """
                {
                  "schemaIdentifier": "\(SettingsPortabilityDocument.schemaIdentifier)",
                  "schemaVersion": \(SettingsPortabilityDocument.currentSchemaVersion),
                  "\(field)": "PRIVATE-BOOKMARK"
                }
                """.utf8
            )

            XCTAssertThrowsError(try SettingsPortabilityService.decodeAndValidate(data)) { error in
                XCTAssertEqual(error as? SettingsPortabilityError, .forbiddenField("$.\(field)"))
            }
        }
    }

    func testDecodeRejectsWatchFolderFailureStateFields() {
        for field in ["failureQueue", "processingState", "pendingSourceCleanupIdentities"] {
            let data = Data(
                """
                {
                  "schemaIdentifier": "\(SettingsPortabilityDocument.schemaIdentifier)",
                  "schemaVersion": \(SettingsPortabilityDocument.currentSchemaVersion),
                  "\(field)": []
                }
                """.utf8
            )

            XCTAssertThrowsError(try SettingsPortabilityService.decodeAndValidate(data)) { error in
                XCTAssertEqual(error as? SettingsPortabilityError, .forbiddenField("$.\(field)"))
            }
        }
    }

    func testDecodeRejectsIgnoredSecretMaterialInsideNestedObjectsAndArrays() throws {
        let forbiddenFields = [
            "apiToken",
            "apiKey",
            "sharedSecret",
            "pkcs12",
            "pkcs12Data",
            "identityBytes",
            "clientIdentityReference",
            "certificateBytes",
            "certificateData",
            "authorization",
            "cookie",
            "keychainItem",
            "rawKeyReference",
        ]

        for field in forbiddenFields {
            let data = try XCTUnwrap(
                """
                {
                  "schemaIdentifier": "net.pokwer.TransmissionRemoteMac.settings",
                  "schemaVersion": 1,
                  "ignored": {
                    "items": [
                      {
                        "\(field)": "SECRET-SENTINEL"
                      }
                    ]
                  }
                }
                """.data(using: .utf8)
            )

            XCTAssertThrowsError(try SettingsPortabilityService.decodeAndValidate(data), field) { error in
                XCTAssertEqual(
                    error as? SettingsPortabilityError,
                    .forbiddenField("$.ignored.items[0].\(field)")
                )
            }
        }
    }

    func testValidationRejectsDuplicateIdentifiersAndInvalidPreferences() throws {
        let profileID = UUID()
        let profile = try ConnectionProfile.validated(
            id: profileID,
            name: "Remote",
            host: "remote.example"
        )
        var document = try SettingsPortabilityService.makeDocument(
            snapshot: SettingsExportSnapshot(
                profiles: [profile],
                selectedProfileID: profileID,
                applicationPreferences: SettingsExportPreferences()
            )
        )
        document.profiles.append(document.profiles[0])

        XCTAssertThrowsError(try SettingsPortabilityService.validated(document)) { error in
            XCTAssertEqual(error as? SettingsPortabilityError, .duplicateProfileIdentifier(profileID))
        }

        document.profiles.removeLast()
        document.applicationPreferences.torrentTable.visibleColumnIDs = ["torrent.unknown"]
        XCTAssertThrowsError(try SettingsPortabilityService.validated(document)) { error in
            guard let portabilityError = error as? SettingsPortabilityError,
                  case .invalidApplicationPreferences = portabilityError else {
                return XCTFail("Expected invalid application preferences, got \(error)")
            }
        }

        document.applicationPreferences.torrentTable.visibleColumnIDs = [TorrentTableColumnID.name.rawValue]
        document.applicationPreferences.workspace.mainWindow = MainWindowPlacement(
            frame: WorkspaceRect(x: 10, y: 10, width: 0, height: -20),
            displayIdentifier: nil
        )
        XCTAssertThrowsError(try SettingsPortabilityService.validated(document)) { error in
            guard let portabilityError = error as? SettingsPortabilityError,
                  case .invalidApplicationPreferences = portabilityError else {
                return XCTFail("Expected invalid application preferences, got \(error)")
            }
        }
    }
}
