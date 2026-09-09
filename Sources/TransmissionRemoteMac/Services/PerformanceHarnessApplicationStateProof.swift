// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

#if DEBUG
import Darwin
import Foundation

struct PerformanceHarnessApplicationState: Equatable, Sendable {
    let activationCount: Int
    let isMainWindowVisibleAndNonMiniaturized: Bool
}

struct PerformanceHarnessApplicationStateProofRecorder {
    static let environmentKey =
        "TRANSMISSION_REMOTE_MAC_PERFORMANCE_APPLICATION_STATE_PROOF"
    static let proofName = ".transmission-remote-mac-performance-application-state"
    static let compiledMarker = "TRM_PERFORMANCE_APPLICATION_STATE_V1"

    private let proofURL: URL
    private let token: String
    private let context: PerformanceHarnessContext
    private let environment: [String: String]
    private let resolvedHomePath: String

    static func requestedFromEnvironment(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        resolvedHomePath: String = NSHomeDirectory(),
        fileManager: FileManager = .default
    ) -> PerformanceHarnessApplicationStateProofRecorder? {
        guard
            let context = PerformanceHarnessContext.validatedIfRequested(
                featureEnvironmentKey: environmentKey,
                environment: environment,
                resolvedHomePath: resolvedHomePath,
                fileManager: fileManager
            ),
            context.token.utf8.count <= 128
        else {
            return nil
        }
        return PerformanceHarnessApplicationStateProofRecorder(
            proofURL: context.temporaryDirectoryURL.appendingPathComponent(proofName),
            token: context.token,
            context: context,
            environment: environment,
            resolvedHomePath: resolvedHomePath
        )
    }

    @discardableResult
    func record(
        _ state: PerformanceHarnessApplicationState,
        fileManager: FileManager = .default
    ) -> Bool {
        guard
            state.activationCount >= 0,
            PerformanceHarnessContext.validatedIfRequested(
                featureEnvironmentKey: Self.environmentKey,
                environment: environment,
                resolvedHomePath: resolvedHomePath,
                fileManager: fileManager
            ) == context,
            context.token == token,
            context.temporaryDirectoryURL.appendingPathComponent(Self.proofName) == proofURL
        else {
            return false
        }
        let windowState = state.isMainWindowVisibleAndNonMiniaturized ? "true" : "false"
        let payload =
            "\(Self.compiledMarker)\n"
                + "\(token)\n"
                + "activation_count=\(state.activationCount)\n"
                + "main_window_visible_nonminiaturized=\(windowState)\n"
        return PerformanceHarnessAtomicProofWriter.write(
            Array(payload.utf8),
            to: proofURL,
            maximumByteCount: 512
        )
    }
}

enum PerformanceHarnessAtomicProofWriter {
    static func write(
        _ bytes: [UInt8],
        to proofURL: URL,
        maximumByteCount: Int
    ) -> Bool {
        guard !bytes.isEmpty, bytes.count <= maximumByteCount else { return false }

        let temporaryURL = proofURL.deletingLastPathComponent().appendingPathComponent(
            ".\(proofURL.lastPathComponent).\(UUID().uuidString).tmp"
        )
        let proofMode = mode_t(S_IRUSR | S_IWUSR)
        let descriptor = open(
            temporaryURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            proofMode
        )
        guard descriptor >= 0 else { return false }
        defer {
            close(descriptor)
            unlink(temporaryURL.path)
        }

        guard
            fchmod(descriptor, proofMode) == 0,
            writeAll(bytes, to: descriptor),
            synchronize(descriptor)
        else {
            return false
        }
        var temporaryStatus = stat()
        guard
            fstat(descriptor, &temporaryStatus) == 0,
            (temporaryStatus.st_mode & S_IFMT) == S_IFREG,
            (temporaryStatus.st_mode & mode_t(0o777)) == proofMode,
            temporaryStatus.st_size == off_t(bytes.count),
            rename(temporaryURL.path, proofURL.path) == 0
        else {
            return false
        }

        var proofStatus = stat()
        guard
            lstat(proofURL.path, &proofStatus) == 0,
            (proofStatus.st_mode & S_IFMT) == S_IFREG,
            (proofStatus.st_mode & mode_t(0o777)) == proofMode,
            proofStatus.st_dev == temporaryStatus.st_dev,
            proofStatus.st_ino == temporaryStatus.st_ino,
            proofStatus.st_size == off_t(bytes.count)
        else {
            return false
        }
        return true
    }

    private static func writeAll(_ bytes: [UInt8], to descriptor: Int32) -> Bool {
        bytes.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return false }
            var written = 0
            while written < rawBuffer.count {
                let result = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: written),
                    rawBuffer.count - written
                )
                if result > 0 {
                    written += result
                } else if result == -1 && errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }

    private static func synchronize(_ descriptor: Int32) -> Bool {
        while true {
            if fsync(descriptor) == 0 { return true }
            if errno != EINTR { return false }
        }
    }
}
#endif
