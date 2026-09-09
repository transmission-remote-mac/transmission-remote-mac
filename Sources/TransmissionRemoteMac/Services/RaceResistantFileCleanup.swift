// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Darwin
import Foundation

struct RaceResistantFileIdentity: Equatable, Hashable, RawRepresentable, Sendable {
    private static let version = "v3"

    let deviceID: UInt64
    let fileID: UInt64
    let generation: UInt32
    let fileSize: Int64
    let modificationTimeSeconds: Int64
    let modificationTimeNanoseconds: Int64
    let changeTimeSeconds: Int64
    let changeTimeNanoseconds: Int64

    var rawValue: String {
        [
            Self.version,
            String(deviceID),
            String(fileID),
            String(generation),
            String(fileSize),
            String(modificationTimeSeconds),
            String(modificationTimeNanoseconds),
            String(changeTimeSeconds),
            String(changeTimeNanoseconds)
        ].joined(separator: ":")
    }

    init(
        deviceID: UInt64,
        fileID: UInt64,
        generation: UInt32,
        fileSize: Int64 = 0,
        modificationTimeSeconds: Int64 = 0,
        modificationTimeNanoseconds: Int64 = 0,
        changeTimeSeconds: Int64 = 0,
        changeTimeNanoseconds: Int64 = 0
    ) {
        self.deviceID = deviceID
        self.fileID = fileID
        self.generation = generation
        self.fileSize = fileSize
        self.modificationTimeSeconds = modificationTimeSeconds
        self.modificationTimeNanoseconds = modificationTimeNanoseconds
        self.changeTimeSeconds = changeTimeSeconds
        self.changeTimeNanoseconds = changeTimeNanoseconds
    }

    init?(rawValue: String) {
        let components = rawValue.split(separator: ":", omittingEmptySubsequences: false)
        guard let version = components.first,
              version == Self.version,
              components.count == 9,
              let deviceID = components.count > 1 ? UInt64(components[1]) : nil,
              let fileID = components.count > 2 ? UInt64(components[2]) : nil,
              let generation = components.count > 3 ? UInt32(components[3]) : nil,
              let fileSize = Int64(components[4]),
              let modificationTimeSeconds = Int64(components[5]),
              let modificationTimeNanoseconds = Int64(components[6]),
              let changeTimeSeconds = Int64(components[7]),
              let changeTimeNanoseconds = Int64(components[8]) else {
            return nil
        }
        self.init(
            deviceID: deviceID,
            fileID: fileID,
            generation: generation,
            fileSize: fileSize,
            modificationTimeSeconds: modificationTimeSeconds,
            modificationTimeNanoseconds: modificationTimeNanoseconds,
            changeTimeSeconds: changeTimeSeconds,
            changeTimeNanoseconds: changeTimeNanoseconds
        )
    }
}

struct RaceResistantRegularFileSnapshot: Equatable, Sendable {
    let data: Data
    let identity: RaceResistantFileIdentity
}

enum RaceResistantFileCleanupError: LocalizedError, Equatable {
    case invalidFileURL
    case sourceIsNotARegularFile
    case sourceExceedsMaximumSize(maximumBytes: Int)
    case sourceIdentityChanged
    case sourceCouldNotBeRestored(URL)

    var errorDescription: String? {
        switch self {
        case .invalidFileURL:
            "The source file location is invalid."
        case .sourceIsNotARegularFile:
            "The source is no longer a regular local file."
        case .sourceExceedsMaximumSize(let maximumBytes):
            "The source file exceeds the \(ByteCountFormatter.string(fromByteCount: Int64(maximumBytes), countStyle: .file)) limit."
        case .sourceIdentityChanged:
            "The source file was replaced, so it was left untouched."
        case .sourceCouldNotBeRestored(let stagingURL):
            "The source changed during cleanup and was preserved at \(stagingURL.path)."
        }
    }
}

protocol RaceResistantFileCleaning: Sendable {
    func stableIdentityOfRegularFile(at fileURL: URL) throws -> RaceResistantFileIdentity
    func removeRegularFile(at fileURL: URL, matching identity: RaceResistantFileIdentity) throws
    func moveRegularFile(
        at sourceURL: URL,
        to destinationURL: URL,
        matching identity: RaceResistantFileIdentity
    ) throws
}

/// Claims the source entry with an exclusive descriptor-relative rename before
/// checking its identity. A replacement can therefore be restored, but is
/// never passed to the final unlink or move operation.
struct DarwinRaceResistantFileCleanup: RaceResistantFileCleaning, Sendable {
    func stableIdentityOfRegularFile(at fileURL: URL) throws -> RaceResistantFileIdentity {
        let location = try fileLocation(for: fileURL)
        let parentDescriptor = try openDirectory(at: location.parentURL)
        defer { _ = Darwin.close(parentDescriptor) }

        return try stableIdentityOfRegularFile(
            in: parentDescriptor,
            named: location.name
        )
    }

