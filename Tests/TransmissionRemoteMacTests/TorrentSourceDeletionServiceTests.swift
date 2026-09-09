// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation
import XCTest
@testable import TransmissionRemoteMac

final class TorrentSourceDeletionServiceTests: XCTestCase {
    func testDefaultPolicyNeverDeletesAConfirmedLocalTorrentSource() {
        XCTAssertEqual(
            TorrentSourceDeletionService.decision(
                policy: .never,
                source: "/Users/example/Downloads/release.torrent",
                addOutcome: .added
            ),
            .keepSource
        )
    }

    func testOptInPolicyDeletesOnlyLocalTorrentFilesAfterConfirmedAdd() {
        let path = "/Users/example/Downloads/release.torrent"
        let fileURL = URL(fileURLWithPath: path).standardizedFileURL

        XCTAssertEqual(
            TorrentSourceDeletionService.decision(
                policy: .afterSuccessfulNonDuplicateAdd,
                source: path,
                addOutcome: .added
            ),
            .deleteLocalTorrentFile(fileURL)
        )
        XCTAssertEqual(
            TorrentSourceDeletionService.decision(
                policy: .afterSuccessfulNonDuplicateAdd,
                source: "file:///Users/example/Downloads/RELEASE.TORRENT",
                addOutcome: .added
            ),
            .deleteLocalTorrentFile(
                URL(fileURLWithPath: "/Users/example/Downloads/RELEASE.TORRENT")
                    .standardizedFileURL
            )
        )
    }

    func testDuplicateAndFailureNeverDeleteLocalTorrentFiles() {
        for outcome in [ConfirmedTorrentAddOutcome.duplicate, .failed] {
            XCTAssertEqual(
                TorrentSourceDeletionService.decision(
                    policy: .afterSuccessfulNonDuplicateAdd,
                    source: "/Users/example/Downloads/release.torrent",
                    addOutcome: outcome
                ),
                .keepSource
            )
        }
    }

    func testURLsMagnetsHashesAndNonTorrentFilesNeverProduceDeletion() {
        let sources = [
            "https://example.com/release.torrent",
            "magnet:?xt=urn:btih:abc",
            "0123456789abcdef0123456789abcdef01234567",
            "/Users/example/Downloads/release.zip",
            #"C:\Downloads\release.torrent"#,
            "file://server/share/release.torrent"
        ]

        for source in sources {
            XCTAssertEqual(
                TorrentSourceDeletionService.decision(
                    policy: .afterSuccessfulNonDuplicateAdd,
                    source: source,
                    addOutcome: .added
                ),
                .keepSource,
                source
            )
        }
    }

    func testExecutorDeletesOnlyAConfirmedRegularLocalTorrentFile() {
        let fileManager = TorrentSourceDeletionFileManagerStub(fileType: .typeRegular)
        let service = TorrentSourceDeletionService(fileCleanup: fileManager)
        let fileURL = URL(fileURLWithPath: "/tmp/release.torrent")

        XCTAssertEqual(
            service.deleteIfAllowed(
                policy: .afterSuccessfulNonDuplicateAdd,
                sourceFileURL: fileURL,
                sourceIdentity: fileManager.stableIdentity,
                addOutcome: .added
            ),
            .deleted(fileURL.standardizedFileURL)
        )
        XCTAssertEqual(fileManager.removedURLs, [fileURL.standardizedFileURL])
    }

    func testExecutorRejectsSymlinksAndSurfacesRemovalFailures() {
        let symlinkManager = TorrentSourceDeletionFileManagerStub(fileType: .typeSymbolicLink)
        let service = TorrentSourceDeletionService(fileCleanup: symlinkManager)
        let fileURL = URL(fileURLWithPath: "/tmp/release.torrent")

        guard case .failed = service.deleteIfAllowed(
            policy: .afterSuccessfulNonDuplicateAdd,
            sourceFileURL: fileURL,
            sourceIdentity: symlinkManager.stableIdentity,
            addOutcome: .added
        ) else {
            return XCTFail("Expected a non-regular source failure")
        }
        XCTAssertTrue(symlinkManager.removedURLs.isEmpty)

        let failingManager = TorrentSourceDeletionFileManagerStub(
            fileType: .typeRegular,
            removalError: TorrentSourceDeletionTestError.removeFailed
        )
        guard case .failed(let message) = TorrentSourceDeletionService(
            fileCleanup: failingManager
        ).deleteIfAllowed(
            policy: .afterSuccessfulNonDuplicateAdd,
            sourceFileURL: fileURL,
            sourceIdentity: failingManager.stableIdentity,
            addOutcome: .added
        ) else {
            return XCTFail("Expected a visible removal failure")
        }
        XCTAssertEqual(message, TorrentSourceDeletionTestError.removeFailed.localizedDescription)
    }

