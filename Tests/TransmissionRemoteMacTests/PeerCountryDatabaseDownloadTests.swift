// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Combine
import Foundation
import XCTest
import zlib
@testable import TransmissionRemoteMac

final class PeerCountryDatabaseDownloadTests: XCTestCase {
    private let csv = Data("\"1.0.0.0\",\"1.0.0.255\",\"AU\"\n".utf8)
    private let published = URL(string: "https://download.db-ip.com/free/dbip-country-lite-2026-09.csv.gz")!

    func testSourceValidationUsesBlankDefaultAndRejectsUnsafeURLsWithoutEchoingInput() throws {
        XCTAssertNil(try PeerCountryDownloadSource.validatedCustomURL(" \n "))
        XCTAssertEqual(
            try PeerCountryDownloadSource.validatedCustomURL(" https://example.test/country.csv.gz?token=private "),
            URL(string: "https://example.test/country.csv.gz?token=private")
        )
        for value in [
            "http://example.test/country.csv", "file:///private/country.csv", "https:///country.csv",
            "https://user:secret@example.test/country.csv", "https://example.test/country.csv#secret",
            "https://example.test:0/country.csv", "https://example.test:65536/country.csv",
            "https://example.test/a b.csv", "https://example.test\\other/country.csv"
        ] {
            XCTAssertThrowsError(try PeerCountryDownloadSource.validatedCustomURL(value)) { error in
                XCTAssertEqual(error as? PeerCountryDownloadError, .invalidSourceURL)
                XCTAssertFalse(error.localizedDescription.contains(value))
            }
        }
    }

    func testPublishedDiscoverySelectsNewestActualCountryLinkOnly() throws {
        let page = """
        <a href="https://download.db-ip.com/free/dbip-country-lite-2025-12.csv.gz">Old</a>
        <a href="https://download.db-ip.com/free/dbip-city-lite-2026-10.csv.gz">Wrong database</a>
        <a href="https://example.test/free/dbip-country-lite-2026-12.csv.gz">Wrong host</a>
        <a href="https://download.db-ip.com/free/dbip-country-lite-2026-09.csv.gz">Current</a>
        <a href="https://download.db-ip.com/free/dbip-country-lite-2026-13.csv.gz">Invalid month</a>
        """
        XCTAssertEqual(try PeerCountryDownloadSource.latestPublishedURL(in: page), published)
        XCTAssertThrowsError(try PeerCountryDownloadSource.latestPublishedURL(in: "No published download"))
    }

    func testRedirectPoliciesKeepProviderRequestsScopedAndCustomRequestsHTTPS() {
        let page = PeerCountryDownloadRedirectPolicy.providerPage
        let provider = PeerCountryDownloadRedirectPolicy.providerDownload
        let custom = PeerCountryDownloadRedirectPolicy.customHTTPS
        XCTAssertTrue(page.allows(PeerCountryDatabaseMetadata.sourceURL))
        XCTAssertFalse(page.allows(published))
        XCTAssertTrue(provider.allows(published))
        XCTAssertFalse(provider.allows(URL(string: "https://other.test/free/dbip-country-lite-2026-09.csv.gz")!))
        XCTAssertFalse(provider.allows(URL(string: "https://download.db-ip.com/private/country.csv.gz")!))
        XCTAssertTrue(custom.allows(URL(string: "https://cdn.example.test/country.csv.gz")!))
        XCTAssertFalse(custom.allows(URL(string: "http://cdn.example.test/country.csv.gz")!))
        XCTAssertFalse(custom.allows(URL(string: "https://user:password@cdn.example.test/country.csv.gz")!))
    }

