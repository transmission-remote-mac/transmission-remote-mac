// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation
import XCTest
@testable import TransmissionRemoteMac

final class PeerCountryDatabaseTests: XCTestCase {
    func testIPAddressNormalizationHandlesIPv4IPv6AndMappedIPv4() throws {
        let ipv4 = try XCTUnwrap(PeerIPAddress(parsing: " 192.0.2.4 "))
        let mapped = try XCTUnwrap(PeerIPAddress(parsing: "::ffff:192.0.2.4"))
        let ipv6 = try XCTUnwrap(PeerIPAddress(parsing: "[2001:0db8::1%en0]"))

        XCTAssertEqual(ipv4.family, .ipv4)
        XCTAssertEqual(ipv4.canonicalString, "192.0.2.4")
        XCTAssertEqual(mapped, ipv4)
        XCTAssertEqual(ipv6.family, .ipv6)
        XCTAssertEqual(ipv6.canonicalString, "2001:db8::1")
        XCTAssertNil(PeerIPAddress(parsing: "example.test"))
    }

    func testCSVParserBuildsPackedIPv4AndIPv6Index() throws {
        let csv = """
        "1.0.0.0","1.0.0.255","AU"
        "8.8.8.0","8.8.8.255","US"
        "2001:db8::","2001:db8::ffff","ZZ"
        """
        let database = try PeerCountryCSVImporter.parse(
            data: Data(csv.utf8),
            sourceFileName: "dbip-country-lite-2026-09.csv",
            importedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        XCTAssertEqual(database.ipv4RangeCount, 2)
        XCTAssertEqual(database.ipv6RangeCount, 1)
        XCTAssertEqual(database.packedByteCount, 54)
        XCTAssertEqual(database.storageByteCount, 54)
        XCTAssertEqual(
            database.countryCode(for: try XCTUnwrap(PeerIPAddress(parsing: "1.0.0.42"))),
            "AU"
        )
        XCTAssertEqual(
            database.countryCode(for: try XCTUnwrap(PeerIPAddress(parsing: "2001:db8::10"))),
            "ZZ"
        )
        XCTAssertNil(database.countryCode(for: try XCTUnwrap(PeerIPAddress(parsing: "9.9.9.9"))))
        XCTAssertNotNil(database.metadata.databaseDate)
    }

    func testCSVRejectsMalformedUnsortedAndOversizedRows() throws {
        XCTAssertThrowsError(try PeerCountryCSVImporter.parse(
            data: Data(#""1.0.0.0","1.0.0.255""#.utf8),
            sourceFileName: "bad.csv"
        )) { error in
            XCTAssertEqual(error as? PeerCountryDatabaseError, .malformedCSV(line: 1))
        }

        let unsorted = """
        "8.8.8.0","8.8.8.255","US"
        "1.0.0.0","1.0.0.255","AU"
        """
        XCTAssertThrowsError(try PeerCountryCSVImporter.parse(
            data: Data(unsorted.utf8),
            sourceFileName: "unsorted.csv"
        )) { error in
            XCTAssertEqual(error as? PeerCountryDatabaseError, .overlappingOrUnsortedRanges)
        }

        let oversized = "\"1.0.0.0\",\"1.0.0.255\",\"AU\""
            + String(repeating: " ", count: PeerCountryDatabaseStorageContract.maximumCSVLineByteCount)
        XCTAssertThrowsError(try PeerCountryCSVImporter.parse(
            data: Data(oversized.utf8),
            sourceFileName: "oversized.csv"
        )) { error in
            XCTAssertEqual(error as? PeerCountryDatabaseError, .lineTooLong(line: 1))
        }
    }

    func testInvalidImportDoesNotReplaceActiveDatabase() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("country.bin")
        let repository = PeerCountryDatabaseRepository(destinationURL: destination)
        let valid = Data(#""1.0.0.0","1.0.0.255","AU""#.utf8)

        _ = try await repository.importCSV(
            data: valid,
            sourceFileName: "dbip-country-lite-2026-09.csv",
            importedAt: Date(timeIntervalSince1970: 100)
        )
        await assertThrowsErrorAsync {
            _ = try await repository.importCSV(
                data: Data(#""1.0.0.255","1.0.0.0","AU""#.utf8),
                sourceFileName: "invalid.csv",
                importedAt: Date(timeIntervalSince1970: 200)
            )
        }

        let loaded = try await repository.load()
        let reloaded = try XCTUnwrap(loaded)
        XCTAssertEqual(reloaded.metadata.sourceFileName, "dbip-country-lite-2026-09.csv")
        XCTAssertEqual(
            reloaded.countryCode(for: try XCTUnwrap(PeerIPAddress(parsing: "1.0.0.7"))),
            "AU"
        )
    }

    func testCancelledImportDoesNotInstallDatabase() async throws {
        let repository = PeerCountryDatabaseRepository.ephemeral()
        let task = Task {
            try await repository.importCSV(
                data: Data(#""1.0.0.0","1.0.0.255","AU""#.utf8),
                sourceFileName: "cancelled.csv"
            )
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("cancelled import should stop before installation")
        } catch is CancellationError {
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        let loaded = try await repository.load()
        XCTAssertNil(loaded)
    }

    func testLargeSyntheticFixtureHasDeterministicBoundedMemoryShape() throws {
        let rangeCount = 100_000
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("dbip-country-lite-2026-09.csv")
        XCTAssertTrue(FileManager.default.createFile(atPath: sourceURL.path, contents: nil))
        let handle = try FileHandle(forWritingTo: sourceURL)
        var batch = ""
        for index in 0 ..< rangeCount {
            let address = ipv4String(UInt32(0x0a00_0000) + UInt32(index))
            batch += "\"\(address)\",\"\(address)\",\"AU\"\n"
            if index % 1_000 == 999 {
                try handle.write(contentsOf: Data(batch.utf8))
                batch.removeAll(keepingCapacity: true)
            }
        }
        if !batch.isEmpty { try handle.write(contentsOf: Data(batch.utf8)) }
        try handle.synchronize()
        try handle.close()

        let database = try PeerCountryCSVImporter.parse(
            sourceURL: sourceURL,
            importedAt: Date(timeIntervalSince1970: 100)
        )

        XCTAssertEqual(database.ipv4RangeCount, rangeCount)
        XCTAssertEqual(
            database.packedByteCount,
            rangeCount * PeerCountryDatabaseStorageContract.ipv4RecordByteCount
        )
        XCTAssertEqual(database.storageByteCount, database.packedByteCount)
        XCTAssertLessThan(
            PeerCountryDatabaseStorageContract.maximumPackedByteCount,
            75 * 1_024 * 1_024
        )
        XCTAssertEqual(PeerCountryDatabaseStorageContract.streamReadByteCount, 64 * 1_024)
        XCTAssertEqual(PeerCountryDatabaseStorageContract.maximumCSVLineByteCount, 1_024)
    }

    private func ipv4String(_ value: UInt32) -> String {
        [24, 16, 8, 0].map { String((value >> UInt32($0)) & 0xff) }.joined(separator: ".")
    }
}

func assertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {}
}