    func testPreparedDeletionCarriesThePreRPCIdentityIntoCleanup() throws {
        let capturedIdentity = RaceResistantFileIdentity(
            deviceID: 41,
            fileID: 42,
            generation: 43
        )
        let fileManager = TorrentSourceDeletionFileManagerStub(
            fileType: .typeRegular,
            stableIdentity: capturedIdentity
        )
        let service = TorrentSourceDeletionService(fileCleanup: fileManager)
        let fileURL = URL(fileURLWithPath: "/tmp/release.torrent").standardizedFileURL

        let preparedDeletion = try XCTUnwrap(
            service.prepareDeletionIfNeeded(
                policy: .afterSuccessfulNonDuplicateAdd,
                sourceFileURL: fileURL,
                sourceIdentity: capturedIdentity
            )
        )

        XCTAssertTrue(fileManager.identityCaptureURLs.isEmpty)
        XCTAssertEqual(
            service.deleteIfAllowed(
                preparedDeletion: preparedDeletion,
                addOutcome: .added
            ),
            .deleted(fileURL)
        )
        XCTAssertEqual(fileManager.removalIdentities, [capturedIdentity])
    }

    func testReplacementAfterDescriptorReadIsRetainedDuringConfirmedCleanup() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directoryURL.appendingPathComponent("release.torrent")
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let cleanup = DarwinRaceResistantFileCleanup()
        try Data("original".utf8).write(to: fileURL)
        let snapshot = try cleanup.readRegularFile(at: fileURL)
        let service = TorrentSourceDeletionService(fileCleanup: cleanup)
        let preparedDeletion = try XCTUnwrap(service.prepareDeletionIfNeeded(
            policy: .afterSuccessfulNonDuplicateAdd,
            sourceFileURL: fileURL,
            sourceIdentity: snapshot.identity
        ))
        try FileManager.default.removeItem(at: fileURL)
        try Data("replacement".utf8).write(to: fileURL)

        guard case .failed = service.deleteIfAllowed(
            preparedDeletion: preparedDeletion,
            addOutcome: .added
        ) else {
            return XCTFail("A replacement source must not be deleted.")
        }
        XCTAssertEqual(try Data(contentsOf: fileURL), Data("replacement".utf8))
    }

    func testPreparedDeletionKeepsSourceForNonAddedOutcomes() throws {
        let fileManager = TorrentSourceDeletionFileManagerStub(fileType: .typeRegular)
        let service = TorrentSourceDeletionService(fileCleanup: fileManager)
        let preparedDeletion = try XCTUnwrap(
            service.prepareDeletionIfNeeded(
                policy: .afterSuccessfulNonDuplicateAdd,
                sourceFileURL: URL(fileURLWithPath: "/tmp/release.torrent"),
                sourceIdentity: fileManager.stableIdentity
            )
        )

        for outcome in [ConfirmedTorrentAddOutcome.duplicate, .failed] {
            XCTAssertEqual(
                service.deleteIfAllowed(
                    preparedDeletion: preparedDeletion,
                    addOutcome: outcome
                ),
                .kept
            )
        }
        XCTAssertTrue(fileManager.removedURLs.isEmpty)
    }
}

private final class TorrentSourceDeletionFileManagerStub: RaceResistantFileCleaning, @unchecked Sendable {
    let fileType: FileAttributeType
    let removalError: Error?
    let stableIdentity: RaceResistantFileIdentity
    private(set) var identityCaptureURLs: [URL] = []
    private(set) var removedURLs: [URL] = []
    private(set) var removalIdentities: [RaceResistantFileIdentity] = []

    init(
        fileType: FileAttributeType,
        removalError: Error? = nil,
        stableIdentity: RaceResistantFileIdentity = RaceResistantFileIdentity(
            deviceID: 1,
            fileID: 2,
            generation: 3
        )
    ) {
        self.fileType = fileType
        self.removalError = removalError
        self.stableIdentity = stableIdentity
    }

    func stableIdentityOfRegularFile(at fileURL: URL) throws -> RaceResistantFileIdentity {
        identityCaptureURLs.append(fileURL)
        guard fileType == .typeRegular else {
            throw RaceResistantFileCleanupError.sourceIsNotARegularFile
        }
        return stableIdentity
    }

    func removeRegularFile(
        at fileURL: URL,
        matching identity: RaceResistantFileIdentity
    ) throws {
        guard fileType == .typeRegular else {
            throw RaceResistantFileCleanupError.sourceIsNotARegularFile
        }
        if let removalError { throw removalError }
        removedURLs.append(fileURL)
        removalIdentities.append(identity)
    }

    func moveRegularFile(
        at sourceURL: URL,
        to destinationURL: URL,
        matching identity: RaceResistantFileIdentity
    ) throws {
        throw TorrentSourceDeletionTestError.unexpectedMove
    }
}

private enum TorrentSourceDeletionTestError: LocalizedError {
    case removeFailed
    case unexpectedMove

    var errorDescription: String? {
        switch self {
        case .removeFailed:
            "Removal failed"
        case .unexpectedMove:
            "Unexpected move"
        }
    }
}
