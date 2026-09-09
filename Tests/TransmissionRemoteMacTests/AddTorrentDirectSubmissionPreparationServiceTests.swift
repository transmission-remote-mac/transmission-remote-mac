// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation
import XCTest
@testable import TransmissionRemoteMac

final class AddTorrentDirectSubmissionPreparationServiceTests: XCTestCase {
    func testDispositionPromptsByDefaultAndKeepsToolbarAddInteractive() {
        let policy = AddTorrentSubmissionDispositionPolicy()

        XCTAssertEqual(
            policy.disposition(for: .remote, promptsForDownloadOptions: true),
            .presentOptions
        )
        XCTAssertEqual(
            policy.disposition(for: .localFile, promptsForDownloadOptions: false),
            .submitDirectly
        )
        XCTAssertEqual(
            policy.disposition(for: .manual, promptsForDownloadOptions: false),
            .presentOptions
        )
    }

    func testRemotePreparationValidatesSourceAndResolvesExplicitOverrides() async throws {
        let outcome = try await AddTorrentDirectSubmissionPreparationService().prepare(
            AddTorrentDirectSubmissionPreparationRequest(
                source: .remote(
                    "  magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567  "
                ),
                initialOptions: AddTorrentInitialOptions(
                    startIntent: .start,
                    peerLimit: .daemonDefault
                ),
                savedDefaults: AddTorrentDefaults(
                    startIntent: .paused,
                    priority: .normal,
                    unwantedFiles: .daemonDefault,
                    peerLimit: 80
                ),
                explicitDownloadDirectory: "   "
            )
        )

        guard case .ready(let preparation) = outcome,
              case .remote(let source) = preparation.payload else {
            return XCTFail("Expected a direct remote submission")
        }
        XCTAssertEqual(
            source,
            "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567"
        )
        XCTAssertFalse(preparation.startPaused)
        XCTAssertNil(preparation.peerLimit)
        XCTAssertNil(preparation.downloadDirectory)
    }

    func testRemotePreparationRequiresInteractionForSavedMetadataDependentChoices() async throws {
        let outcome = try await AddTorrentDirectSubmissionPreparationService().prepare(
            AddTorrentDirectSubmissionPreparationRequest(
                source: .remote(
                    "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567"
                ),
                initialOptions: .unspecified,
                savedDefaults: AddTorrentDefaults(
                    startIntent: .start,
                    priority: .high,
                    unwantedFiles: .daemonDefault,
                    peerLimit: nil
                ),
                explicitDownloadDirectory: nil
            )
        )

        guard case .requiresInteraction(let message) = outcome else {
            return XCTFail("Expected saved file choices to keep the remote source interactive")
        }
        XCTAssertTrue(message.contains("metadata"))
    }

    func testRemotePreparationRequiresInteractionForExplicitMetadataDependentChoices() async throws {
        let outcome = try await AddTorrentDirectSubmissionPreparationService().prepare(
            AddTorrentDirectSubmissionPreparationRequest(
                source: .remote("https://example.com/release.torrent"),
                initialOptions: AddTorrentInitialOptions(
                    unwantedFiles: .allUnwantedWhenFileListKnown
                ),
                savedDefaults: AddTorrentDefaults(
                    startIntent: .start,
                    priority: .normal,
                    unwantedFiles: .daemonDefault,
                    peerLimit: nil
                ),
                explicitDownloadDirectory: nil
            )
        )

        guard case .requiresInteraction(let message) = outcome else {
            return XCTFail("Expected explicit file choices to keep the remote source interactive")
        }
        XCTAssertTrue(message.contains("metadata"))
    }

    func testRemotePreparationNormalizesAnExplicitDestination() async throws {
        let outcome = try await AddTorrentDirectSubmissionPreparationService().prepare(
            AddTorrentDirectSubmissionPreparationRequest(
                source: .remote("https://example.com/release.torrent"),
                initialOptions: .unspecified,
                savedDefaults: AddTorrentDefaults(
                    startIntent: .start,
                    priority: .normal,
                    unwantedFiles: .daemonDefault,
                    peerLimit: nil
                ),
                explicitDownloadDirectory: "  /downloads/direct  "
            )
        )

        guard case .ready(let preparation) = outcome else {
            return XCTFail("Expected the explicit destination to remain eligible")
        }
        XCTAssertEqual(preparation.downloadDirectory, "/downloads/direct")
    }

    func testLocalPreparationAppliesSavedFileChoicesOnlyAfterMetadataIsKnown() async throws {
        let fileURL = try temporaryTorrentFile(contents: validTorrentData)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let outcome = try await AddTorrentDirectSubmissionPreparationService().prepare(
            AddTorrentDirectSubmissionPreparationRequest(
                source: .localFile(fileURL, expectedStableIdentity: nil),
                initialOptions: .unspecified,
                savedDefaults: AddTorrentDefaults(
                    startIntent: .paused,
                    priority: .high,
                    unwantedFiles: .allUnwantedWhenFileListKnown,
                    peerLimit: 42
                ),
                explicitDownloadDirectory: nil
            )
        )

        guard case .ready(let preparation) = outcome,
              case .localFile(
                let snapshot,
                let sourceFileURL,
                let selection,
                let trackerURLs
              ) = preparation.payload else {
            return XCTFail("Expected a direct local-file submission")
        }
        XCTAssertEqual(snapshot.data, validTorrentData)
        XCTAssertEqual(sourceFileURL, fileURL.standardizedFileURL)
        XCTAssertEqual(selection?.filesWanted, [])
        XCTAssertEqual(selection?.filesUnwanted, [0])
        XCTAssertEqual(selection?.priorityHigh, [0])
        XCTAssertEqual(selection?.priorityNormal, [])
        XCTAssertEqual(selection?.priorityLow, [])
        XCTAssertEqual(trackerURLs, ["http://tracker.example/announce"])
        XCTAssertTrue(preparation.startPaused)
        XCTAssertEqual(preparation.peerLimit, 42)
    }

    func testUnreadableMetadataRequiresInteractionWhenSavedFileChoicesNeedIt() async throws {
        let fileURL = try temporaryTorrentFile(contents: Data("not-bencode".utf8))
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let outcome = try await AddTorrentDirectSubmissionPreparationService().prepare(
            AddTorrentDirectSubmissionPreparationRequest(
                source: .localFile(fileURL, expectedStableIdentity: nil),
                initialOptions: .unspecified,
                savedDefaults: AddTorrentDefaults(
                    startIntent: .start,
                    priority: .high,
                    unwantedFiles: .daemonDefault,
                    peerLimit: nil
                ),
                explicitDownloadDirectory: nil
            )
        )

        guard case .requiresInteraction(let message) = outcome else {
            return XCTFail("Expected metadata-dependent choices to remain interactive")
        }
        XCTAssertFalse(message.isEmpty)
    }

    private var validTorrentData: Data {
        Data(
            "d8:announce31:http://tracker.example/announce4:infod6:lengthi12345e4:name10:sample.iso12:piece lengthi16384e6:pieces0:ee"
                .utf8
        )
    }

    private func temporaryTorrentFile(contents: Data) throws -> URL {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("torrent")
        try contents.write(to: fileURL)
        return fileURL
    }
}
