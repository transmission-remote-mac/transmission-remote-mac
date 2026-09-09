// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Darwin
import Foundation
import XCTest
@testable import TransmissionRemoteMac

final class RaceResistantFileCleanupTests: XCTestCase {
    private let cleanup = DarwinRaceResistantFileCleanup()

    func testChunkedReadCancellationLeavesTheSourceUntouched() throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.directoryURL) }
        let bytes = Data(repeating: 0x41, count: 150_000)
        try bytes.write(to: context.sourceURL)
        var checks = 0
        XCTAssertThrowsError(try cleanup.readRegularFile(at: context.sourceURL, maximumBytes: bytes.count, checkCancellation: {
            checks += 1
            if checks == 3 { throw CancellationError() }
        })) {
            XCTAssertTrue($0 is CancellationError)
        }
        XCTAssertEqual(checks, 3)
        XCTAssertEqual(try cleanup.readRegularFile(at: context.sourceURL, maximumBytes: bytes.count).data, bytes)
    }

    func testChunkedReadStillRejectsMutationBeforeFinalIdentityCheck() throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.directoryURL) }
        try Data(repeating: 0x41, count: 150_000).write(to: context.sourceURL)
        var checks = 0
        XCTAssertThrowsError(try cleanup.readRegularFile(at: context.sourceURL, checkCancellation: {
            checks += 1
            if checks == 3 { try Data("changed".utf8).write(to: context.sourceURL) }
        })) {
            XCTAssertEqual($0 as? RaceResistantFileCleanupError, .sourceIdentityChanged)
        }
    }

    func testStableIdentityRoundTripsThroughPersistableValue() throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.directoryURL) }
        try Data("original".utf8).write(to: context.sourceURL)

        let identity = try cleanup.stableIdentityOfRegularFile(at: context.sourceURL)

        XCTAssertEqual(RaceResistantFileIdentity(rawValue: identity.rawValue), identity)
    }

    func testPersistedIdentityRejectsVersionsWithoutChangeTime() {
        XCTAssertNil(RaceResistantFileIdentity(rawValue: "v1:1:2:3"))
        XCTAssertNil(RaceResistantFileIdentity(rawValue: "v2:1:2:3:4:5:6"))
        XCTAssertNil(RaceResistantFileIdentity(rawValue: "1:2:3:4:5:6:7:8"))
    }

    func testDescriptorSnapshotReturnsBytesAndTheCleanupIdentityTogether() throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.directoryURL) }
        let originalData = Data("original metainfo".utf8)
        try originalData.write(to: context.sourceURL)

        let snapshot = try cleanup.readRegularFile(at: context.sourceURL)

        XCTAssertEqual(snapshot.data, originalData)
        XCTAssertEqual(
            snapshot.identity,
            try cleanup.stableIdentityOfRegularFile(at: context.sourceURL)
        )
    }

    func testDescriptorSnapshotRejectsFilesAboveTheExplicitReadLimit() throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.directoryURL) }
        try Data(repeating: 0x41, count: 10).write(to: context.sourceURL)

        XCTAssertThrowsError(
            try cleanup.readRegularFile(at: context.sourceURL, maximumBytes: 9)
        ) { error in
            XCTAssertEqual(
                error as? RaceResistantFileCleanupError,
                .sourceExceedsMaximumSize(maximumBytes: 9)
            )
        }
    }

    func testDescriptorSnapshotRejectsASymlinkWithoutReadingItsTarget() throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.directoryURL) }
        let targetURL = context.directoryURL.appendingPathComponent("target.torrent")
        try Data("target".utf8).write(to: targetURL)
        try FileManager.default.createSymbolicLink(
            at: context.sourceURL,
            withDestinationURL: targetURL
        )

        XCTAssertThrowsError(try cleanup.readRegularFile(at: context.sourceURL)) { error in
            XCTAssertEqual(
                error as? RaceResistantFileCleanupError,
                .sourceIsNotARegularFile
            )
        }
        XCTAssertEqual(try Data(contentsOf: targetURL), Data("target".utf8))
    }

    func testDeleteRejectsAReplacementAndLeavesItAtTheSourcePath() throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.directoryURL) }
        try Data("original".utf8).write(to: context.sourceURL)
        let snapshot = try cleanup.readRegularFile(at: context.sourceURL)
        try replaceItem(at: context.sourceURL, with: Data("replacement".utf8))

        XCTAssertThrowsError(
            try cleanup.removeRegularFile(
                at: context.sourceURL,
                matching: snapshot.identity
            )
        ) { error in
            XCTAssertEqual(
                error as? RaceResistantFileCleanupError,
                .sourceIdentityChanged
            )
        }
        XCTAssertEqual(try Data(contentsOf: context.sourceURL), Data("replacement".utf8))
        XCTAssertTrue(try cleanupStagingNames(in: context.directoryURL).isEmpty)
    }

    func testDeleteRejectsInPlaceContentChangesAfterTheSnapshot() throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.directoryURL) }
        try Data("original".utf8).write(to: context.sourceURL)
        let snapshot = try cleanup.readRegularFile(at: context.sourceURL)
        let handle = try FileHandle(forWritingTo: context.sourceURL)
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Data("modified".utf8))
        try handle.synchronize()
        try handle.close()

        XCTAssertThrowsError(try cleanup.removeRegularFile(
            at: context.sourceURL,
            matching: snapshot.identity
        ))
        XCTAssertEqual(try Data(contentsOf: context.sourceURL), Data("modified".utf8))
    }

    func testDeleteRejectsSameInodeRewriteWithRestoredSizeAndModificationTime() throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.directoryURL) }
        let rewrite = try prepareSameInodeRewrite(at: context.sourceURL)

        XCTAssertThrowsError(try cleanup.removeRegularFile(
            at: context.sourceURL,
            matching: rewrite.snapshot.identity
        )) { error in
            XCTAssertEqual(error as? RaceResistantFileCleanupError, .sourceIdentityChanged)
        }
        XCTAssertEqual(try Data(contentsOf: context.sourceURL), rewrite.rewrittenData)
        XCTAssertTrue(try cleanupStagingNames(in: context.directoryURL).isEmpty)
    }

    func testMoveRejectsAReplacementWithoutCreatingTheDestination() throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.directoryURL) }
        try Data("original".utf8).write(to: context.sourceURL)
        let capturedIdentity = try cleanup.stableIdentityOfRegularFile(at: context.sourceURL)
        try replaceItem(at: context.sourceURL, with: Data("replacement".utf8))

        XCTAssertThrowsError(
            try cleanup.moveRegularFile(
                at: context.sourceURL,
                to: context.destinationURL,
                matching: capturedIdentity
            )
        ) { error in
            XCTAssertEqual(
                error as? RaceResistantFileCleanupError,
                .sourceIdentityChanged
            )
        }
        XCTAssertEqual(try Data(contentsOf: context.sourceURL), Data("replacement".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: context.destinationURL.path))
        XCTAssertTrue(try cleanupStagingNames(in: context.directoryURL).isEmpty)
    }

    func testMoveRejectsSameInodeRewriteWithRestoredSizeAndModificationTime() throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.directoryURL) }
        let rewrite = try prepareSameInodeRewrite(at: context.sourceURL)

        XCTAssertThrowsError(try cleanup.moveRegularFile(
            at: context.sourceURL,
            to: context.destinationURL,
            matching: rewrite.snapshot.identity
        )) { error in
            XCTAssertEqual(error as? RaceResistantFileCleanupError, .sourceIdentityChanged)
        }
        XCTAssertEqual(try Data(contentsOf: context.sourceURL), rewrite.rewrittenData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: context.destinationURL.path))
        XCTAssertTrue(try cleanupStagingNames(in: context.directoryURL).isEmpty)
    }

    func testMoveDoesNotOverwriteARacingDestinationAndRestoresTheSource() throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.directoryURL) }
        try Data("original".utf8).write(to: context.sourceURL)
        try Data("destination".utf8).write(to: context.destinationURL)
        let capturedIdentity = try cleanup.stableIdentityOfRegularFile(at: context.sourceURL)

        XCTAssertThrowsError(
            try cleanup.moveRegularFile(
                at: context.sourceURL,
                to: context.destinationURL,
                matching: capturedIdentity
            )
        )
        XCTAssertEqual(try Data(contentsOf: context.sourceURL), Data("original".utf8))
        XCTAssertEqual(try Data(contentsOf: context.destinationURL), Data("destination".utf8))
        XCTAssertTrue(try cleanupStagingNames(in: context.directoryURL).isEmpty)
    }

    func testReplacementSymlinkAndItsTargetAreLeftUntouched() throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.directoryURL) }
        let targetURL = context.directoryURL.appendingPathComponent("target.torrent")
        try Data("original".utf8).write(to: context.sourceURL)
        try Data("target".utf8).write(to: targetURL)
        let capturedIdentity = try cleanup.stableIdentityOfRegularFile(at: context.sourceURL)
        try FileManager.default.removeItem(at: context.sourceURL)
        try FileManager.default.createSymbolicLink(
            at: context.sourceURL,
            withDestinationURL: targetURL
        )

        XCTAssertThrowsError(
            try cleanup.removeRegularFile(
                at: context.sourceURL,
                matching: capturedIdentity
            )
        ) { error in
            XCTAssertEqual(
                error as? RaceResistantFileCleanupError,
                .sourceIsNotARegularFile
            )
        }
        XCTAssertEqual(try Data(contentsOf: targetURL), Data("target".utf8))
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: context.sourceURL.path),
            targetURL.path
        )
        XCTAssertTrue(try cleanupStagingNames(in: context.directoryURL).isEmpty)
    }

    func testSuccessfulDeleteAndMoveMutateOnlyTheCapturedFile() throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.directoryURL) }
        try Data("move".utf8).write(to: context.sourceURL)
        let moveIdentity = try cleanup.stableIdentityOfRegularFile(at: context.sourceURL)

        try cleanup.moveRegularFile(
            at: context.sourceURL,
            to: context.destinationURL,
            matching: moveIdentity
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: context.sourceURL.path))
        XCTAssertEqual(try Data(contentsOf: context.destinationURL), Data("move".utf8))
        let deleteIdentity = try cleanup.stableIdentityOfRegularFile(at: context.destinationURL)
        try cleanup.removeRegularFile(
            at: context.destinationURL,
            matching: deleteIdentity
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: context.destinationURL.path))
        XCTAssertTrue(try cleanupStagingNames(in: context.directoryURL).isEmpty)
    }

    private func makeContext() throws -> (
        directoryURL: URL,
        sourceURL: URL,
        destinationURL: URL
    ) {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: false
        )
        return (
            directoryURL,
            directoryURL.appendingPathComponent("source.torrent", isDirectory: false),
            directoryURL.appendingPathComponent("processed.torrent", isDirectory: false)
        )
    }

    private func replaceItem(at sourceURL: URL, with data: Data) throws {
        let replacementURL = sourceURL.deletingLastPathComponent().appendingPathComponent(
            "replacement-\(UUID().uuidString).torrent",
            isDirectory: false
        )
        try data.write(to: replacementURL)
        let result: Int32 = replacementURL.withUnsafeFileSystemRepresentation { replacementPath in
            sourceURL.withUnsafeFileSystemRepresentation { sourcePath -> Int32 in
                guard let replacementPath, let sourcePath else { return -1 }
                return Darwin.rename(replacementPath, sourcePath)
            }
        }
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func prepareSameInodeRewrite(
        at sourceURL: URL
    ) throws -> (snapshot: RaceResistantRegularFileSnapshot, rewrittenData: Data) {
        let originalData = Data("original".utf8)
        let rewrittenData = Data("modified".utf8)
        try originalData.write(to: sourceURL)
        let snapshot = try cleanup.readRegularFile(at: sourceURL)
        let originalStatus = try fileStatus(at: sourceURL)
        let rewrittenStatus = try rewriteInPlace(
            sourceURL,
            with: rewrittenData,
            restoringTimesFrom: originalStatus
        )

        XCTAssertEqual(rewrittenStatus.st_ino, originalStatus.st_ino)
        XCTAssertEqual(rewrittenStatus.st_size, originalStatus.st_size)
        XCTAssertEqual(rewrittenStatus.st_mtimespec.tv_sec, originalStatus.st_mtimespec.tv_sec)
        XCTAssertEqual(rewrittenStatus.st_mtimespec.tv_nsec, originalStatus.st_mtimespec.tv_nsec)
        XCTAssertTrue(
            rewrittenStatus.st_ctimespec.tv_sec != originalStatus.st_ctimespec.tv_sec
                || rewrittenStatus.st_ctimespec.tv_nsec != originalStatus.st_ctimespec.tv_nsec
        )
        return (snapshot, rewrittenData)
    }

    private func fileStatus(at fileURL: URL) throws -> stat {
        var status = stat()
        let result = fileURL.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.lstat(path, &status)
        }
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return status
    }

    private func rewriteInPlace(
        _ fileURL: URL,
        with data: Data,
        restoringTimesFrom originalStatus: stat
    ) throws -> stat {
        let descriptor = fileURL.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_WRONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { _ = Darwin.close(descriptor) }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: data)
        guard ftruncate(descriptor, off_t(data.count)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try handle.synchronize()

        var restoredTimes = [
            timespec(
                tv_sec: originalStatus.st_atimespec.tv_sec,
                tv_nsec: originalStatus.st_atimespec.tv_nsec
            ),
            timespec(
                tv_sec: originalStatus.st_mtimespec.tv_sec,
                tv_nsec: originalStatus.st_mtimespec.tv_nsec
            )
        ]
        let restoreResult = restoredTimes.withUnsafeMutableBufferPointer { times in
            futimens(descriptor, times.baseAddress)
        }
        guard restoreResult == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return status
    }

    private func cleanupStagingNames(in directoryURL: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directoryURL.path).filter {
            $0.hasPrefix(".trm-source-cleanup-")
        }
    }
}
