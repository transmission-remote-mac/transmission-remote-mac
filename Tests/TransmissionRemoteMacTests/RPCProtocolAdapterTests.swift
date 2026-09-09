// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import XCTest
@testable import TransmissionRemoteMac

final class RPCProtocolAdapterTests: XCTestCase {
    private let jsonProtocol = RPCWireProtocol.jsonRPC2(RPCSemanticVersion("6.0.0")!)

    func testChallengeHeaderSelectsProtocolWithoutGuessing() {
        XCTAssertEqual(RPCProtocolAdapter.wireProtocol(challengeHeader: nil), .legacy)
        XCTAssertEqual(RPCProtocolAdapter.wireProtocol(challengeHeader: "5.3.0"), .legacy)
        XCTAssertEqual(RPCProtocolAdapter.wireProtocol(challengeHeader: "invalid"), .legacy)
        XCTAssertEqual(
            RPCProtocolAdapter.wireProtocol(challengeHeader: "6.0.0"),
            jsonProtocol
        )
        XCTAssertEqual(
            RPCProtocolAdapter.wireProtocol(challengeHeader: "6.1.0-beta.1+build"),
            .jsonRPC2(RPCSemanticVersion("6.1.0")!)
        )
    }

    func testLegacyRPC5RPC14AndRPC17ResponsesKeepCanonicalMixedKeys() throws {
        for version in [5, 14, 17] {
            let arguments = try RPCProtocolAdapter.decode(
                Data(#"{"result":"success","arguments":{"rpc-version":\#(version),"download-dir":"/legacy","seedRatioLimited":true}}"#.utf8),
                for: RPCRequest(method: "session-get"),
                protocol: .legacy,
                expectedID: 41,
                returnArguments: true
            )
            XCTAssertEqual(arguments["rpc-version"], .int(version))
            XCTAssertEqual(arguments["download-dir"], .string("/legacy"))
            XCTAssertEqual(arguments["seedRatioLimited"], .bool(true))
        }
    }

    func testLegacyModeRejectsJSONRPCEnvelope() throws {
        XCTAssertThrowsError(
            try RPCProtocolAdapter.decode(
                Data(#"{"jsonrpc":"2.0","result":{},"id":41}"#.utf8),
                for: RPCRequest(method: "session-get"),
                protocol: .legacy,
                expectedID: 41,
                returnArguments: true
            )
        ) { error in
            guard case TransmissionRPCError.invalidResponse = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testLegacyModeRejectsJSONRPCErrorEnvelopeWithoutResult() throws {
        XCTAssertThrowsError(
            try RPCProtocolAdapter.decode(
                Data(#"{"jsonrpc":"2.0","error":{"code":-32601,"message":"No method"},"id":41}"#.utf8),
                for: RPCRequest(method: "session-get"),
                protocol: .legacy,
                expectedID: 41,
                returnArguments: true
            )
        ) { error in
            guard case TransmissionRPCError.invalidResponse = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testLegacyModeRejectsExplicitNullJSONRPCMarker() throws {
        XCTAssertThrowsError(
            try RPCProtocolAdapter.decode(
                Data(#"{"jsonrpc":null,"result":"success","arguments":{}}"#.utf8),
                for: RPCRequest(method: "session-get"),
                protocol: .legacy,
                expectedID: 41,
                returnArguments: true
            )
        ) { error in
            guard case TransmissionRPCError.invalidResponse = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testJSONRPCRequestAdaptsMethodArgumentsFieldsAndAliases() throws {
        let request = RPCRequest(method: "torrent-set", arguments: [
            "ids": .array([.int(4)]),
            "bandwidthPriority": .int(1),
            "files-wanted": .array([.int(0), .int(2)]),
            "trackerList": .string("https://tracker.example/announce"),
        ])
        let root = try encodedObject(request, id: 73)

        XCTAssertEqual(root["jsonrpc"], .string("2.0"))
        XCTAssertEqual(root["method"], .string("torrent_set"))
        XCTAssertEqual(root["id"], .int(73))
        let params = try XCTUnwrap(root["params"]?.objectValue)
        XCTAssertEqual(params["ids"], .array([.int(4)]))
        XCTAssertEqual(params["bandwidth_priority"], .int(1))
        XCTAssertEqual(params["files_wanted"], .array([.int(0), .int(2)]))
        XCTAssertEqual(params["tracker_list"], .string("https://tracker.example/announce"))

        let fieldsRequest = RPCRequest(method: "torrent-get", arguments: [
            "ids": .string("recently-active"),
            "fields": .array([
                .string("corruptEver"),
                .string("hashString"),
                .string("fileStats"),
                .string("nextAnnounceTime"),
            ]),
        ])
        let fieldsParams = try XCTUnwrap(try encodedObject(fieldsRequest, id: 74)["params"]?.objectValue)
        XCTAssertEqual(fieldsParams["ids"], .string("recently_active"))
        XCTAssertEqual(
            fieldsParams["fields"],
            .array([.string("corrupt_ever"), .string("hash_string"), .string("file_stats")])
        )
    }

    func testJSONRPCSessionAliasesNormalizeWithoutChangingLegacyModels() throws {
        let arguments = try decodeJSON(
            request: RPCRequest(method: "session-get"),
            id: 5,
            result: [
                "rpc_version": .int(18),
                "rpc_version_semver": .string("6.0.0"),
                "download_dir": .string("/json"),
                "cache_size_mib": .int(64),
                "preferred_transports": .array([.string("utp"), .string("tcp")]),
                "encryption": .string("allowed"),
                "seed_ratio_limited": .bool(true),
            ]
        )

        XCTAssertEqual(arguments["rpc-version"], .int(18))
        XCTAssertEqual(arguments["rpc-version-semver"], .string("6.0.0"))
        XCTAssertEqual(arguments["download-dir"], .string("/json"))
        XCTAssertEqual(arguments["cache-size-mb"], .int(64))
        XCTAssertEqual(arguments["utp-enabled"], .bool(true))
        XCTAssertEqual(arguments["encryption"], .string("tolerated"))
        XCTAssertEqual(arguments["seedRatioLimited"], .bool(true))

        let enabledTransportRequest = RPCRequest(
            method: "session-set",
            arguments: ["utp-enabled": .bool(true)]
        )
        let enabledParams = try XCTUnwrap(try encodedObject(enabledTransportRequest, id: 6)["params"]?.objectValue)
        XCTAssertEqual(enabledParams["preferred_transports"], .array([.string("utp"), .string("tcp")]))

        let disabledTransportRequest = RPCRequest(
            method: "session-set",
            arguments: ["utp-enabled": .bool(false), "cache-size-mb": .int(32)]
        )
        let params = try XCTUnwrap(try encodedObject(disabledTransportRequest, id: 7)["params"]?.objectValue)
        XCTAssertEqual(params["preferred_transports"], .array([.string("tcp")]))
        XCTAssertEqual(params["cache_size_mib"], .int(32))
    }

    func testJSONRPCPieceFieldsEncodeAndDecodeThroughTheAdapter() throws {
        let request = RPCRequest(method: "torrent-get", arguments: [
            "ids": .array([.int(8)]),
            "fields": .array([.string("pieceCount"), .string("pieces")]),
        ])
        let params = try XCTUnwrap(try encodedObject(request, id: 75)["params"]?.objectValue)
        XCTAssertEqual(
            params["fields"],
            .array([.string("piece_count"), .string("pieces")])
        )

        let arguments = try decodeJSON(
            request: request,
            id: 75,
            result: [
                "torrents": .array([.object([
                    "id": .int(8),
                    "piece_count": .int(5),
                    "pieces": .string("qA=="),
                ])]),
            ]
        )
        let torrent = try XCTUnwrap(TorrentGetResponse(validating: arguments).torrents.first)

        XCTAssertEqual(torrent.pieceCount, 5)
        guard case .available(let pieceMap) = torrent.pieceMapState else {
            return XCTFail("Expected the adapter to preserve the typed piece bitfield")
        }
        XCTAssertEqual(pieceMap.completedPieceCount, 3)
    }

    func testJSONRPCTorrentObjectNormalizesNestedPeersFilesAndTrackers() throws {
        let arguments = try decodeJSON(
            request: RPCRequest(method: "torrent-get"),
            id: 9,
            result: [
                "torrents": .array([.object([
                    "id": .int(8),
                    "corrupt_ever": .int(512),
                    "hash_string": .string("abc"),
                    "rate_download": .int(1024),
                    "files": .array([.object([
                        "name": .string("payload.bin"),
                        "length": .int(10),
                        "bytes_completed": .int(4),
                    ])]),
                    "file_stats": .array([.object([
                        "bytes_completed": .int(4),
                        "wanted": .bool(true),
                        "priority": .int(0),
                    ])]),
                    "peers": .array([.object([
                        "address": .string("203.0.113.2"),
                        "client_name": .string("Transmission"),
                        "flag_str": .string("D"),
                        "rate_to_client": .int(100),
                        "rate_to_peer": .int(20),
                    ])]),
                    "tracker_stats": .array([.object([
                        "announce": .string("https://tracker.example/announce"),
                        "announce_state": .int(1),
                        "next_announce_time": .int(1_735_704_000),
                        "seeder_count": .int(10),
                    ])]),
                ])]),
            ]
        )

        let torrent = try XCTUnwrap(TorrentGetResponse(validating: arguments).torrents.first)
        XCTAssertEqual(torrent.hashString, "abc")
        XCTAssertEqual(torrent["corruptEver"], .int(512))
        XCTAssertEqual(torrent.rateDownload, 1_024)
        XCTAssertEqual(torrent.files?.first?.objectValue?["bytesCompleted"], .int(4))
        XCTAssertEqual(torrent.fileStats?.first?.objectValue?["bytesCompleted"], .int(4))
        XCTAssertEqual(torrent.peers?.first?.objectValue?["clientName"], .string("Transmission"))
        XCTAssertEqual(torrent.peers?.first?.objectValue?["rateToClient"], .int(100))
        XCTAssertEqual(torrent.trackerStats?.first?.objectValue?["nextAnnounceTime"], .int(1_735_704_000))
        XCTAssertEqual(torrent.trackerStats?.first?.objectValue?["seederCount"], .int(10))
    }

    func testJSONRPCTorrentTableNormalizesHeaderAndSeparateFieldForms() throws {
        let headerArguments = try decodeJSON(
            request: RPCRequest(method: "torrent-get"),
            id: 12,
            result: [
                "torrents": .array([
                    .array([.string("id"), .string("hash_string"), .string("rate_download")]),
                    .array([.int(1), .string("one"), .int(200)]),
                ]),
            ]
        )
        XCTAssertEqual(try TorrentGetResponse(validating: headerArguments).torrents.first?.hashString, "one")
        XCTAssertEqual(try TorrentGetResponse(validating: headerArguments).torrents.first?.rateDownload, 200)

        let fieldsArguments = try decodeJSON(
            request: RPCRequest(method: "torrent-get"),
            id: 13,
            result: [
                "fields": .array([
                    .string("id"),
                    .string("name"),
                    .string("total_size"),
                    .string("tracker_stats"),
                    .string("file_stats"),
                    .string("peers"),
                ]),
                "torrents": .array([.array([
                    .int(2),
                    .string("two"),
                    .int(400),
                    .array([.object([
                        "announce_state": .int(1),
                        "seeder_count": .int(12),
                    ])]),
                    .array([.object(["bytes_completed": .int(300)])]),
                    .array([.object([
                        "client_name": .string("Transmission"),
                        "rate_to_client": .int(50),
                    ])]),
                ])]),
            ]
        )
        let torrent = try XCTUnwrap(TorrentGetResponse(validating: fieldsArguments).torrents.first)
        XCTAssertEqual(torrent.name, "two")
        XCTAssertEqual(torrent.totalSize, 400)
        XCTAssertEqual(torrent.trackerStats?.first?.objectValue?["announceState"], .int(1))
        XCTAssertEqual(torrent.trackerStats?.first?.objectValue?["seederCount"], .int(12))
        XCTAssertEqual(torrent.fileStats?.first?.objectValue?["bytesCompleted"], .int(300))
        XCTAssertEqual(torrent.peers?.first?.objectValue?["clientName"], .string("Transmission"))
        XCTAssertEqual(torrent.peers?.first?.objectValue?["rateToClient"], .int(50))
    }

    func testJSONRPCStatsAddAndFreeSpaceNormalizeByMethodContext() throws {
        let stats = try decodeJSON(
            request: RPCRequest(method: "session-stats"),
            id: 20,
            result: [
                "active_torrent_count": .int(2),
                "download_speed": .int(500),
                "current_stats": .object(["uploaded_bytes": .int(12), "files_added": .int(3)]),
                "cumulative_stats": .object(["downloaded_bytes": .int(44), "seconds_active": .int(60)]),
            ]
        )
        XCTAssertEqual(SessionStats(arguments: stats).activeTorrentCount, 2)
        XCTAssertEqual(SessionStats(arguments: stats).current.uploadedBytes, 12)
        XCTAssertEqual(SessionStats(arguments: stats).cumulative.downloadedBytes, 44)

        let add = try decodeJSON(
            request: RPCRequest(method: "torrent-add"),
            id: 21,
            result: [
                "torrent_added": .object([
                    "id": .int(7),
                    "name": .string("Seven"),
                    "hash_string": .string("hash-seven"),
                ]),
            ]
        )
        XCTAssertEqual(try TorrentAddResult(arguments: add).hashString, "hash-seven")

        let freeSpace = try decodeJSON(
            request: RPCRequest(method: "free-space"),
            id: 22,
            result: ["size_bytes": .int(123), "total_size": .int(456)]
        )
        XCTAssertEqual(freeSpace["size-bytes"], .int(123))
        XCTAssertEqual(freeSpace["total-size"], .int(456))
    }

    func testMaintenanceMethodsAdaptArgumentsAndNormalizeResults() throws {
        let portRequest = RPCRequest(
            method: "port-test",
            arguments: ["ip-protocol": .string("ipv6")]
        )
        let encodedPort = try encodedObject(portRequest, id: 24)
        XCTAssertEqual(encodedPort["method"], .string("port_test"))
        XCTAssertEqual(
            encodedPort["params"]?.objectValue?["ip_protocol"],
            .string("ipv6")
        )

        let portResult = try decodeJSON(
            request: portRequest,
            id: 24,
            result: [
                "port_is_open": .bool(true),
                "ip_protocol": .string("ipv6"),
            ]
        )
        XCTAssertEqual(portResult["port-is-open"], .bool(true))
        XCTAssertEqual(portResult["ip-protocol"], .string("ipv6"))

        let blocklistRequest = RPCRequest(method: "blocklist-update")
        let encodedBlocklist = try encodedObject(blocklistRequest, id: 25)
        XCTAssertEqual(encodedBlocklist["method"], .string("blocklist_update"))
        XCTAssertEqual(encodedBlocklist["params"], .object([:]))
        let blocklistResult = try decodeJSON(
            request: blocklistRequest,
            id: 25,
            result: ["blocklist_size": .int(12_345)]
        )
        XCTAssertEqual(blocklistResult["blocklist-size"], .int(12_345))
    }

    func testPortTestErrorPreservesReportedProtocolArguments() throws {
        let response = JSONValue.object([
            "jsonrpc": .string("2.0"),
            "error": .object([
                "code": .int(5),
                "message": .string("Port test failed"),
                "data": .object([
                    "result": .object(["ip_protocol": .string("ipv6")]),
                ]),
            ]),
            "id": .int(26),
        ])

        XCTAssertThrowsError(
            try RPCProtocolAdapter.decode(
                JSONEncoder().encode(response),
                for: RPCRequest(method: "port-test", arguments: [
                    "ip-protocol": .string("ipv6")
                ]),
                protocol: jsonProtocol,
                expectedID: 26,
                returnArguments: true
            )
        ) { error in
            guard case TransmissionRPCError.rpcFailureWithArguments(let message, let arguments) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(message, "Port test failed")
            XCTAssertEqual(arguments["ip-protocol"], .string("ipv6"))
        }
    }

    func testJSONRPCValidatesResponseIDAndStructuredErrors() throws {
        XCTAssertThrowsError(
            try decodeJSON(
                request: RPCRequest(method: "session-get"),
                id: 30,
                responseID: 31,
                result: [:]
            )
        ) { error in
            guard case TransmissionRPCError.invalidResponse = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        let response = JSONValue.object([
            "jsonrpc": .string("2.0"),
            "error": .object([
                "code": .int(7),
                "message": .string("Backend failed"),
                "data": .object(["error_string": .string("No response")]),
            ]),
            "id": .int(32),
        ])
        XCTAssertThrowsError(
            try RPCProtocolAdapter.decode(
                JSONEncoder().encode(response),
                for: RPCRequest(method: "port-test"),
                protocol: jsonProtocol,
                expectedID: 32,
                returnArguments: true
            )
        ) { error in
            guard case TransmissionRPCError.rpcFailure(let message) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(message, "Backend failed: No response")
        }

        let malformedError = JSONValue.object([
            "jsonrpc": .string("2.0"),
            "error": .object(["message": .string("Missing code")]),
            "id": .int(33),
        ])
        XCTAssertThrowsError(
            try RPCProtocolAdapter.decode(
                JSONEncoder().encode(malformedError),
                for: RPCRequest(method: "session-get"),
                protocol: jsonProtocol,
                expectedID: 33,
                returnArguments: true
            )
        ) { error in
            guard case TransmissionRPCError.invalidResponse = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testJSONRPCModeNeverFallsBackToLegacyResponse() throws {
        XCTAssertThrowsError(
            try RPCProtocolAdapter.decode(
                Data(#"{"result":"success","arguments":{}}"#.utf8),
                for: RPCRequest(method: "session-get"),
                protocol: jsonProtocol,
                expectedID: 40,
                returnArguments: true
            )
        ) { error in
            guard case TransmissionRPCError.invalidResponse = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    private func encodedObject(_ request: RPCRequest, id: Int) throws -> RPCArguments {
        let data = try RPCProtocolAdapter.encode(request, protocol: jsonProtocol, id: id)
        return try XCTUnwrap(JSONDecoder().decode(JSONValue.self, from: data).objectValue)
    }

    private func decodeJSON(
        request: RPCRequest,
        id: Int,
        responseID: Int? = nil,
        result: RPCArguments
    ) throws -> RPCArguments {
        let response = JSONValue.object([
            "jsonrpc": .string("2.0"),
            "result": .object(result),
            "id": .int(responseID ?? id),
        ])
        return try RPCProtocolAdapter.decode(
            JSONEncoder().encode(response),
            for: request,
            protocol: jsonProtocol,
            expectedID: id,
            returnArguments: true
        )
    }
}
