// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import XCTest
@testable import TransmissionRemoteMac

final class TorrentAddResultTests: XCTestCase {
    func testDecodesAddedTorrentIdentity() throws {
        let result = try TorrentAddResult(arguments: [
            "torrent-added": .object([
                "id": .int(42),
                "hashString": .string("ABC123"),
                "name": .string("Example")
            ])
        ])

        XCTAssertEqual(result.outcome, .added)
        XCTAssertFalse(result.isDuplicate)
        XCTAssertEqual(result.id, 42)
        XCTAssertEqual(result.hashString, "ABC123")
        XCTAssertEqual(result.name, "Example")
    }

    func testDecodesDuplicateTorrentIdentity() throws {
        let result = try TorrentAddResult(arguments: [
            "torrent-duplicate": .object([
                "id": .int(7),
                "hashString": .string("DEF456"),
                "name": .string("Existing")
            ])
        ])

        XCTAssertEqual(result.outcome, .duplicate)
        XCTAssertTrue(result.isDuplicate)
        XCTAssertEqual(result.id, 7)
        XCTAssertEqual(result.hashString, "DEF456")
        XCTAssertEqual(result.name, "Existing")
    }

    func testAllowsMissingOptionalIdentityFields() throws {
        let result = try TorrentAddResult(arguments: [
            "torrent-added": .object([:])
        ])

        XCTAssertEqual(result.outcome, .added)
        XCTAssertNil(result.id)
        XCTAssertNil(result.hashString)
        XCTAssertNil(result.name)
    }

    func testAllowsNullOptionalID() throws {
        let result = try TorrentAddResult(arguments: [
            "torrent-added": .object([
                "id": .null
            ])
        ])

        XCTAssertNil(result.id)
    }

    func testRejectsFractionalIDWithoutTrapping() {
        assertInvalidArguments([
            "torrent-added": .object([
                "id": .double(42.5)
            ])
        ])
    }

    func testRejectsNonFiniteIDWithoutTrapping() {
        assertInvalidArguments([
            "torrent-added": .object([
                "id": .double(.infinity)
            ])
        ])
        assertInvalidArguments([
            "torrent-added": .object([
                "id": .double(.nan)
            ])
        ])
    }

    func testRejectsOutOfRangeIDWithoutTrapping() {
        assertInvalidArguments([
            "torrent-added": .object([
                "id": .double(.greatestFiniteMagnitude)
            ])
        ])
        assertInvalidArguments([
            "torrent-added": .object([
                "id": .double(-Double.greatestFiniteMagnitude)
            ])
        ])
    }

    func testRejectsMissingTorrentResult() {
        assertInvalidArguments([:])
    }

    func testRejectsMalformedTorrentResultObject() {
        assertInvalidArguments([
            "torrent-duplicate": .string("not-an-object")
        ])
    }

    func testRejectsMalformedIdentityFields() {
        assertInvalidArguments([
            "torrent-added": .object([
                "id": .string("42")
            ])
        ])
        assertInvalidArguments([
            "torrent-added": .object([
                "hashString": .int(123)
            ])
        ])
        assertInvalidArguments([
            "torrent-added": .object([
                "name": .bool(true)
            ])
        ])
    }

    func testRejectsAmbiguousTorrentResult() {
        assertInvalidArguments([
            "torrent-added": .object([:]),
            "torrent-duplicate": .object([:])
        ])
    }

    private func assertInvalidArguments(
        _ arguments: RPCArguments,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            _ = try TorrentAddResult(arguments: arguments)
            XCTFail("malformed torrent-add result should fail", file: file, line: line)
        } catch TransmissionRPCError.invalidArguments {
        } catch {
            XCTFail("unexpected error: \(error)", file: file, line: line)
        }
    }
}
