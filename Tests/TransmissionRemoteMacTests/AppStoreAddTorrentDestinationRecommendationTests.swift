// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation
import XCTest
@testable import TransmissionRemoteMac

@MainActor
final class AppStoreAddTorrentDestinationRecommendationTests: XCTestCase {
    override func tearDown() {
        AppStoreMockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testRecommendationUsesThePendingRequestsFrozenProfileRules() async throws {
        AppStoreMockURLProtocol.requestHandler = { request in
            appStoreRPCResponse(for: try request.decodedActionBody().method)
        }
        let firstRules = try AddTorrentDestinationRulesSnapshot(
            defaultDestination: "/first/default",
            rules: [
                try AddTorrentDestinationRule(
                    label: "First video",
                    destination: "/first/video",
                    extensions: ["mkv"]
                )
            ]
        )
        let secondRules = try AddTorrentDestinationRulesSnapshot(
            defaultDestination: "/second/default",
            rules: []
        )
        let profiles = try makeProfiles(firstRules: firstRules, secondRules: secondRules)
        let store = try makeStore(profiles: profiles)
        await store.connect()
        let ownerID = UUID()
        store.registerAddTorrentPresentationOwner(ownerID)
        store.requestAddTorrent(fileURL: URL(fileURLWithPath: "/tmp/video.torrent"))
        let request = try XCTUnwrap(store.presentedAddTorrent(for: ownerID))

        let result = await store.addTorrentDestinationRecommendation(
            requestID: request.id,
            presentationOwnerID: ownerID,
            metainfoFiles: [
                TorrentMetainfoFile(pathComponents: ["show.mkv"], length: 42)
            ]
        )

        XCTAssertEqual(
            result,
            .recommendation(AddTorrentDestinationRecommendation(
                destination: "/first/video",
                provenance: .matchingRule(
                    id: firstRules.rules[0].id,
                    label: "First video",
                    declarationIndex: 0,
                    matchedFileCount: 1,
                    matchedBytes: 42
                )
            ))
        )
        XCTAssertEqual(request.profileID, profiles.selectedProfileID)
    }

    func testMismatchedServiceOwnershipCannotPublishARecommendation() async throws {
        AppStoreMockURLProtocol.requestHandler = { request in
            appStoreRPCResponse(for: try request.decodedActionBody().method)
        }
        let profiles = try makeProfiles(
            firstRules: try AddTorrentDestinationRulesSnapshot(
                defaultDestination: "/first/default",
                rules: []
            ),
            secondRules: .empty
        )
        let service = MismatchedDestinationRecommendationService()
        let store = try makeStore(profiles: profiles, service: service)
        await store.connect()
        let ownerID = UUID()
        store.registerAddTorrentPresentationOwner(ownerID)
        store.requestAddTorrent()
        let request = try XCTUnwrap(store.presentedAddTorrent(for: ownerID))

        let result = await store.addTorrentDestinationRecommendation(
            requestID: request.id,
            presentationOwnerID: ownerID,
            metainfoFiles: []
        )

        XCTAssertNil(result)
    }

    private func makeProfiles(
        firstRules: AddTorrentDestinationRulesSnapshot,
        secondRules: AddTorrentDestinationRulesSnapshot
    ) throws -> ConnectionProfileCollection {
        let first = try ConnectionProfile.validated(
            name: "First",
            host: "first.example",
            transferPreferences: ProfileTransferPreferences(
                addDestinationRules: firstRules
            )
        )
        let second = try ConnectionProfile.validated(
            name: "Second",
            host: "second.example",
            transferPreferences: ProfileTransferPreferences(
                addDestinationRules: secondRules
            )
        )
        return try ConnectionProfileCollection(
            profiles: [first, second],
            selectedProfileID: first.id
        )
    }

    private func makeStore(
        profiles: ConnectionProfileCollection,
        service: any AddTorrentDestinationRecommendationServicing = AddTorrentDestinationRecommendationService()
    ) throws -> AppStore {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directoryURL.appendingPathComponent("profiles.json")
        let profileStore = ConnectionProfileStore(
            fileURL: fileURL,
            passwordStore: AddDestinationRecommendationPasswordStore()
        )
        try profileStore.save(profiles)
        let defaultsSuite = "AppStoreAddTorrentDestinationRecommendationTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directoryURL)
            defaults.removePersistentDomain(forName: defaultsSuite)
        }
        let session = makeAppStoreMockSession()
        return AppStore(
            profileStore: profileStore,
            userDefaults: defaults,
            downloadCompletionNotifier: AddDestinationRecommendationNotifier(),
            addTorrentDestinationRecommendationService: service,
            clientFactory: { profile in
                TransmissionRPCClient(profile: profile, urlSession: session)
            }
        )
    }
}

private struct MismatchedDestinationRecommendationService:
    AddTorrentDestinationRecommendationServicing {
    func evaluate(
        _ request: AddTorrentDestinationRecommendationServiceRequest
    ) async -> AddTorrentDestinationRecommendationServiceResponse? {
        AddTorrentDestinationRecommendationServiceResponse(
            ownership: AddTorrentDestinationRecommendationOwnership(
                requestID: request.ownership.requestID,
                presentationOwnerID: request.ownership.presentationOwnerID,
                profileID: UUID(),
                connectionToken: request.ownership.connectionToken
            ),
            evaluation: .recommendation(AddTorrentDestinationRecommendation(
                destination: "/wrong-profile",
                provenance: .profileDefault
            ))
        )
    }
}

private struct AddDestinationRecommendationPasswordStore: ConnectionPasswordStoring {
    func password(for profileID: ConnectionProfile.ID) throws -> String? { nil }
    func setPassword(_ password: String, for profileID: ConnectionProfile.ID) throws {}
    func removePassword(for profileID: ConnectionProfile.ID) throws {}
}

private struct AddDestinationRecommendationNotifier: DownloadCompletionNotifying {
    func notifyDownloadCompleted(torrentName: String) {}
}
