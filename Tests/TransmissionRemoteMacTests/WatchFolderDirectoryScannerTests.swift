// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation
import XCTest
@testable import TransmissionRemoteMac

final class WatchFolderDirectoryScannerTests: XCTestCase {
    func testIrrelevantEntriesNeverAcquireSecureIdentity() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["notes.txt", ".hidden.torrent", "partial.part.torrent", "~backup.torrent", "download.torrent.tmp"] {
            try Data().write(to: directory.appendingPathComponent(name))
        }
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("folder.torrent"), withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("link.torrent"),
            withDestinationURL: directory.appendingPathComponent("notes.txt")
        )
        var hidden = directory.appendingPathComponent("finder-hidden.torrent")
        try Data().write(to: hidden)
        var values = URLResourceValues()
        values.isHidden = true
        try hidden.setResourceValues(values)
        let reader = IdentityReadProbe()
        XCTAssertTrue(try WatchFolderDirectoryScanner.scan(at: directory, fileCleanup: reader).isEmpty)
        XCTAssertEqual(reader.names, [])
    }

    func testRealCandidatesStillAcquireRaceResistantIdentityOnEveryScan() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let candidate = directory.appendingPathComponent("valid.TORRENT")
        try Data("metainfo".utf8).write(to: candidate)
        let reader = IdentityReadProbe()
        let first = try WatchFolderDirectoryScanner.scan(at: directory, fileCleanup: reader)
        let second = try WatchFolderDirectoryScanner.scan(at: directory, fileCleanup: reader)
        XCTAssertEqual(first.map(\.entry), second.map(\.entry))
        XCTAssertEqual(first.map { $0.url.resolvingSymlinksInPath() }, [candidate.resolvingSymlinksInPath()])
        XCTAssertEqual(reader.names, ["valid.TORRENT", "valid.TORRENT"])
        XCTAssertTrue(try XCTUnwrap(first.first?.entry).isEligibleTorrentFile)
    }
}

private final class IdentityReadProbe: RaceResistantFileCleaning, @unchecked Sendable {
    private let lock = NSLock()
    private var readNames: [String] = []
    var names: [String] { lock.lock(); defer { lock.unlock() }; return readNames }
    func stableIdentityOfRegularFile(at fileURL: URL) throws -> RaceResistantFileIdentity {
        lock.lock()
        readNames.append(fileURL.lastPathComponent)
        lock.unlock()
        return try DarwinRaceResistantFileCleanup().stableIdentityOfRegularFile(at: fileURL)
    }
    func removeRegularFile(at fileURL: URL, matching identity: RaceResistantFileIdentity) throws {
        XCTFail("Scanning must not mutate files")
    }
    func moveRegularFile(at sourceURL: URL, to destinationURL: URL, matching identity: RaceResistantFileIdentity) throws {
        XCTFail("Scanning must not mutate files")
    }
}
