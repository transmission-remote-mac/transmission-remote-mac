// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation
import zlib

protocol PeerCountryDatabaseDownloading: Sendable {
    func download(
        customURL: String,
        phase: @escaping @Sendable (String) -> Void
    ) async throws -> PeerCountryDatabase
}

protocol PeerCountryDownloadTransport: Sendable {
    func download(
        from url: URL,
        to destination: URL,
        maximumBytes: Int,
        redirectPolicy: PeerCountryDownloadRedirectPolicy
    ) async throws
}

/// Explicit user-triggered acquisition only. Network files and expanded CSVs
/// remain temporary; the controller installs the validated packed result.
struct PeerCountryDatabaseDownloader: PeerCountryDatabaseDownloading {
    static let maximumPageBytes = 2 * 1_024 * 1_024
    static let maximumDownloadBytes = 128 * 1_024 * 1_024

    var transport: any PeerCountryDownloadTransport = PeerCountryURLSessionDownloadTransport()
    var temporaryDirectory = FileManager.default.temporaryDirectory

    func download(
        customURL: String,
        phase: @escaping @Sendable (String) -> Void
    ) async throws -> PeerCountryDatabase {
        try Task.checkCancellation()
        let customSource = try PeerCountryDownloadSource.validatedCustomURL(customURL)
        let directory = temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let source: URL
        if let customSource {
            source = customSource
        } else {
            phase("Finding the latest DB-IP database…")
            let pageURL = directory.appendingPathComponent("provider.html")
            try await transport.download(
                from: PeerCountryDatabaseMetadata.sourceURL,
                to: pageURL,
                maximumBytes: Self.maximumPageBytes,
                redirectPolicy: .providerPage
            )
            try Task.checkCancellation()
            let data = try boundedData(at: pageURL, maximumBytes: Self.maximumPageBytes)
            guard let page = String(data: data, encoding: .utf8) else {
                throw PeerCountryDownloadError.publishedDownloadUnavailable
            }
            source = try PeerCountryDownloadSource.latestPublishedURL(in: page)
        }

        phase("Downloading country database…")
        let downloaded = directory.appendingPathComponent("download")
        try await transport.download(
            from: source,
            to: downloaded,
            maximumBytes: Self.maximumDownloadBytes,
            redirectPolicy: customSource == nil ? .providerDownload : .customHTTPS
        )
        try Task.checkCancellation()
        let downloadedBytes = try downloaded.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard downloadedBytes <= Self.maximumDownloadBytes else {
            throw PeerCountryDownloadError.downloadTooLarge
        }

        phase("Validating country database…")
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let csvURL: URL
            if try PeerCountryGzipDecoder.isGzip(at: downloaded) {
                csvURL = directory.appendingPathComponent("expanded.csv")
                try PeerCountryGzipDecoder.expand(from: downloaded, to: csvURL)
            } else {
                csvURL = downloaded
            }
            return try PeerCountryCSVImporter.parse(
                sourceURL: csvURL,
                sourceFileName: source.deletingPathExtensionIfGzip.lastPathComponent
            )
        }
        return try await withTaskCancellationHandler {
            let result = try await worker.value
            try Task.checkCancellation()
            return result
        } onCancel: {
            worker.cancel()
        }
    }

    private func boundedData(at url: URL, maximumBytes: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else { throw PeerCountryDownloadError.downloadTooLarge }
        return data
    }
}

private extension URL {
    var deletingPathExtensionIfGzip: URL {
        pathExtension.lowercased() == "gz" ? deletingPathExtension() : self
    }
}

enum PeerCountryGzipDecoder {
    static func isGzip(at url: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try handle.read(upToCount: 2) == Data([0x1f, 0x8b])
    }

    /// Fixed-size input/output buffers avoid materializing the expanded CSV.
    /// zlib validates the gzip CRC and trailer before any database is installed.
    static func expand(
        from source: URL,
        to destination: URL,
        maximumBytes: Int = PeerCountryDatabaseStorageContract.maximumSourceByteCount
    ) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        var succeeded = false
        defer { if !succeeded { try? FileManager.default.removeItem(at: destination) } }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var stream = z_stream()
        guard inflateInit2_(&stream, 15 + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw PeerCountryDownloadError.invalidGzip
        }
        defer { inflateEnd(&stream) }
        let chunkSize = PeerCountryDatabaseStorageContract.streamReadByteCount
        var outputBytes = [UInt8](repeating: 0, count: chunkSize)
        var total = 0
        var ended = false
        while let chunk = try input.read(upToCount: chunkSize), !chunk.isEmpty {
            try Task.checkCancellation()
            guard !ended else { throw PeerCountryDownloadError.invalidGzip }
            try chunk.withUnsafeBytes { inputBuffer in
                stream.next_in = UnsafeMutablePointer(mutating: inputBuffer.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(chunk.count)
                repeat {
                    try Task.checkCancellation()
                    let result = outputBytes.withUnsafeMutableBytes { outputBuffer in
                        stream.next_out = outputBuffer.bindMemory(to: Bytef.self).baseAddress
                        stream.avail_out = uInt(chunkSize)
                        return inflate(&stream, Z_NO_FLUSH)
                    }
                    if result == Z_BUF_ERROR, stream.avail_in == 0 { break }
                    guard result == Z_OK || result == Z_STREAM_END else {
                        throw PeerCountryDownloadError.invalidGzip
                    }
                    let count = chunkSize - Int(stream.avail_out)
                    guard count <= maximumBytes - total else {
                        throw PeerCountryDownloadError.expandedDataTooLarge
                    }
                    total += count
                    try output.write(contentsOf: Data(outputBytes.prefix(count)))
                    if result == Z_STREAM_END {
                        guard stream.avail_in == 0 else { throw PeerCountryDownloadError.invalidGzip }
                        ended = true
                        break
                    }
                } while stream.avail_in > 0 || stream.avail_out == 0
            }
        }
        guard ended else { throw PeerCountryDownloadError.invalidGzip }
        try Task.checkCancellation()
        try output.close()
        succeeded = true
    }
}

