// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import XCTest
@testable import TransmissionRemoteMac

final class TorrentGetResponseTests: XCTestCase {
    func testAbsurdWireDatesCannotReachMappedTorrentPresentation() throws {
        let data = Data("""
        {"torrents":[{"id":1,"addedDate":1e300,"doneDate":1e300,
        "activityDate":1e300,"dateCreated":1e300,"nextAnnounceTime":1e300}]}
        """.utf8)
        let arguments = try JSONDecoder().decode(RPCArguments.self, from: data)
        let response = try TorrentGetResponse(validating: arguments)
        let torrent = try XCTUnwrap(response.torrents.first)

        XCTAssertNil(torrent.addedDate)
        XCTAssertNil(torrent.doneDate)
        XCTAssertNil(torrent.activityDate)
        XCTAssertNil(torrent.dateCreated)
        XCTAssertNil(torrent.nextAnnounceDate)
        let summary = TorrentMapper.map(torrent, rpcVersion: 18)
        XCTAssertNil(summary.addedDate)
        XCTAssertNil(summary.completedDate)
        XCTAssertNil(summary.activityDate)
    }

    func testValidatedObjectRowsRequirePositiveUniqueIDs() throws {
        let valid = try TorrentGetResponse(validating: [
            "torrents": .array([
                .object(["id": .int(1), "name": .string("One")]),
                .object(["id": .int(2), "name": .string("Two")]),
            ])
        ])
        XCTAssertEqual(valid.torrents.map(\.id), [1, 2])

        XCTAssertThrowsError(try TorrentGetResponse(validating: [
            "torrents": .array([.object(["name": .string("Missing")])])
        ])) { error in
            XCTAssertEqual(error as? TorrentGetResponseDecodingError, .invalidTorrentID)
        }
        XCTAssertThrowsError(try TorrentGetResponse(validating: [
            "torrents": .array([
                .object(["id": .int(1)]),
                .object(["id": .int(1)]),
            ])
        ])) { error in
            XCTAssertEqual(error as? TorrentGetResponseDecodingError, .duplicateTorrentID(1))
        }
    }

    func testValidatedObjectRowsCanOmitIDsWhenTheRequestDidNotAskForThem() throws {
        let response = try TorrentGetResponse(
            validating: [
                "torrents": .array([
                    .object([
                        "hashString": .string("hash-one"),
                        "magnetLink": .string("magnet:?xt=urn:btih:one"),
                    ]),
                ])
            ],
            requiresTorrentIDs: false
        )

        XCTAssertEqual(response.torrents.first?.hashString, "hash-one")
    }

    func testValidatedRowsRejectMixedAndTruncatedRepresentations() {
        XCTAssertThrowsError(try TorrentGetResponse(validating: [
            "torrents": .array([
                .object(["id": .int(1)]),
                .array([.int(2)]),
            ])
        ])) { error in
            XCTAssertEqual(error as? TorrentGetResponseDecodingError, .invalidRows)
        }

        XCTAssertThrowsError(try TorrentGetResponse(validating: [
            "fields": .array([.string("id"), .string("name")]),
            "torrents": .array([.array([.int(1)])]),
        ])) { error in
            XCTAssertEqual(error as? TorrentGetResponseDecodingError, .truncatedTableRow)
        }
    }

    func testValidatedRowsRejectDuplicateOrMalformedTableFields() {
        XCTAssertThrowsError(try TorrentGetResponse(validating: [
            "fields": .array([.string("id"), .string("id")]),
            "data": .array([.array([.int(1), .int(1)])]),
        ])) { error in
            XCTAssertEqual(error as? TorrentGetResponseDecodingError, .invalidTableFields)
        }

        XCTAssertThrowsError(try TorrentGetResponse(validating: [
            "torrents": .array([
                .array([.string("id"), .int(2)]),
                .array([.int(1), .string("One")]),
            ])
        ])) { error in
            XCTAssertEqual(error as? TorrentGetResponseDecodingError, .invalidTableFields)
        }
    }
}