    func testDefaultDownloadDiscoversPublishedGzipValidatesAndRemovesTemporaryFiles() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = CountryFixtureTransport(responses: [
            PeerCountryDatabaseMetadata.sourceURL: Data("<a href='\(published.absoluteString)'>Download</a>".utf8),
            published: gzip(csv)
        ])
        let service = PeerCountryDatabaseDownloader(transport: transport, temporaryDirectory: directory)
        let database = try await service.download(customURL: " ", phase: { _ in })
        XCTAssertEqual(database.metadata.sourceFileName, "dbip-country-lite-2026-09.csv")
        XCTAssertNotNil(database.metadata.databaseDate)
        XCTAssertEqual(database.countryCode(for: PeerIPAddress(parsing: "1.0.0.7")!), "AU")
        let requests = await transport.requestedURLs
        XCTAssertEqual(requests, [PeerCountryDatabaseMetadata.sourceURL, published])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    func testCustomCSVSkipsProviderDiscoveryAndRemovesTemporaryFiles() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let custom = URL(string: "https://example.test/custom.csv")!
        let transport = CountryFixtureTransport(responses: [custom: csv])
        let service = PeerCountryDatabaseDownloader(transport: transport, temporaryDirectory: directory)
        let database = try await service.download(customURL: custom.absoluteString, phase: { _ in })
        XCTAssertEqual(database.metadata.sourceFileName, "custom.csv")
        let requests = await transport.requestedURLs
        XCTAssertEqual(requests, [custom])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    func testInvalidCustomDatabaseLeavesNoTemporaryFiles() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let custom = URL(string: "https://example.test/country.csv.gz")!
        let transport = CountryFixtureTransport(responses: [custom: Data("<html>Not a CSV</html>".utf8)])
        let service = PeerCountryDatabaseDownloader(transport: transport, temporaryDirectory: directory)
        await assertThrowsErrorAsync {
            _ = try await service.download(customURL: custom.absoluteString, phase: { _ in })
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    func testGzipRejectsCorruptTruncatedAndTrailingDataAndCleansOutput() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("input.gz")
        let output = directory.appendingPathComponent("output.csv")
        let valid = gzip(csv)
        var badCRC = valid
        badCRC[badCRC.count - 8] ^= 0xff
        for data in [badCRC, Data(valid.dropLast()), valid + Data([0x00]), Data("not gzip".utf8)] {
            try data.write(to: input)
            XCTAssertThrowsError(try PeerCountryGzipDecoder.expand(from: input, to: output)) { error in
                XCTAssertEqual(error as? PeerCountryDownloadError, .invalidGzip)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        }
    }

    func testGzipExpandedSizeBoundAndExactOutput() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("input.gz")
        let output = directory.appendingPathComponent("output.csv")
        try gzip(csv).write(to: input)
        XCTAssertThrowsError(try PeerCountryGzipDecoder.expand(from: input, to: output, maximumBytes: csv.count - 1)) {
            XCTAssertEqual($0 as? PeerCountryDownloadError, .expandedDataTooLarge)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        try PeerCountryGzipDecoder.expand(from: input, to: output, maximumBytes: csv.count)
        XCTAssertEqual(try Data(contentsOf: output), csv)
    }

    func testGzipSpansInputAndExactOutputBufferBoundaries() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("large.gz")
        let output = directory.appendingPathComponent("large.csv")
        let bytes = Data(repeating: 0x61, count: PeerCountryDatabaseStorageContract.streamReadByteCount * 4)
        try gzip(bytes).write(to: input)
        try PeerCountryGzipDecoder.expand(from: input, to: output, maximumBytes: bytes.count)
        XCTAssertEqual(try Data(contentsOf: output), bytes)
    }

