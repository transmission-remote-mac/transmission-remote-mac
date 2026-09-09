// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation
import XCTest
@testable import TransmissionRemoteMac

final class ConnectionProfileTransferPreferencesTests: XCTestCase {
    func testProfileDraftAndValidationPreserveTransferPreferences() throws {
        let destinationRules = try AddTorrentDestinationRulesSnapshot(
            defaultDestination: "/downloads/default",
            rules: [
                try destinationRule(
                    label: "Video",
                    destination: "/downloads/video",
                    extensions: ["mkv"]
                )
            ]
        )
        let preferences = ProfileTransferPreferences(
            downloadSpeedPresetsKBps: [125, 500],
            uploadSpeedPresetsKBps: [25, 75],
            destinationHistoryLimit: 3,
            addDestinationHistory: ["/downloads", "/incoming"],
            moveDestinationHistory: ["/archive"],
            addDestinationRules: destinationRules
        )
        let profile = try ConnectionProfile.validated(
            name: "Remote",
            host: "transmission.example",
            transferPreferences: preferences
        )

        let draft = ConnectionProfileDraft(profile: profile)
        let validated = try draft.validatedProfile()

        XCTAssertEqual(draft.transferPreferences, preferences)
        XCTAssertEqual(validated.transferPreferences, preferences)
    }

    func testStoreRoundTripsDistinctTransferPreferencesPerProfile() throws {
        let fileURL = temporaryFileURL()
        let store = ConnectionProfileStore(
            fileURL: fileURL,
            passwordStore: NoOpConnectionPasswordStore()
        )
        let firstRule = try destinationRule(
            label: "First video",
            destination: "/first//video/../tv ",
            extensions: ["mkv"]
        )
        let secondRule = try destinationRule(
            label: "Second Linux",
            destination: "/second/linux",
            nameTokens: ["linux"]
        )
        let firstPreferences = ProfileTransferPreferences(
            downloadSpeedPresetsKBps: [100, 500],
            uploadSpeedPresetsKBps: [25],
            destinationHistoryLimit: 2,
            addDestinationHistory: ["/first/add"],
            moveDestinationHistory: ["/first/move"],
            addDestinationRules: try AddTorrentDestinationRulesSnapshot(
                defaultDestination: "/first/default ",
                rules: [firstRule]
            )
        )
        let secondPreferences = ProfileTransferPreferences(
            downloadSpeedPresetsKBps: [1_000],
            uploadSpeedPresetsKBps: [100, 250],
            destinationHistoryLimit: 4,
            addDestinationHistory: ["/second/add"],
            moveDestinationHistory: ["/second/move"],
            addDestinationRules: try AddTorrentDestinationRulesSnapshot(
                defaultDestination: nil,
                rules: [secondRule]
            )
        )
        let first = try ConnectionProfile.validated(
            name: "First",
            host: "first.example",
            transferPreferences: firstPreferences
        )
        let second = try ConnectionProfile.validated(
            name: "Second",
            host: "second.example",
            transferPreferences: secondPreferences
        )
        let collection = try ConnectionProfileCollection(
            profiles: [first, second],
            selectedProfileID: second.id
        )

        try store.save(collection)
        let loaded = try store.load()
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
        )
        let storedProfiles = try XCTUnwrap(root["profiles"] as? [[String: Any]])