    func readRegularFile(at fileURL: URL, maximumBytes: Int? = nil, checkCancellation: () throws -> Void = {}) throws -> RaceResistantRegularFileSnapshot {
        try checkCancellation()
        let location = try fileLocation(for: fileURL)
        let parentDescriptor = try openDirectory(at: location.parentURL)
        defer { _ = Darwin.close(parentDescriptor) }

        let descriptor = try openRegularFile(
            in: parentDescriptor,
            named: location.name
        )
        defer { _ = Darwin.close(descriptor) }

        let initialStatus = try regularFileStatus(for: descriptor)
        if let maximumBytes,
           (maximumBytes < 0 || initialStatus.st_size > Int64(maximumBytes)) {
            throw RaceResistantFileCleanupError.sourceExceedsMaximumSize(
                maximumBytes: max(0, maximumBytes)
            )
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        var data = Data()
        while true {
            try checkCancellation()
            // One extra byte detects growth beyond the cap without allocating
            // the full maximum up front or losing descriptor identity checks.
            let chunkSize = maximumBytes.map { min(64 * 1_024, $0 - data.count) + 1 }
                ?? (64 * 1_024)
            guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else { break }
            data.append(chunk)
            if let maximumBytes, data.count > maximumBytes {
                throw RaceResistantFileCleanupError.sourceExceedsMaximumSize(
                    maximumBytes: maximumBytes
                )
            }
        }
        try checkCancellation()
        let finalStatus = try regularFileStatus(for: descriptor)
        guard isSameFileSnapshot(initialStatus, finalStatus) else {
            throw RaceResistantFileCleanupError.sourceIdentityChanged
        }
        return RaceResistantRegularFileSnapshot(
            data: data,
            identity: identity(from: finalStatus)
        )
    }

    func removeRegularFile(
        at fileURL: URL,
        matching identity: RaceResistantFileIdentity
    ) throws {
        try withClaimedRegularFile(at: fileURL, matching: identity) { directoryDescriptor, name in
            let result = name.withCString { unlinkat(directoryDescriptor, $0, 0) }
            guard result == 0 else {
                throw currentPOSIXError()
            }
        }
    }

    func moveRegularFile(
        at sourceURL: URL,
        to destinationURL: URL,
        matching identity: RaceResistantFileIdentity
    ) throws {
        let destination = try fileLocation(for: destinationURL)
        let destinationParentDescriptor = try openDirectory(at: destination.parentURL)
        defer { _ = Darwin.close(destinationParentDescriptor) }

        try withClaimedRegularFile(at: sourceURL, matching: identity) {
            stagingDescriptor,
            stagingName in
            try renameExclusive(
                from: stagingDescriptor,
                name: stagingName,
                to: destinationParentDescriptor,
                name: destination.name
            )
        }
    }

    private func withClaimedRegularFile<Result>(
        at fileURL: URL,
        matching expectedIdentity: RaceResistantFileIdentity,
        operation: (Int32, String) throws -> Result
    ) throws -> Result {
        let source = try fileLocation(for: fileURL)
        let sourceParentDescriptor = try openDirectory(at: source.parentURL)
        defer { _ = Darwin.close(sourceParentDescriptor) }

        return try withStagingDirectory(
            in: sourceParentDescriptor,
            parentURL: source.parentURL
        ) { stagingDescriptor, stagingURL in
            let sourceDescriptor = try openRegularFile(
                in: sourceParentDescriptor,
                named: source.name
            )
            defer { _ = Darwin.close(sourceDescriptor) }

            let preClaimStatus = try regularFileStatus(for: sourceDescriptor)
            guard identity(from: preClaimStatus) == expectedIdentity else {
                throw RaceResistantFileCleanupError.sourceIdentityChanged
            }

            let stagingName = "source"
            try renameExclusive(
                from: sourceParentDescriptor,
                name: source.name,
                to: stagingDescriptor,
                name: stagingName
            )

            do {
                let claimedDescriptor = try openRegularFile(
                    in: stagingDescriptor,
                    named: stagingName
                )
                defer { _ = Darwin.close(claimedDescriptor) }

                let claimedStatus = try regularFileStatus(for: claimedDescriptor)
                guard isSameClaimedFile(preClaimStatus, claimedStatus) else {
                    throw RaceResistantFileCleanupError.sourceIdentityChanged
                }
                return try operation(stagingDescriptor, stagingName)
            } catch {
                do {
                    try renameExclusive(
                        from: stagingDescriptor,
                        name: stagingName,
                        to: sourceParentDescriptor,
                        name: source.name
                    )
                } catch {
                    throw RaceResistantFileCleanupError.sourceCouldNotBeRestored(
                        stagingURL.appendingPathComponent(stagingName, isDirectory: false)
                    )
                }
                throw error
            }
        }
    }

    private func withStagingDirectory<Result>(
        in parentDescriptor: Int32,
        parentURL: URL,
        operation: (Int32, URL) throws -> Result
    ) throws -> Result {
        for _ in 0..<4 {
            let name = ".trm-source-cleanup-\(UUID().uuidString)"
            let creationResult = name.withCString {
                mkdirat(parentDescriptor, $0, mode_t(S_IRWXU))
            }
            guard creationResult == 0 else {
                if errno == EEXIST { continue }
                throw currentPOSIXError()
            }

            let descriptor = name.withCString {
                openat(parentDescriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            }
            guard descriptor >= 0 else {
                let error = currentPOSIXError()
                _ = name.withCString { unlinkat(parentDescriptor, $0, AT_REMOVEDIR) }
                throw error
            }
            defer {
                _ = Darwin.close(descriptor)
                _ = name.withCString { unlinkat(parentDescriptor, $0, AT_REMOVEDIR) }
            }
            return try operation(
                descriptor,
                parentURL.appendingPathComponent(name, isDirectory: true)
            )
        }
        throw POSIXError(.EEXIST)
    }

    private func stableIdentityOfRegularFile(
        in directoryDescriptor: Int32,
        named name: String
    ) throws -> RaceResistantFileIdentity {
        let descriptor = try openRegularFile(
            in: directoryDescriptor,
            named: name
        )
        defer { _ = Darwin.close(descriptor) }

        return identity(from: try regularFileStatus(for: descriptor))
    }

    private func openRegularFile(
        in directoryDescriptor: Int32,
        named name: String
    ) throws -> Int32 {
        let descriptor = name.withCString {
            openat(directoryDescriptor, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            if errno == ELOOP {
                throw RaceResistantFileCleanupError.sourceIsNotARegularFile
            }
            throw currentPOSIXError()
        }
        do {
            _ = try regularFileStatus(for: descriptor)
            return descriptor
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    private func regularFileStatus(for descriptor: Int32) throws -> stat {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw currentPOSIXError()
        }
        guard (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            throw RaceResistantFileCleanupError.sourceIsNotARegularFile
        }
        return status
    }

    private func identity(from status: stat) -> RaceResistantFileIdentity {
        return RaceResistantFileIdentity(
            deviceID: UInt64(UInt32(bitPattern: status.st_dev)),
            fileID: UInt64(status.st_ino),
            generation: status.st_gen,
            fileSize: Int64(status.st_size),
            modificationTimeSeconds: Int64(status.st_mtimespec.tv_sec),
            modificationTimeNanoseconds: Int64(status.st_mtimespec.tv_nsec),
            changeTimeSeconds: Int64(status.st_ctimespec.tv_sec),
            changeTimeNanoseconds: Int64(status.st_ctimespec.tv_nsec)
        )
    }

    private func isSameFileSnapshot(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_gen == rhs.st_gen
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    /// A descriptor-relative rename can update ctime on macOS. The full source
    /// identity is checked before claiming the path; afterward, compare only
    /// attributes that the rename itself cannot legitimately change.
    private func isSameClaimedFile(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_gen == rhs.st_gen
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
    }

    private func openDirectory(at directoryURL: URL) throws -> Int32 {
        let descriptor = directoryURL.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw currentPOSIXError()
        }
        return descriptor
    }

    private func renameExclusive(
        from sourceDirectoryDescriptor: Int32,
        name sourceName: String,
        to destinationDirectoryDescriptor: Int32,
        name destinationName: String
    ) throws {
        let result = sourceName.withCString { sourcePath in
            destinationName.withCString { destinationPath in
                renameatx_np(
                    sourceDirectoryDescriptor,
                    sourcePath,
                    destinationDirectoryDescriptor,
                    destinationPath,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard result == 0 else {
            throw currentPOSIXError()
        }
    }

    private func fileLocation(for fileURL: URL) throws -> (parentURL: URL, name: String) {
        guard fileURL.isFileURL else {
            throw RaceResistantFileCleanupError.invalidFileURL
        }
        let standardizedURL = fileURL.standardizedFileURL
        let name = standardizedURL.lastPathComponent
        guard !name.isEmpty,
              name != ".",
              name != "..",
              !name.contains("/") else {
            throw RaceResistantFileCleanupError.invalidFileURL
        }
        return (standardizedURL.deletingLastPathComponent(), name)
    }

    private func currentPOSIXError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