struct PeerCountryURLSessionDownloadTransport: PeerCountryDownloadTransport {
    var configuration: @Sendable () -> URLSessionConfiguration = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 180
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        return configuration
    }

    func download(
        from url: URL,
        to destination: URL,
        maximumBytes: Int,
        redirectPolicy: PeerCountryDownloadRedirectPolicy
    ) async throws {
        let transfer = PeerCountryFileTransfer(
            destination: destination,
            maximumBytes: maximumBytes,
            redirectPolicy: redirectPolicy
        )
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await transfer.start(url: url, configuration: configuration())
        } onCancel: {
            transfer.cancel()
        }
    }
}

/// URLSession delivers chunks, not individual async bytes. State shared with
/// task cancellation is locked; file I/O stays on its serial delegate queue.
private final class PeerCountryFileTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let destination: URL
    private let maximumBytes: Int
    private let redirectPolicy: PeerCountryDownloadRedirectPolicy
    private let lock = NSLock()
    private var cancelled = false
    private var task: URLSessionDataTask?
    private var continuation: CheckedContinuation<Void, Error>?
    private var handle: FileHandle?
    private var failure: Error?
    private var receivedBytes = 0
    private var redirects = 0
    private var receivedResponse = false

    init(destination: URL, maximumBytes: Int, redirectPolicy: PeerCountryDownloadRedirectPolicy) {
        self.destination = destination
        self.maximumBytes = maximumBytes
        self.redirectPolicy = redirectPolicy
    }

    func start(url: URL, configuration: URLSessionConfiguration) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            defer { lock.unlock() }
            guard !cancelled else {
                continuation.resume(throwing: CancellationError())
                return
            }
            do {
                guard redirectPolicy.allows(url) else { throw PeerCountryDownloadError.invalidSourceURL }
                guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                handle = try FileHandle(forWritingTo: destination)
                self.continuation = continuation
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                var request = URLRequest(url: url)
                request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                let task = session.dataTask(with: request)
                self.task = task
                task.resume()
            } catch {
                try? FileManager.default.removeItem(at: destination)
                continuation.resume(throwing: error)
            }
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = task
        lock.unlock()
        task?.cancel()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        lock.lock()
        defer { lock.unlock() }
        if let response = response as? HTTPURLResponse, let url = response.url {
            if response.statusCode != 200 {
                failure = PeerCountryDownloadError.httpStatus(response.statusCode)
            } else if response.expectedContentLength > Int64(maximumBytes) {
                failure = PeerCountryDownloadError.downloadTooLarge
            } else if !redirectPolicy.allows(url) {
                failure = PeerCountryDownloadError.unsafeRedirect
            } else {
                receivedResponse = true
            }
        } else {
            failure = PeerCountryDownloadError.unexpectedResponse
        }
        completionHandler(failure == nil && !cancelled ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard failure == nil, !cancelled else { return }
        do {
            guard data.count <= maximumBytes - receivedBytes else {
                throw PeerCountryDownloadError.downloadTooLarge
            }
            receivedBytes += data.count
            try handle?.write(contentsOf: data)
        } catch {
            failure = error
            dataTask.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        lock.lock()
        defer { lock.unlock() }
        redirects += 1
        if redirects > 5 {
            failure = PeerCountryDownloadError.tooManyRedirects
        } else if request.url.map({ redirectPolicy.allows($0) }) != true {
            failure = PeerCountryDownloadError.unsafeRedirect
        }
        completionHandler(failure == nil && !cancelled ? request : nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        self.task = nil
        do { try handle?.close() } catch { failure = failure ?? error }
        handle = nil
        let result: Result<Void, Error>
        if cancelled {
            result = .failure(CancellationError())
        } else if let failure {
            result = .failure(failure)
        } else if error != nil {
            result = .failure(PeerCountryDownloadError.networkFailure)
        } else if receivedResponse {
            result = .success(())
        } else {
            result = .failure(PeerCountryDownloadError.unexpectedResponse)
        }
        lock.unlock()
        if case .failure = result { try? FileManager.default.removeItem(at: destination) }
        session.finishTasksAndInvalidate()
        continuation?.resume(with: result)
    }
}