        XCTAssertEqual(
            loaded.profiles.first { $0.id == first.id }?.transferPreferences,
            firstPreferences
        )
        XCTAssertEqual(
            loaded.profiles.first { $0.id == second.id }?.transferPreferences,
            secondPreferences
        )
        XCTAssertEqual(
            loaded.profiles.first { $0.id == first.id }?
                .transferPreferences.addDestinationRules.rules.map(\.id),
            [firstRule.id]
        )
        XCTAssertEqual(
            loaded.profiles.first { $0.id == second.id }?
                .transferPreferences.addDestinationRules.rules.map(\.id),
            [secondRule.id]
        )
        XCTAssertEqual(
            loaded.profiles.first { $0.id == first.id }?
                .transferPreferences.addDestinationRules.rules.map(\.destination),
            ["/first//video/../tv "]
        )
        XCTAssertNil(root["transferPreferences"])
        XCTAssertTrue(storedProfiles.allSatisfy { $0["transferPreferences"] is [String: Any] })
    }

    func testStoreMigratesMissingTransferPreferencesToCanonicalDefaults() throws {
        let fileURL = temporaryFileURL()
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let profileID = UUID()
        try """
        {
          "profiles" : [
            {
              "autoReconnect" : false,
              "askPasswordAtConnect" : false,
              "connectOnLaunch" : true,
              "host" : "transmission.example",
              "id" : "\(profileID.uuidString)",
              "name" : "Remote",
              "pathMappings" : [],
              "port" : 9091,
              "proxySettings" : {
                "authenticationEnabled" : false,
                "host" : "",
                "port" : 0,
                "transport" : "direct",
                "username" : ""
              },
              "requestTimeoutSeconds" : 30,
              "rpcPath" : "/transmission/rpc",
              "scheme" : "http",
              "username" : ""
            }
          ],
          "selectedProfileID" : "\(profileID.uuidString)"
        }
        """.write(to: fileURL, atomically: true, encoding: .utf8)
        let store = ConnectionProfileStore(
            fileURL: fileURL,
            passwordStore: NoOpConnectionPasswordStore()
        )

        let loaded = try store.load()
        let migratedRoot = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
        )
        let migratedProfiles = try XCTUnwrap(migratedRoot["profiles"] as? [[String: Any]])
        let storedPreferences = try XCTUnwrap(
            migratedProfiles.first?["transferPreferences"] as? [String: Any]
        )

        XCTAssertEqual(loaded.selectedProfile.transferPreferences, .defaults)
        XCTAssertEqual(
            storedPreferences["schemaVersion"] as? Int,
            ProfileTransferPreferences.currentSchemaVersion
        )
        XCTAssertEqual(
            storedPreferences["destinationHistoryLimit"] as? Int,
            ProfileTransferPreferences.defaultDestinationHistoryLimit
        )
        let storedRules = try XCTUnwrap(
            storedPreferences["addDestinationRules"] as? [String: Any]
        )
        XCTAssertEqual((storedRules["rules"] as? [Any])?.count, 0)
        XCTAssertNil(storedRules["defaultDestination"])
    }

    func testMalformedAndFutureProfilePreferencesFallBackWithoutBreakingProfileDecode() throws {
        let malformed = try profileJSON(transferPreferencesJSON: #""invalid""#)
        let future = try profileJSON(
            transferPreferencesJSON: #"{"schemaVersion":99,"downloadSpeedPresetsKBps":[1]}"#
        )

        XCTAssertEqual(
            try JSONDecoder().decode(ConnectionProfile.self, from: malformed).transferPreferences,
            .defaults
        )
        XCTAssertEqual(
            try JSONDecoder().decode(ConnectionProfile.self, from: future).transferPreferences,
            .defaults
        )
    }

    private func temporaryFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("profiles.json")
    }

    private func profileJSON(transferPreferencesJSON: String) throws -> Data {
        try XCTUnwrap(
            """
            {
              "id" : "\(UUID().uuidString)",
              "name" : "Remote",
              "scheme" : "http",
              "host" : "transmission.example",
              "port" : 9091,
              "rpcPath" : "/transmission/rpc",
              "username" : "",
              "transferPreferences" : \(transferPreferencesJSON)
            }
            """.data(using: .utf8)
        )
    }

    private func destinationRule(
        label: String,
        destination: String,
        extensions: [String] = [],
        nameTokens: [String] = []
    ) throws -> AddTorrentDestinationRule {
        try AddTorrentDestinationRule(
            label: label,
            destination: destination,
            extensions: extensions,
            nameTokens: nameTokens
        )
    }
}

private struct NoOpConnectionPasswordStore: ConnectionPasswordStoring {
    func password(for profileID: ConnectionProfile.ID) throws -> String? { nil }
    func setPassword(_ password: String, for profileID: ConnectionProfile.ID) throws {}
    func removePassword(for profileID: ConnectionProfile.ID) throws {}
}