    func testCancelledOperationCannotInstallOrRemoveAnExistingDatabase() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = PeerCountryDatabaseRepository(destinationURL: directory.appendingPathComponent("country.bin"))
        let original = try await repository.importCSV(data: csv, sourceFileName: "original.csv")
        let operation = PeerCountryDatabaseOperation()
        operation.cancel()
        await assertThrowsErrorAsync { try await repository.install(original, operation: operation) }
        await assertThrowsErrorAsync { try await repository.remove(operation: operation) }
        let loaded = try await repository.load()
        XCTAssertEqual(loaded, original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["country.bin"])
    }

    @MainActor
    func testRemovalRejectsLateDownloadEvenWhenDownloaderIgnoresCancellation() async throws {
        let database = try PeerCountryCSVImporter.parse(data: csv, sourceFileName: "download.csv")
        let gate = CountryDownloadGate(result: database)
        let repository = PeerCountryDatabaseRepository.ephemeral()
        let controller = PeerCountryDatabaseController(repository: repository, downloader: gate)
        let task = Task { try await controller.downloadDatabase(customURL: "") }
        await gate.waitUntilStarted()
        XCTAssertNotNil(controller.downloadPhase)
        try await controller.removeDatabase()
        await gate.finish()
        await assertThrowsErrorAsync { _ = try await task.value }
        let loaded = try await repository.load()
        XCTAssertNil(loaded)
        let snapshot = try await controller.databaseSnapshot()
        XCTAssertNil(snapshot)
        XCTAssertEqual(controller.status, .unavailable)
        XCTAssertNil(controller.downloadPhase)
        XCTAssertNil(controller.errorMessage)
    }

    @MainActor
    func testFailedUpdatePreservesPreviousDatabaseAndClearsProgress() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("original.csv")
        try csv.write(to: file)
        let repository = PeerCountryDatabaseRepository(destinationURL: directory.appendingPathComponent("country.bin"))
        let controller = PeerCountryDatabaseController(repository: repository, downloader: CountryFailingDownloader())
        let original = try await controller.importDatabase(from: file)
        var publications = 0
        let subscription = controller.$status.dropFirst().sink { _ in publications += 1 }
        defer { subscription.cancel() }
        await assertThrowsErrorAsync { _ = try await controller.downloadDatabase(customURL: "") }
        let loaded = try await repository.load()
        XCTAssertEqual(loaded, original)
        XCTAssertEqual(controller.status, .installed(original.metadata))
        XCTAssertNil(controller.downloadPhase)
        XCTAssertNotNil(controller.errorMessage)
        XCTAssertEqual(publications, 0, "A failed update must not restart resolution of the unchanged database")
    }

    @MainActor
    func testCancelledUpdateDoesNotRepublishUnchangedDatabase() async throws {
        let original = try PeerCountryCSVImporter.parse(data: csv, sourceFileName: "original.csv")
        let gate = CountryDownloadGate(result: original)
        let repository = PeerCountryDatabaseRepository.ephemeral()
        try await repository.install(original)
        let controller = PeerCountryDatabaseController(repository: repository, downloader: gate)
        let initialLoad = expectation(description: "initial database published")
        let initialSubscription = controller.$status.first { $0 == .installed(original.metadata) }.sink { _ in
            initialLoad.fulfill()
        }
        await fulfillment(of: [initialLoad], timeout: 2)
        initialSubscription.cancel()
        var publications = 0
        let subscription = controller.$status.dropFirst().sink { _ in publications += 1 }
        defer { subscription.cancel() }

        let task = Task { try await controller.downloadDatabase(customURL: "") }
        await gate.waitUntilStarted()
        task.cancel()
        await gate.finish()
        await assertThrowsErrorAsync { _ = try await task.value }

        let snapshot = try await controller.databaseSnapshot()
        XCTAssertEqual(snapshot, original)
        XCTAssertEqual(controller.status, .installed(original.metadata))
        XCTAssertEqual(publications, 0, "Cancellation must not restart resolution of the unchanged database")
        XCTAssertNil(controller.errorMessage)
        XCTAssertNil(controller.downloadPhase)
    }

    @MainActor
    func testFailedSuccessorPublishesLatestCommittedRepositorySnapshot() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("original.csv")
        try csv.write(to: source)
        let repository = PeerCountryDatabaseRepository(destinationURL: directory.appendingPathComponent("country.bin"))
        let controller = PeerCountryDatabaseController(repository: repository, downloader: CountryFailingDownloader())
        let original = try await controller.importDatabase(from: source)
        let committed = try PeerCountryCSVImporter.parse(
            data: Data("\"1.0.0.0\",\"1.0.0.255\",\"US\"\n".utf8),
            sourceFileName: original.metadata.sourceFileName,
            importedAt: original.metadata.importedAt
        )
        XCTAssertEqual(committed.metadata, original.metadata)
        var publications = 0
        let subscription = controller.$status.dropFirst().sink { _ in publications += 1 }
        defer { subscription.cancel() }

        // Stage the exact post-commit/pre-publication boundary without relying
        // on executor timing: disk advances while the controller retains old state.
        try await repository.install(committed)
        let before = try await controller.databaseSnapshot()
        XCTAssertEqual(before, original)
        await assertThrowsErrorAsync { _ = try await controller.downloadDatabase(customURL: "") }

        let published = try await controller.databaseSnapshot()
        let persisted = try await repository.load()
        XCTAssertEqual(published, committed)
        XCTAssertEqual(persisted, committed)
        XCTAssertEqual(controller.status, .installed(committed.metadata))
        XCTAssertEqual(publications, 1, "Changed ranges must publish even when metadata matches")
        XCTAssertEqual(controller.errorMessage, PeerCountryDownloadError.httpStatus(503).localizedDescription)
    }

    @MainActor
    func testCancelledSuccessorPublishesLatestCommittedRepositorySnapshot() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("original.csv")
        try csv.write(to: source)
        let committed = try PeerCountryCSVImporter.parse(data: csv, sourceFileName: "committed-update.csv")
        let gate = CountryDownloadGate(result: committed)
        let repository = PeerCountryDatabaseRepository(destinationURL: directory.appendingPathComponent("country.bin"))
        let controller = PeerCountryDatabaseController(repository: repository, downloader: gate)
        let original = try await controller.importDatabase(from: source)
        try await repository.install(committed)
        let before = try await controller.databaseSnapshot()
        XCTAssertEqual(before, original)

        let task = Task { try await controller.downloadDatabase(customURL: "") }
        await gate.waitUntilStarted()
        task.cancel()
        await gate.finish()
        await assertThrowsErrorAsync { _ = try await task.value }

        let published = try await controller.databaseSnapshot()
        let persisted = try await repository.load()
        XCTAssertEqual(published, committed)
        XCTAssertEqual(persisted, committed)
        XCTAssertEqual(controller.status, .installed(committed.metadata))
        XCTAssertNil(controller.errorMessage)
        XCTAssertNil(controller.downloadPhase)
    }

    func testTransportHTTPAndByteLimitsCleanFailedOutput() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = fixtureURLSessionTransport()
        let cases: [(String, Int, PeerCountryDownloadError)] = [
            ("missing", 100, .httpStatus(404)),
            ("advertised-large", 8, .downloadTooLarge),
            ("chunked-large", 8, .downloadTooLarge)
        ]
        for (path, maximum, expected) in cases {
            let destination = directory.appendingPathComponent(path)
            do {
                try await transport.download(
                    from: URL(string: "https://fixture.test/\(path)")!,
                    to: destination,
                    maximumBytes: maximum,
                    redirectPolicy: .customHTTPS
                )
                XCTFail("Expected rejection for \(path)")
            } catch {
                XCTAssertEqual(error as? PeerCountryDownloadError, expected)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        }
    }

    func testTransportStreamsSuccessfulChunksAndUsesIndependentSessionPolicy() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = fixtureURLSessionTransport()
        let destination = directory.appendingPathComponent("result.csv")
        let url = URL(string: "https://fixture.test/valid")!
        try await transport.download(from: url, to: destination, maximumBytes: 32, redirectPolicy: .customHTTPS)
        XCTAssertEqual(try Data(contentsOf: destination), Data("1234567890".utf8))
        let configuration = PeerCountryURLSessionDownloadTransport().configuration()
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertNil(configuration.urlCache)
        XCTAssertEqual(configuration.timeoutIntervalForRequest, 30)
        XCTAssertEqual(configuration.timeoutIntervalForResource, 180)
    }

    func testCancelledTransportNeverLeavesOutput() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("cancelled.csv")
        let transport = fixtureURLSessionTransport()
        let started = expectation(description: "request started")
        CountryDownloadURLProtocol.requestStarted = { started.fulfill() }
        defer { CountryDownloadURLProtocol.requestStarted = nil }
        let task = Task {
            try await transport.download(
                from: URL(string: "https://fixture.test/wait")!,
                to: destination,
                maximumBytes: 32,
                redirectPolicy: .customHTTPS
            )
        }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        do {
            try await task.value
            XCTFail("cancelled transport should throw")
        } catch is CancellationError {
        } catch {
            XCTFail("unexpected cancellation error: \(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    private func fixtureURLSessionTransport() -> PeerCountryURLSessionDownloadTransport {
        PeerCountryURLSessionDownloadTransport(configuration: {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [CountryDownloadURLProtocol.self]
            return configuration
        })
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Standards-compliant stored DEFLATE blocks keep fixture creation
    /// deterministic and independent of the production inflate implementation.
    private func gzip(_ data: Data) -> Data {
        var result = Data([0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 3])
        var offset = 0
        repeat {
            let end = min(offset + Int(UInt16.max), data.count)
            let length = UInt16(end - offset)
            result.append(end == data.count ? 1 : 0)
            for value in [length, ~length] {
                result.append(UInt8(truncatingIfNeeded: value))
                result.append(UInt8(truncatingIfNeeded: value >> 8))
            }
            result.append(data[offset ..< end])
            offset = end
        } while offset < data.count
        let crc = data.withUnsafeBytes { bytes in
            UInt32(crc32(0, bytes.bindMemory(to: Bytef.self).baseAddress, uInt(data.count)))
        }
        for value in [crc, UInt32(data.count)] {
            for shift in stride(from: 0, to: 32, by: 8) { result.append(UInt8(truncatingIfNeeded: value >> shift)) }
        }
        return result
    }
}

private actor CountryFixtureTransport: PeerCountryDownloadTransport {
    let responses: [URL: Data]
    private(set) var requestedURLs: [URL] = []

    init(responses: [URL: Data]) { self.responses = responses }

    func download(
        from url: URL,
        to destination: URL,
        maximumBytes: Int,
        redirectPolicy: PeerCountryDownloadRedirectPolicy
    ) async throws {
        requestedURLs.append(url)
        guard redirectPolicy.allows(url), let data = responses[url] else {
            throw PeerCountryDownloadError.unexpectedResponse
        }
        guard data.count <= maximumBytes else { throw PeerCountryDownloadError.downloadTooLarge }
        try data.write(to: destination)
    }
}

private actor CountryDownloadGate: PeerCountryDatabaseDownloading {
    let result: PeerCountryDatabase
    private var continuation: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?

    init(result: PeerCountryDatabase) { self.result = result }

    func download(customURL: String, phase: @escaping @Sendable (String) -> Void) async throws -> PeerCountryDatabase {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started?.resume()
            started = nil
        }
        return result
    }

    func waitUntilStarted() async {
        if continuation != nil { return }
        await withCheckedContinuation { started = $0 }
    }

    func finish() {
        continuation?.resume()
        continuation = nil
    }
}

private struct CountryFailingDownloader: PeerCountryDatabaseDownloading {
    func download(customURL: String, phase: @escaping @Sendable (String) -> Void) async throws -> PeerCountryDatabase {
        throw PeerCountryDownloadError.httpStatus(503)
    }
}

private final class CountryDownloadURLProtocol: URLProtocol {
    static var requestStarted: (() -> Void)?

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "fixture.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let path = url.lastPathComponent
        if path == "wait" {
            Self.requestStarted?()
            return
        }
        let headers = path == "advertised-large" ? ["Content-Length": "1000"] : [:]
        let response = HTTPURLResponse(url: url, statusCode: path == "missing" ? 404 : 200, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("12345".utf8))
        client?.urlProtocol(self, didLoad: Data("67890".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
