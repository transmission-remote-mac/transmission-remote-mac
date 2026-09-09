// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation
import XCTest
@testable import TransmissionRemoteMac

final class WatchFolderSourceCleanupTests: XCTestCase {
    func testDeleteAndMoveUseTheOriginalScanIdentity() throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.rootURL) }
        try Data("torrent".utf8).write(to: context.sourceURL)
        let identity = RaceResistantFileIdentity(
            deviceID: 11,
            fileID: 12,
            generation: 13
        )
        let recorder = WatchFolderCleanupRecordingFileService(identity: identity)
        let cleanup = WatchFolderSourceCleanup(fileCleanup: recorder)

        try cleanup.apply(
            disposition: .delete,
            to: context.sourceURL,
            processedFolderURL: nil,
            expectedIdentity: identity.rawValue
        ).get()
        try cleanup.apply(
            disposition: .move(destinationBookmarkData: Data()),
            to: context.sourceURL,
            processedFolderURL: context.processedURL,
            expectedIdentity: identity.rawValue
        ).get()

        XCTAssertEqual(recorder.removals.count, 1)
        XCTAssertEqual(recorder.removals.first?.0, context.sourceURL)
        XCTAssertEqual(recorder.removals.first?.1, identity)
        XCTAssertEqual(recorder.moves.count, 1)
        XCTAssertEqual(recorder.moves.first?.0, context.sourceURL)
        XCTAssertEqual(
            recorder.moves.first?.1,
            context.processedURL.appendingPathComponent("source.torrent")
        )
        XCTAssertEqual(recorder.moves.first?.2, identity)
        XCTAssertTrue(recorder.identityCaptures.isEmpty)
    }

    func testReplacementAtSourcePathIsRetainedForDeleteAndMove() throws {
        for disposition in [
            WatchFolderSourceDisposition.delete,
            .move(destinationBookmarkData: Data())
        ] {
            let context = try makeContext()
            defer { try? FileManager.default.removeItem(at: context.rootURL) }
            let fileCleanup = DarwinRaceResistantFileCleanup()
            try Data("original".utf8).write(to: context.sourceURL)
            let scanIdentity = try fileCleanup.stableIdentityOfRegularFile(
                at: context.sourceURL
            )
            try FileManager.default.removeItem(at: context.sourceURL)
            try Data("replacement".utf8).write(to: context.sourceURL)

            XCTAssertThrowsError(try WatchFolderSourceCleanup().apply(
                disposition: disposition,
                to: context.sourceURL,
                processedFolderURL: context.processedURL,
                expectedIdentity: scanIdentity.rawValue
            ).get())
            XCTAssertEqual(
                try Data(contentsOf: context.sourceURL),
                Data("replacement".utf8)
            )
            XCTAssertTrue(
                try FileManager.default.contentsOfDirectory(atPath: context.processedURL.path).isEmpty
            )
        }
    }

    func testSymlinkSourceAndTargetAreUntouched() throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.rootURL) }
        let targetURL = context.rootURL.appendingPathComponent("target.torrent")
        let originalURL = context.rootURL.appendingPathComponent("original.torrent")
        let fileCleanup = DarwinRaceResistantFileCleanup()
        try Data("original".utf8).write(to: originalURL)
        let scanIdentity = try fileCleanup.stableIdentityOfRegularFile(at: originalURL)
        try Data("target".utf8).write(to: targetURL)
        try FileManager.default.createSymbolicLink(
            at: context.sourceURL,
            withDestinationURL: targetURL
        )

        XCTAssertThrowsError(try WatchFolderSourceCleanup().apply(
            disposition: .delete,
            to: context.sourceURL,
            processedFolderURL: nil,
            expectedIdentity: scanIdentity.rawValue
        ).get())
        XCTAssertEqual(try Data(contentsOf: targetURL), Data("target".utf8))
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: context.sourceURL.path),
            targetURL.path
        )
    }

    private func makeContext() throws -> (
        rootURL: URL,
        sourceURL: URL,
        processedURL: URL
    ) {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let processedURL = rootURL.appendingPathComponent("processed", isDirectory: true)
        try FileManager.default.createDirectory(
            at: processedURL,
            withIntermediateDirectories: true
        )
        return (
            rootURL,
            rootURL.appendingPathComponent("source.torrent"),
            processedURL
        )
    }
}

private final class WatchFolderCleanupRecordingFileService: RaceResistantFileCleaning,
    @unchecked Sendable {
    private let identity: RaceResistantFileIdentity
    private(set) var identityCaptures: [URL] = []
    private(set) var removals: [(URL, RaceResistantFileIdentity)] = []
    private(set) var moves: [(URL, URL, RaceResistantFileIdentity)] = []

    init(identity: RaceResistantFileIdentity) {
        self.identity = identity
    }

    func stableIdentityOfRegularFile(at fileURL: URL) throws -> RaceResistantFileIdentity {
        identityCaptures.append(fileURL)
        return identity
    }

    func removeRegularFile(
        at fileURL: URL,
        matching identity: RaceResistantFileIdentity
    ) throws {
        removals.append((fileURL, identity))
    }

    func moveRegularFile(
        at sourceURL: URL,
        to destinationURL: URL,
        matching identity: RaceResistantFileIdentity
    ) throws {
        moves.append((sourceURL, destinationURL, identity))
    }
}
