// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import XCTest
@testable import TransmissionRemoteMac

final class TransmissionRPCActionsTests: XCTestCase {
    override func tearDown() {
        ActionMockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testTorrentActionMethodsSendExpectedPayloads() async throws {
        let recorder = ActionRequestRecorder()
        ActionMockURLProtocol.requestHandler = { request in
            _ = recorder.record(request)
            return Self.response(body: #"{"result":"success"}"#)
        }

        let client = TransmissionRPCClient(profile: .localDefault, urlSession: mockSession())

        try await client.start(ids: [1, 2])
        try await client.startNow(ids: [1, 2])
        try await client.stop(ids: [1, 2])
        let hashes = [String(repeating: "1", count: 40), String(repeating: "2", count: 40)]
        try await client.verify(hashes: hashes)
        try await client.reannounce(ids: [1, 2])
        try await client.queueMoveTop(ids: [1, 2])
        try await client.queueMoveUp(ids: [1, 2])
        try await client.queueMoveDown(ids: [1, 2])
        try await client.queueMoveBottom(ids: [1, 2])

        let bodies = try recorder.requests.map(Self.decodedBody)
        XCTAssertEqual(bodies.map(\.method), [
            "torrent-start",
            "torrent-start-now",
            "torrent-stop",
            "torrent-verify",
            "torrent-reannounce",
            "queue-move-top",
            "queue-move-up",
            "queue-move-down",
            "queue-move-bottom",
        ])
        for body in bodies {
            let expectedIDs: JSONValue = body.method == "torrent-verify"
                ? .array(hashes.map(JSONValue.string))
                : .array([.int(1), .int(2)])
            XCTAssertEqual(body.arguments["ids"], expectedIDs)
        }
    }

    func testStartAndStopAllOmitIds() async throws {
        let recorder = ActionRequestRecorder()
        ActionMockURLProtocol.requestHandler = { request in
            _ = recorder.record(request)
            return Self.response(body: #"{"result":"success"}"#)
        }

        let client = TransmissionRPCClient(profile: .localDefault, urlSession: mockSession())

        try await client.start()
        try await client.stop()

        let bodies = try recorder.requests.map(Self.decodedBody)
        XCTAssertEqual(bodies.map(\.method), ["torrent-start", "torrent-stop"])
        XCTAssertTrue(bodies.allSatisfy { $0.arguments["ids"] == nil })
    }

    func testActionSurfacesTransmissionResultFailure() async throws {
        ActionMockURLProtocol.requestHandler = { _ in
            Self.response(body: #"{"result":"invalid torrent id"}"#)
        }

        let client = TransmissionRPCClient(profile: .localDefault, urlSession: mockSession())

        do {
            try await client.stop(ids: [99])
            XCTFail("action should surface Transmission result failures")
        } catch TransmissionRPCError.rpcFailure(let message) {
            XCTAssertEqual(message, "invalid torrent id")
            XCTAssertEqual(
                TransmissionRPCError.rpcFailure(message).localizedDescription,
                "Transmission RPC failed: invalid torrent id"
            )
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testRemoveUsesStableHashesAndDeleteLocalDataFlag() async throws {
        let recorder = ActionRequestRecorder()
        ActionMockURLProtocol.requestHandler = { request in
            _ = recorder.record(request)
            return Self.response(body: #"{"result":"success"}"#)
        }

        let client = TransmissionRPCClient(profile: .localDefault, urlSession: mockSession())

        try await client.remove(hashes: ["abc", "def"], deleteLocalData: false)
        try await client.remove(hashes: ["abc", "def"], deleteLocalData: true)

        let bodies = try recorder.requests.map(Self.decodedBody)
        XCTAssertEqual(bodies.map(\.method), ["torrent-remove", "torrent-remove"])
        XCTAssertEqual(bodies[0].arguments["ids"], .array([.string("abc"), .string("def")]))
        XCTAssertEqual(bodies[0].arguments["delete-local-data"], .bool(false))
        XCTAssertEqual(bodies[1].arguments["ids"], .array([.string("abc"), .string("def")]))
        XCTAssertEqual(bodies[1].arguments["delete-local-data"], .bool(true))
    }

    func testSetLocationPreservesValidDestinationBytesInMoveDataPayload() async throws {
        let recorder = ActionRequestRecorder()
        ActionMockURLProtocol.requestHandler = { request in
            let index = recorder.record(request)
            if index == 0 {
                return Self.response(body: #"{"result":"success","arguments":{"rpc-version":6}}"#)
            }
            return Self.response(body: #"{"result":"success"}"#)
        }

        let client = TransmissionRPCClient(profile: .localDefault, urlSession: mockSession())

        _ = try await client.getSession()
        let hashes = [String(repeating: "2", count: 40), String(repeating: "4", count: 40)]
        try await client.setLocation(hashes: hashes, location: "/srv/complete ", moveData: true)

        let bodies = try recorder.requests.map(Self.decodedBody)
        XCTAssertEqual(bodies.map(\.method), ["session-get", "torrent-set-location"])
        let body = bodies[1]
        XCTAssertEqual(body.method, "torrent-set-location")
        XCTAssertEqual(body.arguments["ids"], .array(hashes.map(JSONValue.string)))
        XCTAssertEqual(body.arguments["location"], .string("/srv/complete "))
        XCTAssertEqual(body.arguments["move"], .bool(true))
    }

    func testSetLocationCanTargetStableTorrentHashes() async throws {
        let recorder = ActionRequestRecorder()
        ActionMockURLProtocol.requestHandler = { request in
            let index = recorder.record(request)
            if index == 0 {
                return Self.response(body: #"{"result":"success","arguments":{"rpc-version":6}}"#)
            }
            return Self.response(body: #"{"result":"success"}"#)
        }
        let client = TransmissionRPCClient(profile: .localDefault, urlSession: mockSession())

        _ = try await client.getSession()
        try await client.setLocation(
            hashes: [
                "ABCDEF0123456789ABCDEF0123456789ABCDEF01",
                "1234567890ABCDEF1234567890ABCDEF12345678",
            ],
            location: "/srv/complete",
            moveData: false
        )

        let bodies = try recorder.requests.map(Self.decodedBody)
        XCTAssertEqual(bodies.map(\.method), ["session-get", "torrent-set-location"])
        let body = bodies[1]
        XCTAssertEqual(body.method, "torrent-set-location")
        XCTAssertEqual(
            body.arguments["ids"],
            .array([
                .string("abcdef0123456789abcdef0123456789abcdef01"),
                .string("1234567890abcdef1234567890abcdef12345678"),
            ])
        )
        XCTAssertEqual(body.arguments["location"], .string("/srv/complete"))
        XCTAssertEqual(body.arguments["move"], .bool(false))
    }

    func testVerifyCanTargetCanonicalDeduplicatedTorrentHashes() async throws {
        let recorder = ActionRequestRecorder()
        ActionMockURLProtocol.requestHandler = { request in
            _ = recorder.record(request)
            return Self.response(body: #"{"result":"success"}"#)
        }
        let client = TransmissionRPCClient(profile: .localDefault, urlSession: mockSession())

        try await client.verify(hashes: [
            " ABCDEF0123456789ABCDEF0123456789ABCDEF01 ",
            "1234567890ABCDEF1234567890ABCDEF12345678",
            "abcdef0123456789abcdef0123456789abcdef01",
        ])

        let body = try XCTUnwrap(recorder.requests.first).decodedActionBody()
        XCTAssertEqual(recorder.requests.count, 1)
        XCTAssertEqual(body.method, "torrent-verify")
        XCTAssertEqual(
            body.arguments["ids"],
            .array([
                .string("abcdef0123456789abcdef0123456789abcdef01"),
                .string("1234567890abcdef1234567890abcdef12345678"),
            ])
        )
    }

    func testVerifyRejectsInvalidHashesWithoutSendingRequest() async throws {
        let recorder = ActionRequestRecorder()
        ActionMockURLProtocol.requestHandler = { request in
            _ = recorder.record(request)
            return Self.response(body: #"{"result":"success"}"#)
        }
        let client = TransmissionRPCClient(profile: .localDefault, urlSession: mockSession())

        let invalidTargets = [
            [],
            [
                "abcdef0123456789abcdef0123456789abcdef01",
                "not-a-canonical-hash",
            ],
        ]
        for hashes in invalidTargets {
            do {
                try await client.verify(hashes: hashes)
                XCTFail("invalid verify hashes should fail before sending")
            } catch TransmissionRPCError.invalidArguments {
            } catch {
                XCTFail("unexpected error: \(error)")
            }
        }

        XCTAssertTrue(recorder.requests.isEmpty)
    }

    func testSetLocationRejectsInvalidDestinationsBeforeSendingMutation() async throws {
        let recorder = ActionRequestRecorder()
        ActionMockURLProtocol.requestHandler = { request in
            let index = recorder.record(request)
            if index == 0 {
                return Self.response(body: #"{"result":"success","arguments":{"rpc-version":6}}"#)
            }
            return Self.response(body: #"{"result":"success"}"#)
        }
        let client = TransmissionRPCClient(profile: .localDefault, urlSession: mockSession())
        _ = try await client.getSession()

        let invalidDestinations: [(String, RemotePOSIXDestinationValidationError)] = [
            (" /srv/data", .notAbsolute),
            ("srv/data", .notAbsolute),
            ("", .empty),
            ("/srv/\0data", .containsNullByte),
        ]
        for (destination, expectedError) in invalidDestinations {
            for moveData in [false, true] {
                do {
                    try await client.setLocation(
                        hashes: ["abcdef0123456789abcdef0123456789abcdef01"],
                        location: destination,
                        moveData: moveData
                    )
                    XCTFail("invalid destination should fail before sending: \(destination)")
                } catch let error as RemotePOSIXDestinationValidationError {
                    XCTAssertEqual(error, expectedError)
                } catch {
                    XCTFail("unexpected error: \(error)")
                }
            }
        }

        XCTAssertEqual(recorder.requests.count, 1)
        XCTAssertEqual(try Self.decodedBody(from: recorder.requests[0]).method, "session-get")
    }

    func testSetLocationRejectsRPC5BeforeSendingSetLocationOrMoveMutation() async throws {
        let rpc5Recorder = ActionRequestRecorder()
        ActionMockURLProtocol.requestHandler = { request in
            _ = rpc5Recorder.record(request)
            return Self.response(body: #"{"result":"success","arguments":{"rpc-version":5}}"#)
        }
        let rpc5Client = TransmissionRPCClient(profile: .localDefault, urlSession: mockSession())
        _ = try await rpc5Client.getSession()

        for moveData in [false, true] {
            do {
                try await rpc5Client.setLocation(
                    hashes: ["abcdef0123456789abcdef0123456789abcdef01"],
                    location: "relative",
                    moveData: moveData
                )
                XCTFail("set location should be gated below RPC 6")
            } catch TransmissionRPCError.unsupportedRPCVersion(let feature, let required, let actual) {
                XCTAssertEqual(feature, "Set torrent location")
                XCTAssertEqual(required, 6)
                XCTAssertEqual(actual, 5)
            } catch {
                XCTFail("unexpected error: \(error)")
            }
        }

        XCTAssertEqual(rpc5Recorder.requests.count, 1)
        XCTAssertEqual(try Self.decodedBody(from: rpc5Recorder.requests[0]).method, "session-get")
    }

    func testRenamePathRequiresRPC15AndSendsPayload() async throws {
        let recorder = ActionRequestRecorder()
        ActionMockURLProtocol.requestHandler = { request in
            let index = recorder.record(request)
            if index == 0 {
                return Self.response(body: #"{"result":"success","arguments":{"rpc-version":15,"version":"4.0","download-dir":"/downloads"}}"#)
            }
            return Self.response(body: #"{"result":"success"}"#)
        }

        let client = TransmissionRPCClient(profile: .localDefault, urlSession: mockSession())

        _ = try await client.getSession()
        let hash = String(repeating: "b", count: 40)
        try await client.renamePath(hash: hash, path: "Old Name", name: " New Name ")

        let bodies = try recorder.requests.map(Self.decodedBody)
        XCTAssertEqual(bodies.map(\.method), ["session-get", "torrent-rename-path"])
        XCTAssertEqual(bodies[1].arguments["ids"], .array([.string(hash)]))
        XCTAssertEqual(bodies[1].arguments["path"], .string("Old Name"))
        XCTAssertEqual(bodies[1].arguments["name"], .string("New Name"))
    }

    func testRenamePathCanTargetAStableTorrentHash() async throws {
        let recorder = ActionRequestRecorder()
        ActionMockURLProtocol.requestHandler = { request in
            let index = recorder.record(request)
            if index == 0 {
                return Self.response(body: #"{"result":"success","arguments":{"rpc-version":15}}"#)
            }
            return Self.response(body: #"{"result":"success"}"#)
        }
        let client = TransmissionRPCClient(profile: .localDefault, urlSession: mockSession())

        _ = try await client.getSession()
        try await client.renamePath(
            hash: "ABCDEF0123456789ABCDEF0123456789ABCDEF01",
            path: "Old Name",
            name: "New Name"
        )

        let bodies = try recorder.requests.map(Self.decodedBody)
        XCTAssertEqual(bodies.map(\.method), ["session-get", "torrent-rename-path"])
        XCTAssertEqual(
            bodies[1].arguments["ids"],
            .array([.string("abcdef0123456789abcdef0123456789abcdef01")])
        )
    }

    func testValidatedRenamePathPrefersStableHashAndPreservesExactPath() async throws {
        let recorder = ActionRequestRecorder()
        ActionMockURLProtocol.requestHandler = { request in
            let index = recorder.record(request)
            if index == 0 {
                return Self.response(body: #"{"result":"success","arguments":{"rpc-version":15,"version":"4.0","download-dir":"/downloads"}}"#)
            }
            return Self.response(body: #"{"result":"success"}"#)
        }
        let client = TransmissionRPCClient(profile: .localDefault, urlSession: mockSession())
        let owner = TorrentPathRenameOwner(
            connectionToken: UUID(),
            profileID: UUID(),
            selectionRevision: 1,
            paneRevision: 2,
            filesRevision: UUID()
        )
        let request = try TorrentPathRenameValidator.request(
            torrentHash: "ABCDEF0123456789ABCDEF0123456789ABCDEF01",
            torrentID: 11,
            owner: owner,
            nodeID: "folder-Old Name/Season 1",
            nodeKind: .folder,
            oldRelativePath: "Old Name/Season 1",
            originalBasename: "Season 1",
            newBasename: "Season One"
        )

        _ = try await client.getSession()
        try await client.renamePath(request)

        let bodies = try recorder.requests.map(Self.decodedBody)
        XCTAssertEqual(bodies.map(\.method), ["session-get", "torrent-rename-path"])
        XCTAssertEqual(
            bodies[1].arguments["ids"],
            .array([.string("abcdef0123456789abcdef0123456789abcdef01")])
        )
        XCTAssertEqual(bodies[1].arguments["path"], .string("Old Name/Season 1"))
        XCTAssertEqual(bodies[1].arguments["name"], .string("Season One"))
    }

    func testRenamePathRejectsUnsupportedRPCVersionBeforeSendingAction() async throws {
        let recorder = ActionRequestRecorder()
        ActionMockURLProtocol.requestHandler = { request in
            _ = recorder.record(request)
            return Self.response(body: #"{"result":"success","arguments":{"rpc-version":14,"version":"3.0","download-dir":"/downloads"}}"#)
        }

        let client = TransmissionRPCClient(profile: .localDefault, urlSession: mockSession())

        _ = try await client.getSession()

        do {
            try await client.renamePath(hash: String(repeating: "b", count: 40), path: "Old Name", name: "New Name")
            XCTFail("rename should be gated below RPC 15")
        } catch TransmissionRPCError.unsupportedRPCVersion(let feature, let required, let actual) {
            XCTAssertEqual(feature, "Rename torrent path")
            XCTAssertEqual(required, 15)
            XCTAssertEqual(actual, 14)
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        XCTAssertEqual(recorder.requests.count, 1)
    }

    func testFreeSpaceRequiresRPC15AndSendsPayload() async throws {
        let recorder = ActionRequestRecorder()
        ActionMockURLProtocol.requestHandler = { request in
            let index = recorder.record(request)
            if index == 0 {
                return Self.response(body: #"{"result":"success","arguments":{"rpc-version":15,"version":"4.0","download-dir":"/downloads"}}"#)
            }
            return Self.response(body: #"{"result":"success","arguments":{"size-bytes":123456789}}"#)
        }

        let client = TransmissionRPCClient(profile: .localDefault, urlSession: mockSession())

        _ = try await client.getSession()
        let sizeBytes = try await client.freeSpace(path: " /srv/downloads ")

        let bodies = try recorder.requests.map(Self.decodedBody)
        XCTAssertEqual(sizeBytes, 123_456_789)
        XCTAssertEqual(bodies.map(\.method), ["session-get", "free-space"])
        XCTAssertEqual(bodies[1].arguments["path"], .string("/srv/downloads"))
    }

    func testFreeSpaceRejectsUnsupportedRPCVersionBeforeSendingProbe() async throws {
        let recorder = ActionRequestRecorder()
        ActionMockURLProtocol.requestHandler = { request in
            _ = recorder.record(request)
            return Self.response(body: #"{"result":"success","arguments":{"rpc-version":14,"version":"3.0","download-dir":"/downloads"}}"#)
        }

        let client = TransmissionRPCClient(profile: .localDefault, urlSession: mockSession())

        _ = try await client.getSession()

        do {
            _ = try await client.freeSpace(path: "/srv/downloads")
            XCTFail("free-space should be gated below RPC 15")
        } catch TransmissionRPCError.unsupportedRPCVersion(let feature, let required, let actual) {
            XCTAssertEqual(feature, "Free space probe")
            XCTAssertEqual(required, 15)
            XCTAssertEqual(actual, 14)
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        XCTAssertEqual(recorder.requests.count, 1)
    }

    func testTorrentSetPriorityAndLabelsPayloads() async throws {
        let recorder = ActionRequestRecorder()
        ActionMockURLProtocol.requestHandler = { request in
            _ = recorder.record(request)
            return Self.response(body: #"{"result":"success"}"#)
        }

        let client = TransmissionRPCClient(profile: .localDefault, urlSession: mockSession())

        try await client.setBandwidthPriority(.high, ids: [9])
        try await client.setLabels(fromCommaSeparatedText: " beta, alpha,  , zulu ", ids: [9])

        let bodies = try recorder.requests.map(Self.decodedBody)
        XCTAssertEqual(bodies[0].method, "torrent-set")
        XCTAssertEqual(bodies[0].arguments["ids"], .array([.int(9)]))
        XCTAssertEqual(bodies[0].arguments["bandwidthPriority"], .int(1))
        XCTAssertEqual(bodies[1].method, "torrent-set")
        XCTAssertEqual(bodies[1].arguments["ids"], .array([.int(9)]))
        XCTAssertEqual(bodies[1].arguments["labels"], .array([.string("alpha"), .string("beta"), .string("zulu")]))
    }

    func testFetchTorrentPropertiesRequestsTrackerListOnRPC17AndDecodesSnapshot() async throws {
        let recorder = ActionRequestRecorder()
        ActionMockURLProtocol.requestHandler = { request in
            let index = recorder.record(request)
            if index == 0 {
                return Self.response(body: #"{"result":"success","arguments":{"rpc-version":17,"version":"4.0","download-dir":"/downloads"}}"#)
            }
            return Self.response(
                body: #"""
                {
                  "result": "success",
                  "arguments": {
                    "torrents": [{
                      "id": 9,
                      "hashString": "9999999999999999999999999999999999999999",
                      "name": "Debian ISO",
                      "downloadLimited": true,
                      "downloadLimit": 700,
                      "uploadLimited": false,
                      "uploadLimit": 50,
                      "maxConnectedPeers": 40,
                      "seedRatioMode": 1,
                      "seedRatioLimit": 2.5,
                      "seedIdleMode": 1,
                      "seedIdleLimit": 30,
                      "trackerList": "https://one.example/announce\n\nhttps://two.example/announce"
                    }]
                  }
                }
                """#
            )
        }

        let client = TransmissionRPCClient(profile: .localDefault, urlSession: mockSession())

        _ = try await client.getSession()
        let hash = String(repeating: "9", count: 40)
        let snapshot = try await client.fetchTorrentProperties(id: 9, hash: hash)

        let bodies = try recorder.requests.map(Self.decodedBody)
        let fields = try XCTUnwrap(bodies[1].arguments["fields"]?.arrayValue?.compactMap(\.stringValue))
        XCTAssertEqual(bodies.map(\.method), ["session-get", "torrent-get"])
        XCTAssertEqual(bodies[1].arguments["ids"], .array([.string(hash)]))
        XCTAssertTrue(fields.contains("hashString"))
        XCTAssertTrue(fields.contains("trackerList"))
        XCTAssertFalse(fields.contains("trackers"))
        XCTAssertEqual(snapshot.id, 9)
        XCTAssertEqual(snapshot.name, "Debian ISO")
        XCTAssertEqual(snapshot.downloadSpeedLimit, TorrentPropertiesSpeedLimit(isEnabled: true, limitKBps: 700))
        XCTAssertEqual(snapshot.uploadSpeedLimit, TorrentPropertiesSpeedLimit(isEnabled: false, limitKBps: 50))
        XCTAssertEqual(snapshot.peerLimit, 40)
        XCTAssertEqual(snapshot.seedRatio, TorrentPropertiesLimitSetting(mode: .single, limit: 2.5))
        XCTAssertEqual(snapshot.seedIdle, TorrentPropertiesLimitSetting(mode: .single, limit: 30))
        XCTAssertEqual(snapshot.trackerText, "https://one.example/announce\n\nhttps://two.example/announce")
    }

    func testFetchTorrentPropertiesRejectsMismatchedResponseIdentity() async throws {
        let hash = String(repeating: "a", count: 40)
        let otherHash = String(repeating: "b", count: 40)
        for (returnedID, returnedHash) in [(10, hash), (9, otherHash), (9, "")] {
            ActionMockURLProtocol.requestHandler = { _ in
                Self.response(
                    body: #"{"result":"success","arguments":{"torrents":[{"id":\#(returnedID),"hashString":"\#(returnedHash)"}]}}"#
                )
            }
            let client = TransmissionRPCClient(profile: .localDefault, urlSession: mockSession())
            do {
                _ = try await client.fetchTorrentProperties(id: 9, hash: hash)
                XCTFail("Properties must reject a response for another torrent identity")
            } catch TransmissionRPCError.invalidArguments {
                // The daemon response did not establish ownership of the requested torrent.
            }
        }
    }

    func testTorrentPropertiesHashMutationNormalizesAndDeduplicatesTargets() async throws {
        let recorder = ActionRequestRecorder()
        ActionMockURLProtocol.requestHandler = { request in
            _ = recorder.record(request)
            return Self.response(body: #"{"result":"success"}"#)
        }
        let hash = String(repeating: "a", count: 40)
        let client = TransmissionRPCClient(profile: .localDefault, urlSession: mockSession())
        try await client.setTorrentProperties(
            update: TorrentPropertiesUpdate(peerLimit: 80),
            hashes: [" \(hash.uppercased())\n", hash],
            rpcVersion: 17
        )
        let body = try XCTUnwrap(recorder.requests.first).decodedActionBody()
        XCTAssertEqual(body.arguments["ids"], .array([.string(hash)]))
        XCTAssertEqual(body.arguments["peer-limit"], .int(80))
    }

    func testTorrentPropertiesRejectsInvalidHashTargetsWithoutSending() async throws {
        let recorder = ActionRequestRecorder()
        ActionMockURLProtocol.requestHandler = { request in
            _ = recorder.record(request)
            return Self.response(body: #"{"result":"success"}"#)
        }
        let client = TransmissionRPCClient(profile: .localDefault, urlSession: mockSession())
        for hashes in [[], ["invalid"], [String(repeating: "a", count: 40), "invalid"]] {
            do {
                try await client.setTorrentProperties(
                    update: TorrentPropertiesUpdate(peerLimit: 80), hashes: hashes, rpcVersion: 17
                )
                XCTFail("Properties must never fall back to a broad or numeric target")
            } catch TransmissionRPCError.invalidArguments {
                // Reject the entire target set before sending any mutation.
            }
        }
        XCTAssertTrue(recorder.requests.isEmpty)
    }

    func testTorrentPropertiesLegacyRPC4SpeedPayloadUsesOldKeys() async throws {
        let recorder = ActionRequestRecorder()
        ActionMockURLProtocol.requestHandler = { request in
            _ = recorder.record(request)
            return Self.response(body: #"{"result":"success"}"#)
        }

        let client = TransmissionRPCClient(profile: .localDefault, urlSession: mockSession())
        let update = TorrentPropertiesUpdate(
            downloadSpeedLimit: TorrentPropertiesSpeedLimit(isEnabled: true, limitKBps: 111),
            uploadSpeedLimit: TorrentPropertiesSpeedLimit(isEnabled: false, limitKBps: 222),
            peerLimit: 33
        )

        let hashes = [String(repeating: "9", count: 40), String(repeating: "a", count: 40)]
        try await client.setTorrentProperties(update: update, hashes: hashes, rpcVersion: 4)

        let body = try XCTUnwrap(recorder.requests.first).decodedActionBody()
        XCTAssertEqual(body.method, "torrent-set")
        XCTAssertEqual(body.arguments["ids"], .array(hashes.map(JSONValue.string)))
        XCTAssertEqual(body.arguments["speed-limit-down-enabled"], .bool(true))
        XCTAssertEqual(body.arguments["speed-limit-down"], .int(111))
        XCTAssertEqual(body.arguments["speed-limit-up-enabled"], .bool(false))
        XCTAssertEqual(body.arguments["speed-limit-up"], nil)
        XCTAssertEqual(body.arguments["downloadLimited"], nil)
        XCTAssertEqual(body.arguments["peer-limit"], .int(33))
        XCTAssertEqual(body.arguments["seedRatioMode"], nil)
    }

    func testTorrentPropertiesModernRPC5SpeedAndSeedRatioPayloadUsesModernKeys() async throws {
        let recorder = ActionRequestRecorder()
        ActionMockURLProtocol.requestHandler = { request in
            _ = recorder.record(request)
            return Self.response(body: #"{"result":"success"}"#)
        }

        let client = TransmissionRPCClient(profile: .localDefault, urlSession: mockSession())
        let update = TorrentPropertiesUpdate(
            downloadSpeedLimit: TorrentPropertiesSpeedLimit(isEnabled: true, limitKBps: 333),
            uploadSpeedLimit: TorrentPropertiesSpeedLimit(isEnabled: true, limitKBps: 44),
            seedRatio: TorrentPropertiesLimitSetting(mode: .single, limit: 1.75)
        )

        let hash = String(repeating: "c", count: 40)
        try await client.setTorrentProperties(update: update, hashes: [hash], rpcVersion: 5)

        let body = try XCTUnwrap(recorder.requests.first).decodedActionBody()
        XCTAssertEqual(body.method, "torrent-set")
        XCTAssertEqual(body.arguments["ids"], .array([.string(hash)]))
        XCTAssertEqual(body.arguments["downloadLimited"], .bool(true))
        XCTAssertEqual(body.arguments["downloadLimit"], .int(333))
        XCTAssertEqual(body.arguments["uploadLimited"], .bool(true))
        XCTAssertEqual(body.arguments["uploadLimit"], .int(44))
        XCTAssertEqual(body.arguments["speed-limit-down-enabled"], nil)
        XCTAssertEqual(body.arguments["seedRatioMode"], .int(1))
        XCTAssertEqual(body.arguments["seedRatioLimit"], .double(1.75))
    }

    func testTorrentPropertiesRPC10SeedIdleAndPeerLimitPayload() async throws {
        let recorder = ActionRequestRecorder()
        ActionMockURLProtocol.requestHandler = { request in
            _ = recorder.record(request)
            return Self.response(body: #"{"result":"success"}"#)
        }

        let client = TransmissionRPCClient(profile: .localDefault, urlSession: mockSession())
        let update = TorrentPropertiesUpdate(
            peerLimit: 80,
            seedRatio: TorrentPropertiesLimitSetting(mode: .unlimited, limit: 9.0),
            seedIdle: TorrentPropertiesLimitSetting(mode: .single, limit: 45)
        )

        let hash = String(repeating: "3", count: 40)
        try await client.setTorrentProperties(update: update, hashes: [hash], rpcVersion: 10)

        let body = try XCTUnwrap(recorder.requests.first).decodedActionBody()
        XCTAssertEqual(body.method, "torrent-set")
        XCTAssertEqual(body.arguments["ids"], .array([.string(hash)]))
        XCTAssertEqual(body.arguments["peer-limit"], .int(80))
        XCTAssertEqual(body.arguments["seedRatioMode"], .int(2))
        XCTAssertEqual(body.arguments["seedRatioLimit"], nil)
        XCTAssertEqual(body.arguments["seedIdleMode"], .int(1))
        XCTAssertEqual(body.arguments["seedIdleLimit"], .int(45))
    }

    func testTorrentPropertiesTrackerListPayloadOnRPC17() async throws {
        let recorder = ActionRequestRecorder()
        ActionMockURLProtocol.requestHandler = { request in
            _ = recorder.record(request)
            return Self.response(body: #"{"result":"success"}"#)
        }

        let client = TransmissionRPCClient(profile: .localDefault, urlSession: mockSession())
        let edit = TorrentPropertiesTrackerEdit(
            originalTrackers: [],
            originalTrackerList: "https://old.example/announce",
            editedText: " https://one.example/announce\n\nhttps://two.example/announce "
        )
        let update = TorrentPropertiesUpdate(trackerEdit: edit)

        let hash = String(repeating: "e", count: 40)
        try await client.setTorrentProperties(update: update, hashes: [hash], rpcVersion: 17)

        let body = try XCTUnwrap(recorder.requests.first).decodedActionBody()
        XCTAssertEqual(body.method, "torrent-set")
        XCTAssertEqual(body.arguments["ids"], .array([.string(hash)]))
        XCTAssertEqual(
            body.arguments["trackerList"],
            .string("https://one.example/announce\n\nhttps://two.example/announce")
        )
        XCTAssertEqual(body.arguments["trackerAdd"], nil)
        XCTAssertEqual(body.arguments["trackerReplace"], nil)
        XCTAssertEqual(body.arguments["trackerRemove"], nil)
    }

    func testDirectTrackerActionsSendExactStableHashPayloads() async throws {
        let recorder = ActionRequestRecorder()
        ActionMockURLProtocol.requestHandler = { request in
            _ = recorder.record(request)
            return Self.response(body: #"{"result":"success"}"#)
        }

        let client = TransmissionRPCClient(profile: .localDefault, urlSession: mockSession())

        try await client.addTracker(
            announceURL: "  tracker.example/announce  ",
            torrentHash: "  frozen-hash  "
        )
        try await client.replaceTracker(
            id: 17,
            announceURL: " udp://replacement.example:6969/announce ",
            torrentHash: "frozen-hash"
        )
        try await client.removeTrackers(ids: [17, 23], torrentHash: "frozen-hash")

        let bodies = try recorder.requests.map(Self.decodedBody)
        XCTAssertEqual(bodies.map(\.method), ["torrent-set", "torrent-set", "torrent-set"])
        XCTAssertTrue(
            bodies.allSatisfy {
                $0.arguments["ids"] == .array([.string("frozen-hash")])
            }
        )
        XCTAssertEqual(
            bodies[0].arguments,
            [
                "ids": .array([.string("frozen-hash")]),
                "trackerAdd": .array([.string("tracker.example/announce")])
            ]
        )
        XCTAssertEqual(
            bodies[1].arguments,
            [
                "ids": .array([.string("frozen-hash")]),
                "trackerReplace": .array([
                    .int(17),
                    .string("udp://replacement.example:6969/announce")
                ])
            ]
        )
        XCTAssertEqual(
            bodies[2].arguments,
            [
                "ids": .array([.string("frozen-hash")]),
                "trackerRemove": .array([.int(17), .int(23)])
            ]
        )
    }

    func testDirectTrackerActionsRejectInvalidInputWithoutSendingRequests() async throws {
        let recorder = ActionRequestRecorder()
        ActionMockURLProtocol.requestHandler = { request in
            _ = recorder.record(request)
            return Self.response(body: #"{"result":"success"}"#)
        }

        let client = TransmissionRPCClient(profile: .localDefault, urlSession: mockSession())

        await assertInvalidTrackerArguments {
            try await client.addTracker(announceURL: " \n ", torrentHash: "frozen-hash")
        }
        await assertInvalidTrackerArguments {
            try await client.addTracker(announceURL: "tracker.example/announce", torrentHash: " ")
        }
        await assertInvalidTrackerArguments {
            try await client.replaceTracker(id: -1, announceURL: "tracker.example/announce", torrentHash: "frozen-hash")
        }
        await assertInvalidTrackerArguments {
            try await client.replaceTracker(id: 17, announceURL: "\t", torrentHash: "frozen-hash")
        }
        await assertInvalidTrackerArguments {
            try await client.removeTrackers(ids: [], torrentHash: "frozen-hash")
        }
        await assertInvalidTrackerArguments {
            try await client.removeTrackers(ids: [17, -23], torrentHash: "frozen-hash")
        }
        await assertInvalidTrackerArguments {
            try await client.removeTrackers(ids: [17], torrentHash: "\n")
        }

        XCTAssertTrue(recorder.requests.isEmpty)
    }

    func testTorrentPropertiesTrackerDiffPlannerCoversUnchangedAddReplaceAndRemove() {
        let original = [
            TorrentPropertiesTracker(id: 10, announce: "https://one.example/announce"),
            TorrentPropertiesTracker(id: 20, announce: "https://two.example/announce"),
            TorrentPropertiesTracker(id: 30, announce: "https://three.example/announce")
        ]

        XCTAssertTrue(
            TorrentPropertiesTrackerEdit(
                originalTrackers: original,
                editedText: "https://one.example/announce\nhttps://two.example/announce\nhttps://three.example/announce"
            )
            .arguments(rpcVersion: 16)
            .isEmpty
        )

        let addArguments = TorrentPropertiesTrackerEdit(
            originalTrackers: original,
            editedText: """
            https://one.example/announce
            https://two.example/announce
            https://three.example/announce
            https://four.example/announce
            """
        )
        .arguments(rpcVersion: 16)
        XCTAssertEqual(addArguments["trackerAdd"], .array([.string("https://four.example/announce")]))
        XCTAssertEqual(addArguments["trackerReplace"], nil)
        XCTAssertEqual(addArguments["trackerRemove"], nil)

        let replaceArguments = TorrentPropertiesTrackerEdit(
            originalTrackers: original,
            editedText: """
            https://one.example/announce
            https://replacement.example/announce
            https://three.example/announce
            """
        )
        .arguments(rpcVersion: 16)
        XCTAssertEqual(replaceArguments["trackerReplace"], .array([
            .int(20),
            .string("https://replacement.example/announce")
        ]))
        XCTAssertEqual(replaceArguments["trackerAdd"], nil)
        XCTAssertEqual(replaceArguments["trackerRemove"], nil)

        let removeArguments = TorrentPropertiesTrackerEdit(
            originalTrackers: original,
            editedText: """
            https://one.example/announce
            https://three.example/announce
            """
        )
        .arguments(rpcVersion: 16)
        XCTAssertEqual(removeArguments["trackerRemove"], .array([.int(20)]))
        XCTAssertEqual(removeArguments["trackerAdd"], nil)
        XCTAssertEqual(removeArguments["trackerReplace"], nil)
    }

    func testTorrentPropertiesDraftOnlyAppliesChangedValuesAcrossSelection() {
        let snapshot = TorrentPropertiesSnapshot(
            id: 9,
            name: "Debian ISO",
            downloadSpeedLimit: TorrentPropertiesSpeedLimit(isEnabled: true, limitKBps: 700),
            uploadSpeedLimit: TorrentPropertiesSpeedLimit(isEnabled: false, limitKBps: 50),
            peerLimit: 40,
            seedRatio: TorrentPropertiesLimitSetting(mode: .global, limit: 2.0),
            seedIdle: TorrentPropertiesLimitSetting(mode: .unlimited, limit: 30),
            trackers: [TorrentPropertiesTracker(id: 4, announce: "https://tracker.example/announce")]
        )
        var draft = snapshot.draft()

        XCTAssertTrue(draft.update().arguments(rpcVersion: 18).isEmpty)

        draft.peerLimit = 80
        let arguments = draft.update().arguments(rpcVersion: 18)
        XCTAssertEqual(arguments, ["peer-limit": .int(80)])

        let multiSelectionArguments = draft.update(forceAllGeneral: true).arguments(rpcVersion: 18)
        XCTAssertEqual(multiSelectionArguments["downloadLimited"], .bool(true))
        XCTAssertEqual(multiSelectionArguments["downloadLimit"], .int(700))
        XCTAssertEqual(multiSelectionArguments["uploadLimited"], .bool(false))
        XCTAssertEqual(multiSelectionArguments["peer-limit"], .int(80))
        XCTAssertEqual(multiSelectionArguments["seedRatioMode"], .int(0))
        XCTAssertEqual(multiSelectionArguments["seedIdleMode"], .int(2))
    }

    func testTorrentPropertiesDraftCanSuppressUnsafeLegacyMultiSelectionTrackerEdit() {
        let snapshot = TorrentPropertiesSnapshot(
            id: 9,
            trackers: [TorrentPropertiesTracker(id: 4, announce: "https://old.example/announce")]
        )
        var draft = snapshot.draft()
        draft.trackerText = "https://new.example/announce"

        XCTAssertTrue(draft.update(includeTrackers: false).arguments(rpcVersion: 16).isEmpty)
    }

    func testTorrentSetFileWantedPayloads() async throws {
        let recorder = ActionRequestRecorder()
        ActionMockURLProtocol.requestHandler = { request in
            _ = recorder.record(request)
            return Self.response(body: #"{"result":"success"}"#)
        }

        let client = TransmissionRPCClient(profile: .localDefault, urlSession: mockSession())

        try await client.setFileWanted(true, torrentID: 9, fileIndexes: [3, 1, 3])
        try await client.setFileWanted(false, torrentID: 9, fileIndexes: [2])

        let bodies = try recorder.requests.map(Self.decodedBody)
        XCTAssertEqual(bodies[0].method, "torrent-set")
        XCTAssertEqual(bodies[0].arguments["ids"], .array([.int(9)]))
        XCTAssertEqual(bodies[0].arguments["files-wanted"], .array([.int(1), .int(3)]))
        XCTAssertEqual(bodies[0].arguments["files-unwanted"], nil)
        XCTAssertEqual(bodies[1].method, "torrent-set")
        XCTAssertEqual(bodies[1].arguments["ids"], .array([.int(9)]))
        XCTAssertEqual(bodies[1].arguments["files-unwanted"], .array([.int(2)]))
        XCTAssertEqual(bodies[1].arguments["files-wanted"], nil)
    }

    func testTorrentSetFilePriorityPayloadMarksFilesWanted() async throws {
        let recorder = ActionRequestRecorder()
        ActionMockURLProtocol.requestHandler = { request in
            _ = recorder.record(request)
            return Self.response(body: #"{"result":"success"}"#)
        }

        let client = TransmissionRPCClient(profile: .localDefault, urlSession: mockSession())

        try await client.setFilePriority(.high, torrentID: 12, fileIndexes: [4, 0, 4])
        try await client.setFilePriority(.normal, torrentID: 12, fileIndexes: [1])
        try await client.setFilePriority(.low, torrentID: 12, fileIndexes: [2])

        let bodies = try recorder.requests.map(Self.decodedBody)
        XCTAssertEqual(bodies[0].arguments["ids"], .array([.int(12)]))
        XCTAssertEqual(bodies[0].arguments["files-wanted"], .array([.int(0), .int(4)]))
        XCTAssertEqual(bodies[0].arguments["priority-high"], .array([.int(0), .int(4)]))
        XCTAssertEqual(bodies[1].arguments["files-wanted"], .array([.int(1)]))
        XCTAssertEqual(bodies[1].arguments["priority-normal"], .array([.int(1)]))
        XCTAssertEqual(bodies[2].arguments["files-wanted"], .array([.int(2)]))
        XCTAssertEqual(bodies[2].arguments["priority-low"], .array([.int(2)]))
    }

    func testSessionSetDaemonOptionsPayloadIsVersionGated() async throws {
        let recorder = ActionRequestRecorder()
        ActionMockURLProtocol.requestHandler = { request in
            _ = recorder.record(request)
            return Self.response(body: #"{"result":"success"}"#)
        }

        let client = TransmissionRPCClient(profile: .localDefault, urlSession: mockSession())

        try await client.setDaemonOptions(
            DaemonOptionsUpdate(
                downloadDirectory: "/srv/downloads",
                portForwardingEnabled: true,
                encryption: .preferred,
                downloadSpeedLimitEnabled: true,
                downloadSpeedLimitKBps: 900,
                uploadSpeedLimitEnabled: false,
                uploadSpeedLimitKBps: 100,
                peerPort: 51_413,
                peerLimitGlobal: 200,
                peerLimitPerTorrent: 50,
                dhtEnabled: true,
                alternateSpeedEnabled: true,
                alternateSpeedDownKBps: 80,
                alternateSpeedUpKBps: 40,
                incompleteDirectoryEnabled: true,
                incompleteDirectory: "/srv/incomplete",
                downloadQueueEnabled: true,
                downloadQueueSize: 3,
                seedQueueEnabled: true,
                seedQueueSize: 4,
                queueStalledEnabled: true,
                queueStalledMinutes: 30
            ),
            rpcVersion: 17
        )

        let body = try XCTUnwrap(recorder.requests.first).decodedActionBody()
        XCTAssertEqual(body.method, "session-set")
        XCTAssertEqual(body.arguments["download-dir"], .string("/srv/downloads"))
        XCTAssertEqual(body.arguments["port-forwarding-enabled"], .bool(true))
        XCTAssertEqual(body.arguments["encryption"], .string("preferred"))
        XCTAssertEqual(body.arguments["speed-limit-down-enabled"], .bool(true))
        XCTAssertEqual(body.arguments["speed-limit-down"], .int(900))
        XCTAssertEqual(body.arguments["speed-limit-up-enabled"], .bool(false))
        XCTAssertEqual(body.arguments["speed-limit-up"], nil)
        XCTAssertEqual(body.arguments["peer-port"], .int(51_413))
        XCTAssertEqual(body.arguments["peer-limit-global"], .int(200))
        XCTAssertEqual(body.arguments["peer-limit-per-torrent"], .int(50))
        XCTAssertEqual(body.arguments["dht-enabled"], .bool(true))
        XCTAssertEqual(body.arguments["alt-speed-enabled"], .bool(true))
        XCTAssertEqual(body.arguments["alt-speed-down"], .int(80))
        XCTAssertEqual(body.arguments["alt-speed-up"], .int(40))
        XCTAssertEqual(body.arguments["incomplete-dir-enabled"], .bool(true))
        XCTAssertEqual(body.arguments["incomplete-dir"], .string("/srv/incomplete"))
        XCTAssertEqual(body.arguments["download-queue-enabled"], .bool(true))
        XCTAssertEqual(body.arguments["download-queue-size"], .int(3))
        XCTAssertEqual(body.arguments["seed-queue-enabled"], .bool(true))
        XCTAssertEqual(body.arguments["seed-queue-size"], .int(4))
        XCTAssertEqual(body.arguments["queue-stalled-enabled"], .bool(true))
        XCTAssertEqual(body.arguments["queue-stalled-minutes"], .int(30))
    }

    func testSessionSetSpeedLimitAndAltSpeedHelpersSendNarrowPayloads() async throws {
        let recorder = ActionRequestRecorder()
        ActionMockURLProtocol.requestHandler = { request in
            let index = recorder.record(request)
            if index == 0 {
                return Self.response(body: #"{"result":"success","arguments":{"rpc-version":5}}"#)
            }
            return Self.response(body: #"{"result":"success"}"#)
        }

        let client = TransmissionRPCClient(profile: .localDefault, urlSession: mockSession())

        _ = try await client.getSession()
        try await client.setSpeedLimit(direction: .download, enabled: true, limitKBps: 700)
        try await client.setSpeedLimit(direction: .upload, enabled: false, limitKBps: 300)
        try await client.setAlternateSpeedEnabled(false, rpcVersion: 5)

        let bodies = try recorder.requests.map(Self.decodedBody)
        XCTAssertEqual(bodies.map(\.method), ["session-get", "session-set", "session-set", "session-set"])
        XCTAssertEqual(bodies[1].arguments["speed-limit-down-enabled"], .bool(true))
        XCTAssertEqual(bodies[1].arguments["speed-limit-down"], .int(700))
        XCTAssertEqual(bodies[1].arguments["alt-speed-enabled"], .bool(false))
        XCTAssertEqual(bodies[2].arguments["speed-limit-up-enabled"], .bool(false))
        XCTAssertEqual(bodies[2].arguments["speed-limit-up"], nil)
        XCTAssertEqual(bodies[2].arguments["alt-speed-enabled"], .bool(false))
        XCTAssertEqual(bodies[3].arguments, ["alt-speed-enabled": .bool(false)])
    }

    func testSpeedLimitOmitsUnsupportedAlternateSpeedKeyAtRPC4() async throws {
        let recorder = ActionRequestRecorder()
        ActionMockURLProtocol.requestHandler = { request in
            let index = recorder.record(request)
            if index == 0 {
                return Self.response(body: #"{"result":"success","arguments":{"rpc-version":4}}"#)
            }
            return Self.response(body: #"{"result":"success"}"#)
        }
        let client = TransmissionRPCClient(profile: .localDefault, urlSession: mockSession())

        _ = try await client.getSession()
        try await client.setSpeedLimit(direction: .download, enabled: true, limitKBps: 700)

        let body = try XCTUnwrap(recorder.requests.last).decodedActionBody()
        XCTAssertEqual(body.method, "session-set")
        XCTAssertEqual(body.arguments["speed-limit-down-enabled"], .bool(true))
        XCTAssertEqual(body.arguments["speed-limit-down"], .int(700))
        XCTAssertNil(body.arguments["alt-speed-enabled"])
    }

    func testAlternateSpeedRejectsUnsupportedRPCBeforeSendingRequest() async throws {
        let recorder = ActionRequestRecorder()
        ActionMockURLProtocol.requestHandler = { request in
            _ = recorder.record(request)
            return Self.response(body: #"{"result":"success"}"#)
        }
        let client = TransmissionRPCClient(profile: .localDefault, urlSession: mockSession())

        do {
            try await client.setAlternateSpeedEnabled(true, rpcVersion: 4)
            XCTFail("alternate speed should be gated below RPC 5")
        } catch TransmissionRPCError.unsupportedRPCVersion(let feature, let required, let actual) {
            XCTAssertEqual(feature, "Alternate speed")
            XCTAssertEqual(required, 5)
            XCTAssertEqual(actual, 4)
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        XCTAssertTrue(recorder.requests.isEmpty)
    }

    func testAddTorrentSourceSendsFilenamePayload() async throws {
        let recorder = ActionRequestRecorder()
        ActionMockURLProtocol.requestHandler = { request in
            _ = recorder.record(request)
            return Self.response(body: #"{"result":"success","arguments":{"torrent-added":{"id":42}}}"#)
        }

        let client = TransmissionRPCClient(profile: .localDefault, urlSession: mockSession())

        let result = try await client.addTorrent(
            filename: "magnet:?xt=urn:btih:abc",
            startPaused: true,
            downloadDirectory: "/downloads",
            peerLimit: 37
        )

        let body = try XCTUnwrap(recorder.requests.first).decodedActionBody()
        XCTAssertEqual(result.outcome, .added)
        XCTAssertEqual(result.id, 42)
        XCTAssertEqual(body.method, "torrent-add")
        XCTAssertEqual(body.arguments["filename"], .string("magnet:?xt=urn:btih:abc"))
        XCTAssertEqual(body.arguments["metainfo"], nil)
        XCTAssertEqual(body.arguments["paused"], .bool(true))
        XCTAssertEqual(body.arguments["download-dir"], .string("/downloads"))
        XCTAssertEqual(body.arguments["peer-limit"], .int(37))
    }

    func testAddTorrentSourceOmitsBlankOptionalArguments() async throws {
        let recorder = ActionRequestRecorder()
        ActionMockURLProtocol.requestHandler = { request in
            _ = recorder.record(request)
            return Self.response(body: #"{"result":"success","arguments":{"torrent-added":{"id":44}}}"#)
        }

        let client = TransmissionRPCClient(profile: .localDefault, urlSession: mockSession())

        let result = try await client.addTorrent(
            filename: "/srv/watch/example.torrent",
            startPaused: nil,
            downloadDirectory: "  "
        )

        let body = try XCTUnwrap(recorder.requests.first).decodedActionBody()
        XCTAssertEqual(result.outcome, .added)
        XCTAssertEqual(result.id, 44)
        XCTAssertEqual(body.method, "torrent-add")
        XCTAssertEqual(body.arguments["filename"], .string("/srv/watch/example.torrent"))
        XCTAssertEqual(body.arguments["metainfo"], nil)
        XCTAssertEqual(body.arguments["paused"], nil)
        XCTAssertEqual(body.arguments["download-dir"], nil)
        XCTAssertEqual(body.arguments["peer-limit"], nil)
    }

    func testAddTorrentRejectsOutOfRangePeerLimitBeforeRequest() async throws {
        let recorder = ActionRequestRecorder()
        ActionMockURLProtocol.requestHandler = { request in
            _ = recorder.record(request)
            return Self.response(body: #"{"result":"success","arguments":{"torrent-added":{"id":44}}}"#)
        }
        let client = TransmissionRPCClient(profile: .localDefault, urlSession: mockSession())

        do {
            _ = try await client.addTorrent(
                filename: "/srv/watch/example.torrent",
                startPaused: nil,
                downloadDirectory: nil,
                peerLimit: 1_000
            )
            XCTFail("out-of-range peer limit should fail before sending")
        } catch TransmissionRPCError.invalidArguments {
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        XCTAssertTrue(recorder.requests.isEmpty)
    }

    func testAddTorrentFileSendsBase64MetainfoPayload() async throws {
        let recorder = ActionRequestRecorder()
        ActionMockURLProtocol.requestHandler = { request in
            _ = recorder.record(request)
            return Self.response(body: #"{"result":"success","arguments":{"torrent-added":{"id":43}}}"#)
        }

        let client = TransmissionRPCClient(profile: .localDefault, urlSession: mockSession())
        let metainfo = Data([0, 1, 2, 255])

        let result = try await client.addTorrent(
            metainfo: metainfo,
            startPaused: false,
            downloadDirectory: nil
        )

        let body = try XCTUnwrap(recorder.requests.first).decodedActionBody()
        XCTAssertEqual(result.outcome, .added)
        XCTAssertEqual(result.id, 43)
        XCTAssertEqual(body.method, "torrent-add")
        XCTAssertEqual(body.arguments["metainfo"], .string("AAEC/w=="))
        XCTAssertEqual(body.arguments["filename"], nil)
        XCTAssertEqual(body.arguments["paused"], .bool(false))
        XCTAssertEqual(body.arguments["download-dir"], nil)
    }

    func testAddTorrentFileSendsAdvancedFileSelectionPayload() async throws {
        let recorder = ActionRequestRecorder()
        ActionMockURLProtocol.requestHandler = { request in
            _ = recorder.record(request)
            return Self.response(body: #"{"result":"success","arguments":{"torrent-added":{"id":45}}}"#)
        }

        let client = TransmissionRPCClient(profile: .localDefault, urlSession: mockSession())
        let selection = TorrentAddFileSelection(files: [
            TorrentMetainfoFileSelection(index: 0, path: "one.txt", length: 10, wanted: true, priority: .high),
            TorrentMetainfoFileSelection(index: 1, path: "two.bin", length: 20, wanted: false, priority: .low),
            TorrentMetainfoFileSelection(index: 2, path: "three.mkv", length: 30, wanted: true, priority: .normal)
        ])

        let result = try await client.addTorrent(
            metainfo: Data([1, 2, 3]),
            startPaused: true,
            downloadDirectory: "/downloads",
            fileSelection: selection,
            peerLimit: 99
        )

        let body = try XCTUnwrap(recorder.requests.first).decodedActionBody()
        XCTAssertEqual(result.outcome, .added)
        XCTAssertEqual(result.id, 45)
        XCTAssertEqual(body.method, "torrent-add")
        XCTAssertEqual(body.arguments["metainfo"], .string("AQID"))
        XCTAssertEqual(body.arguments["paused"], .bool(true))
        XCTAssertEqual(body.arguments["download-dir"], .string("/downloads"))
        XCTAssertEqual(body.arguments["files-wanted"], .array([.int(0), .int(2)]))
        XCTAssertEqual(body.arguments["files-unwanted"], .array([.int(1)]))
        XCTAssertEqual(body.arguments["priority-high"], .array([.int(0)]))
        XCTAssertEqual(body.arguments["priority-normal"], .array([.int(2)]))
        XCTAssertEqual(body.arguments["priority-low"], .array([.int(1)]))
        XCTAssertEqual(body.arguments["peer-limit"], .int(99))
    }

    func testProvisionalMetadataFetchTargetsOnlyStableHashAndMinimalFields() async throws {
        let recorder = ActionRequestRecorder()
        ActionMockURLProtocol.requestHandler = { request in
            _ = recorder.record(request)
            return Self.response(
                body: #"{"result":"success","arguments":{"torrents":[{"id":42,"hashString":"0123456789abcdef0123456789abcdef01234567","metadataPercentComplete":1,"name":"Ubuntu"}]}}"#
            )
        }
        let client = TransmissionRPCClient(profile: .localDefault, urlSession: mockSession())

        let snapshot = try await client.fetchProvisionalTorrentMetadata(
            torrentHash: "0123456789abcdef0123456789abcdef01234567"
        )

        let body = try XCTUnwrap(recorder.requests.first).decodedActionBody()
        XCTAssertEqual(recorder.requests.count, 1)
        XCTAssertEqual(body.method, "torrent-get")
        XCTAssertEqual(
            body.arguments["ids"],
            .array([.string("0123456789abcdef0123456789abcdef01234567")])
        )
        XCTAssertEqual(
            body.arguments["fields"],
            .array(["hashString", "id", "metadataPercentComplete", "name"].map(JSONValue.string))
        )
        XCTAssertEqual(snapshot?.torrentID, 42)
        XCTAssertEqual(snapshot?.rootName, "Ubuntu")
        XCTAssertTrue(snapshot?.hasAuthoritativeRootName == true)
    }

    func testSaveAsRenamesOriginalRootUsingStableHashAtRPC15() async throws {
        let recorder = ActionRequestRecorder()
        ActionMockURLProtocol.requestHandler = { request in
            _ = recorder.record(request)
            return Self.response(body: #"{"result":"success"}"#)
        }
        let client = TransmissionRPCClient(profile: .localDefault, urlSession: mockSession())

        try await client.renameProvisionalTorrentRoot(
            torrentHash: "0123456789abcdef0123456789abcdef01234567",
            originalRootName: "Ubuntu",
            newName: "Ubuntu 24.04",
            rpcVersion: 15
        )

        let body = try XCTUnwrap(recorder.requests.first).decodedActionBody()
        XCTAssertEqual(recorder.requests.count, 1)
        XCTAssertEqual(body.method, "torrent-rename-path")
        XCTAssertEqual(
            body.arguments,
            [
                "ids": .array([.string("0123456789abcdef0123456789abcdef01234567")]),
                "path": .string("Ubuntu"),
                "name": .string("Ubuntu 24.04")
            ]
        )
    }

    func testProvisionalMetadataAndSaveAsRejectInvalidHashBeforeRequest() async throws {
        let recorder = ActionRequestRecorder()
        ActionMockURLProtocol.requestHandler = { request in
            _ = recorder.record(request)
            return Self.response(body: #"{"result":"success","arguments":{"torrents":[]}}"#)
        }
        let client = TransmissionRPCClient(profile: .localDefault, urlSession: mockSession())

        do {
            _ = try await client.fetchProvisionalTorrentMetadata(torrentHash: "not-a-full-hash")
            XCTFail("invalid metadata hash should fail before sending")
        } catch TransmissionRPCError.invalidArguments {
        } catch {
            XCTFail("unexpected metadata error: \(error)")
        }

        do {
            try await client.renameProvisionalTorrentRoot(
                torrentHash: "not-a-full-hash",
                originalRootName: "Ubuntu",
                newName: "Ubuntu 24.04",
                rpcVersion: 15
            )
            XCTFail("invalid rename hash should fail before sending")
        } catch TransmissionRPCError.invalidArguments {
        } catch {
            XCTFail("unexpected rename error: \(error)")
        }

        XCTAssertTrue(recorder.requests.isEmpty)
    }

    func testEmptyIDsDoNotSendActionRequest() async throws {
        let recorder = ActionRequestRecorder()
        ActionMockURLProtocol.requestHandler = { request in
            _ = recorder.record(request)
            return Self.response(body: #"{"result":"success"}"#)
        }

        let client = TransmissionRPCClient(profile: .localDefault, urlSession: mockSession())

        try await client.start(ids: [])

        XCTAssertTrue(recorder.requests.isEmpty)
    }

    private func mockSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ActionMockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func decodedBody(from request: URLRequest) throws -> RPCRequest {
        try request.decodedActionBody()
    }

    private static func response(body: String) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: URL(string: "http://127.0.0.1:9091/transmission/rpc")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        return (response, Data(body.utf8))
    }

    private func assertInvalidTrackerArguments(
        operation: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("invalid tracker arguments should fail before sending a request", file: file, line: line)
        } catch TransmissionRPCError.invalidArguments {
        } catch {
            XCTFail("unexpected error: \(error)", file: file, line: line)
        }
    }
}

extension TransmissionRPCActionsTests {
    func testFetchMagnetLinksUsesStableHashesAndPreservesRequestedOrder() async throws {
        let recorder = ActionRequestRecorder()
        ActionMockURLProtocol.requestHandler = { request in
            _ = recorder.record(request)
            return Self.response(body: #"{"result":"success","arguments":{"torrents":[{"hashString":"hash-three","magnetLink":"magnet:?xt=urn:btih:three"},{"hashString":"hash-nine","magnetLink":"magnet:?xt=urn:btih:nine"}]}}"#)
        }
        let client = TransmissionRPCClient(profile: .localDefault, urlSession: mockSession())

        let magnetLinks = try await client.fetchMagnetLinks(hashes: ["hash-nine", "hash-three"], rpcVersion: 7)

        let body = try XCTUnwrap(recorder.requests.first).decodedActionBody()
        XCTAssertEqual(body.method, "torrent-get")
        XCTAssertEqual(body.arguments["ids"], .array([.string("hash-nine"), .string("hash-three")]))
        XCTAssertEqual(body.arguments["fields"], .array([.string("hashString"), .string("magnetLink")]))
        XCTAssertEqual(magnetLinks, [
            TorrentMagnetLink(hashString: "hash-nine", magnetLink: "magnet:?xt=urn:btih:nine"),
            TorrentMagnetLink(hashString: "hash-three", magnetLink: "magnet:?xt=urn:btih:three"),
        ])
    }

    func testFetchMagnetLinksRejectsUnsupportedRPCBeforeRequest() async throws {
        let recorder = ActionRequestRecorder()
        ActionMockURLProtocol.requestHandler = { request in
            _ = recorder.record(request)
            return Self.response(body: #"{"result":"success","arguments":{"torrents":[]}}"#)
        }
        let client = TransmissionRPCClient(profile: .localDefault, urlSession: mockSession())

        do {
            _ = try await client.fetchMagnetLinks(hashes: ["hash-nine", "hash-three"], rpcVersion: 6)
            XCTFail("copy magnet links should be gated below RPC 7")
        } catch TransmissionRPCError.unsupportedRPCVersion(let feature, let required, let actual) {
            XCTAssertEqual(feature, "Copy magnet links")
            XCTAssertEqual(required, 7)
            XCTAssertEqual(actual, 6)
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        XCTAssertTrue(recorder.requests.isEmpty)
    }

    func testFetchMagnetLinksRejectsMissingAndEmptyLinksInRequestedOrder() async throws {
        ActionMockURLProtocol.requestHandler = { _ in
            Self.response(body: #"{"result":"success","arguments":{"torrents":[{"hashString":"hash-nine","magnetLink":"   "},{"hashString":"hash-two","magnetLink":"magnet:?xt=urn:btih:two"}]}}"#)
        }
        let client = TransmissionRPCClient(profile: .localDefault, urlSession: mockSession())

        do {
            _ = try await client.fetchMagnetLinks(
                hashes: ["hash-nine", "hash-three", "hash-two"],
                rpcVersion: 7
            )
            XCTFail("missing and empty magnet links should fail the whole copy")
        } catch TransmissionRPCError.missingMagnetLinks(let hashes) {
            XCTAssertEqual(hashes, ["hash-nine", "hash-three"])
            XCTAssertEqual(
                TransmissionRPCError.missingMagnetLinks(hashes).localizedDescription,
                "Transmission did not return magnet links for 2 selected torrents."
            )
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testPasteboardServiceWritesNewlineSeparatedMagnetLinks() throws {
        let writer = MagnetLinkWriterSpy()
        let service = MagnetLinkPasteboardService(pasteboardWriter: writer)

        try service.copy([
            TorrentMagnetLink(hashString: "hash-nine", magnetLink: "magnet:?xt=urn:btih:nine"),
            TorrentMagnetLink(hashString: "hash-three", magnetLink: "magnet:?xt=urn:btih:three"),
        ])

        XCTAssertEqual(
            writer.writtenText,
            "magnet:?xt=urn:btih:nine\nmagnet:?xt=urn:btih:three"
        )
    }

    func testPasteboardServiceSurfacesEmptyInputAndWriteFailure() {
        let writer = MagnetLinkWriterSpy(result: false)
        let service = MagnetLinkPasteboardService(pasteboardWriter: writer)

        XCTAssertThrowsError(try service.copy([])) { error in
            XCTAssertEqual(error as? MagnetLinkPasteboardError, .noMagnetLinks)
        }
        XCTAssertThrowsError(
            try service.copy([
                TorrentMagnetLink(hashString: "hash-nine", magnetLink: "magnet:?xt=urn:btih:nine")
            ])
        ) { error in
            XCTAssertEqual(error as? MagnetLinkPasteboardError, .writeFailed)
        }
    }
}

extension URLRequest {
    func decodedActionBody() throws -> RPCRequest {
        let data: Data
        if let httpBody {
            data = httpBody
        } else {
            let stream = try XCTUnwrap(httpBodyStream)
            stream.open()
            defer { stream.close() }

            var body = Data()
            var buffer = [UInt8](repeating: 0, count: 1_024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count > 0 {
                    body.append(buffer, count: count)
                } else {
                    break
                }
            }
            data = body
        }
        return try JSONDecoder().decode(RPCRequest.self, from: data)
    }
}

private final class MagnetLinkWriterSpy: MagnetLinkPasteboardWriting {
    private(set) var writtenText: String?
    private let result: Bool

    init(result: Bool = true) {
        self.result = result
    }

    func writePlainText(_ text: String) -> Bool {
        writtenText = text
        return result
    }
}

private final class ActionRequestRecorder {
    private let lock = NSLock()
    private var recordedRequests: [URLRequest] = []

    var requests: [URLRequest] {
        lock.withLock { recordedRequests }
    }

    func record(_ request: URLRequest) -> Int {
        lock.withLock {
            let index = recordedRequests.count
            recordedRequests.append(request)
            return index
        }
    }
}

private final class ActionMockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: TransmissionRPCError.invalidResponse)
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {
    }
}
