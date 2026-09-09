// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import XCTest
@testable import TransmissionRemoteMac

final class TransmissionRPCClientTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testConnectRetriesOnceAfterSessionIDChallenge() async throws {
        let recorder = RequestRecorder()
        let diagnostics = RPCDiagnostics(capacity: 10)
        MockURLProtocol.requestHandler = { request in
            let requestNumber = recorder.record(request)
            if requestNumber == 0 {
                return Self.response(
                    statusCode: 409,
                    headers: ["X-Transmission-Session-Id": "session-123"],
                    body: ""
                )
            }

            return Self.response(
                statusCode: 200,
                body: #"{"result":"success","arguments":{"rpc-version":17,"version":"4.0.6"}}"#
            )
        }

        let client = TransmissionRPCClient(
            profile: .localDefault,
            urlSession: mockSession(),
            diagnostics: diagnostics
        )
        let rpcVersion = try await client.connect()
        let requests = recorder.requests
        let event = try XCTUnwrap(diagnostics.snapshot().events.last)

        XCTAssertEqual(rpcVersion, 17)
        XCTAssertEqual(requests.count, 2)
        XCTAssertNil(requests[0].value(forHTTPHeaderField: "X-Transmission-Session-Id"))
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "X-Transmission-Session-Id"), "session-123")
        XCTAssertEqual(try decodedBody(from: requests[1]).method, "session-get")
        XCTAssertEqual(event.method, .sessionGet)
        XCTAssertEqual(event.category, .session)
        XCTAssertEqual(event.applicationRequestCount, 1)
        XCTAssertEqual(event.httpAttemptCount, 2)
        XCTAssertEqual(
            event.requestBytes,
            try JSONEncoder().encode(RPCRequest(method: "session-get")).count * 2
        )
        XCTAssertEqual(event.sessionChallengeRetryCount, 1)
        XCTAssertNil(event.errorClass)
    }

    func testConnectSwitches409RetryToJSONRPCAndKeepsOneDiagnosticEvent() async throws {
        let recorder = RequestRecorder()
        let diagnostics = RPCDiagnostics(capacity: 10)
        MockURLProtocol.requestHandler = { request in
            let requestNumber = recorder.record(request)
            if requestNumber == 0 {
                return Self.response(
                    statusCode: 409,
                    headers: [
                        "X-Transmission-Session-Id": "session-json",
                        "X-Transmission-Rpc-Version": "6.0.0",
                    ],
                    body: ""
                )
            }

            let root = try request.decodedJSONValueBody().objectValue ?? [:]
            let id = root["id"] ?? .null
            let response = JSONValue.object([
                "jsonrpc": .string("2.0"),
                "result": .object([
                    "rpc_version": .int(18),
                    "rpc_version_semver": .string("6.0.0"),
                    "version": .string("4.1.0"),
                    "download_dir": .string("/json"),
                ]),
                "id": id,
            ])
            return Self.response(
                statusCode: 200,
                body: String(decoding: try JSONEncoder().encode(response), as: UTF8.self)
            )
        }

        let client = TransmissionRPCClient(
            profile: .localDefault,
            urlSession: mockSession(),
            diagnostics: diagnostics
        )
        let version = try await client.connect()
        let requests = recorder.requests
        let firstRequest = try decodedBody(from: requests[0])
        let firstRequestObject = try requests[0].decodedJSONValueBody().objectValue
        let secondRequest = try requests[1].decodedJSONValueBody().objectValue
        let event = try XCTUnwrap(diagnostics.snapshot().events.last)

        XCTAssertEqual(version, 18)
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(firstRequest.method, "session-get")
        XCTAssertNil(firstRequestObject?["jsonrpc"])
        XCTAssertEqual(firstRequestObject?["method"], .string("session-get"))
        XCTAssertEqual(firstRequestObject?["arguments"], .object([:]))
        XCTAssertEqual(secondRequest?["jsonrpc"], .string("2.0"))
        XCTAssertEqual(secondRequest?["method"], .string("session_get"))
        XCTAssertEqual(secondRequest?["params"], .object([:]))
        XCTAssertNil(secondRequest?["arguments"])
        XCTAssertNotNil(secondRequest?["id"]?.intValue)
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "X-Transmission-Session-Id"), "session-json")
        XCTAssertEqual(event.applicationRequestCount, 1)
        XCTAssertEqual(event.httpAttemptCount, 2)
        XCTAssertEqual(event.sessionChallengeRetryCount, 1)
        XCTAssertEqual(event.method, .sessionGet)
        XCTAssertNil(event.errorClass)
    }

    func testTorrentGetDiagnosticsRecordFieldAndReturnedRowCounts() async throws {
        let diagnostics = RPCDiagnostics(capacity: 10)
        let recorder = RequestRecorder()
        MockURLProtocol.requestHandler = { request in
            _ = recorder.record(request)
            return Self.response(
                statusCode: 200,
                body: #"{"result":"success","arguments":{"torrents":[{"id":1},{"id":2}]}}"#
            )
        }

        let client = TransmissionRPCClient(
            profile: .localDefault,
            urlSession: mockSession(),
            diagnostics: diagnostics
        )
        _ = try await client.getTorrents()
        let event = try XCTUnwrap(diagnostics.snapshot().events.last)
        let request = try XCTUnwrap(recorder.requests.first)
        let requestedFields = try decodedBody(from: request).arguments["fields"]?.arrayValue ?? []

        XCTAssertEqual(event.method, .torrentGet)
        XCTAssertEqual(event.category, .torrentQuery)
        XCTAssertFalse(requestedFields.isEmpty)
        XCTAssertEqual(event.requestedFieldCount, requestedFields.count)
        XCTAssertEqual(event.returnedTorrentRows, 2)
        XCTAssertEqual(event.httpAttemptCount, 1)
        XCTAssertGreaterThan(event.requestBytes, 0)
        XCTAssertGreaterThan(event.responseBytes, 0)
        XCTAssertNil(event.errorClass)
    }

    func testConnectFailsWhenSessionIDChallengeRepeatsAfterRetry() async throws {
        let recorder = RequestRecorder()
        let diagnostics = RPCDiagnostics(capacity: 10)
        MockURLProtocol.requestHandler = { request in
            _ = recorder.record(request)
            return Self.response(
                statusCode: 409,
                headers: ["X-Transmission-Session-Id": "session-123"],
                body: ""
            )
        }

        let client = TransmissionRPCClient(
            profile: .localDefault,
            urlSession: mockSession(),
            diagnostics: diagnostics
        )

        do {
            _ = try await client.connect()
            XCTFail("connect should fail when session id retry is rejected")
        } catch TransmissionRPCError.sessionIDRejected {
            XCTAssertEqual(recorder.requests.count, 2)
            XCTAssertEqual(
                TransmissionRPCError.sessionIDRejected.localizedDescription,
                "Transmission rejected the session id after retry"
            )
            let event = try XCTUnwrap(diagnostics.snapshot().events.last)
            XCTAssertEqual(event.applicationRequestCount, 1)
            XCTAssertEqual(event.httpAttemptCount, 2)
            XCTAssertEqual(event.sessionChallengeRetryCount, 1)
            XCTAssertEqual(event.errorClass, .sessionNegotiation)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testConnectFailsWhenSessionIDChallengeHasNoSessionID() async throws {
        MockURLProtocol.requestHandler = { _ in
            Self.response(statusCode: 409, body: "")
        }

        let client = TransmissionRPCClient(profile: .localDefault, urlSession: mockSession())

        do {
            _ = try await client.connect()
            XCTFail("connect should fail without a session id")
        } catch TransmissionRPCError.missingSessionID {
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testSendFailsWhenArgumentsAreExpectedButMissing() async throws {
        MockURLProtocol.requestHandler = { _ in
            Self.response(statusCode: 200, body: #"{"result":"success"}"#)
        }

        let client = TransmissionRPCClient(profile: .localDefault, urlSession: mockSession())

        do {
            _ = try await client.send(RPCRequest(method: "session-get"))
            XCTFail("send should require arguments by default")
        } catch TransmissionRPCError.missingArguments {
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testSendFailsWhenArgumentsAreNotAnObject() async throws {
        MockURLProtocol.requestHandler = { _ in
            Self.response(statusCode: 200, body: #"{"result":"success","arguments":[]}"#)
        }

        let client = TransmissionRPCClient(profile: .localDefault, urlSession: mockSession())

        do {
            _ = try await client.send(RPCRequest(method: "session-get"))
            XCTFail("send should reject non-object arguments")
        } catch TransmissionRPCError.invalidArguments {
            XCTAssertEqual(TransmissionRPCError.invalidArguments.localizedDescription, "RPC arguments value was not an object")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testSendFailsWithMalformedJSONMessage() async throws {
        MockURLProtocol.requestHandler = { _ in
            Self.response(statusCode: 200, body: #"{"result":"success","arguments":"#)
        }

        let client = TransmissionRPCClient(profile: .localDefault, urlSession: mockSession())

        do {
            _ = try await client.send(RPCRequest(method: "session-get"))
            XCTFail("send should reject malformed JSON")
        } catch TransmissionRPCError.malformedJSON {
            XCTAssertEqual(TransmissionRPCError.malformedJSON.localizedDescription, "Invalid server response: malformed JSON")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testSendSurfacesTransmissionRPCResultFailures() async throws {
        MockURLProtocol.requestHandler = { _ in
            Self.response(statusCode: 200, body: #"{"result":"invalid arguments"}"#)
        }

        let client = TransmissionRPCClient(profile: .localDefault, urlSession: mockSession())

        do {
            _ = try await client.send(RPCRequest(method: "torrent-get"), returnArguments: false)
            XCTFail("send should surface Transmission result failures")
        } catch TransmissionRPCError.rpcFailure(let message) {
            XCTAssertEqual(message, "invalid arguments")
            XCTAssertEqual(
                TransmissionRPCError.rpcFailure(message).localizedDescription,
                "Transmission RPC failed: invalid arguments"
            )
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testHTTPErrorExtractsReadableBodyText() async throws {
        MockURLProtocol.requestHandler = { _ in
            Self.response(
                statusCode: 500,
                body: #"<html><body><h1>Server failed</h1><p>&quot;bad rpc&quot;</p><br><span>retry later</span></body></html>"#
            )
        }

        let client = TransmissionRPCClient(profile: .localDefault, urlSession: mockSession())

        do {
            _ = try await client.send(RPCRequest(method: "session-get"))
            XCTFail("send should surface HTTP failures")
        } catch TransmissionRPCError.httpStatus(let status, let message) {
            XCTAssertEqual(status, 500)
            XCTAssertEqual(message, #"Server failed "bad rpc" retry later"#)
            XCTAssertEqual(
                TransmissionRPCError.httpStatus(status, message).localizedDescription,
                #"HTTP 500: Server failed "bad rpc" retry later"#
            )
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testAuthHTTPStatusUsesHelpfulDescription() async throws {
        MockURLProtocol.requestHandler = { _ in
            Self.response(statusCode: 401, body: #"<html><body><h1>Unauthorized</h1></body></html>"#)
        }

        let client = TransmissionRPCClient(profile: .localDefault, urlSession: mockSession())

        do {
            _ = try await client.connect()
            XCTFail("connect should surface authentication failures")
        } catch TransmissionRPCError.httpStatus(let status, let message) {
            XCTAssertEqual(status, 401)
            XCTAssertEqual(message, "Unauthorized")
            let description = TransmissionRPCError.httpStatus(status, message).localizedDescription
            XCTAssertEqual(description, "Authentication failed (HTTP 401): Unauthorized")
            XCTAssertFalse(description.contains("<body>"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testForbiddenHTTPStatusUsesHelpfulDescription() async throws {
        MockURLProtocol.requestHandler = { _ in
            Self.response(statusCode: 403, body: #"<html><body>Forbidden</body></html>"#)
        }

        let client = TransmissionRPCClient(profile: .localDefault, urlSession: mockSession())

        do {
            _ = try await client.connect()
            XCTFail("connect should surface forbidden responses")
        } catch TransmissionRPCError.httpStatus(let status, let message) {
            XCTAssertEqual(status, 403)
            XCTAssertEqual(message, "Forbidden")
            XCTAssertEqual(
                TransmissionRPCError.httpStatus(status, message).localizedDescription,
                "Access denied by Transmission (HTTP 403): Forbidden"
            )
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testConnectMapsURLSessionConnectivityFailures() async throws {
        MockURLProtocol.requestHandler = { _ in
            throw URLError(.cannotConnectToHost)
        }

        let client = TransmissionRPCClient(profile: .localDefault, urlSession: mockSession())

        do {
            _ = try await client.connect()
            XCTFail("connect should surface connectivity failures")
        } catch TransmissionRPCError.connectionFailed(let message) {
            XCTAssertEqual(message, "http://127.0.0.1:9091/transmission/rpc — connection refused")
            XCTAssertEqual(
                TransmissionRPCError.connectionFailed(message).localizedDescription,
                "Could not connect to Transmission: http://127.0.0.1:9091/transmission/rpc — connection refused"
            )
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testRequestUsesCustomPathAndBasicAuth() async throws {
        let recorder = RequestRecorder()
        MockURLProtocol.requestHandler = { request in
            _ = recorder.record(request)
            return Self.response(
                statusCode: 200,
                body: #"{"result":"success","arguments":{"rpc-version":16}}"#
            )
        }
        let profile = ConnectionProfile(
            name: "Test",
            host: "transmission.example",
            rpcPath: "custom/rpc",
            username: "user",
            password: "pass",
            requestTimeoutSeconds: 45
        )

        let client = TransmissionRPCClient(profile: profile, urlSession: mockSession())
        _ = try await client.connect()

        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.url?.path, "/custom/rpc")
        XCTAssertEqual(request.timeoutInterval, 45)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept-Encoding"), "gzip")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Basic dXNlcjpwYXNz")
    }

    func testConnectRepairsSameOriginWebRedirectBeforeSessionChallengeRetry() async throws {
        let recorder = RequestRecorder()
        let diagnostics = RPCDiagnostics(capacity: 10)
        MockURLProtocol.requestHandler = { request in
            let requestNumber = recorder.record(request)
            switch requestNumber {
            case 0:
                return Self.response(
                    statusCode: 301,
                    headers: ["Location": "/nested/transmission/web/"],
                    body: ""
                )
            case 1:
                return Self.response(
                    statusCode: 409,
                    headers: ["X-Transmission-Session-Id": "repaired-session"],
                    body: ""
                )
            default:
                return Self.response(
                    statusCode: 200,
                    body: #"{"result":"success","arguments":{"rpc-version":17}}"#
                )
            }
        }
        let profile = ConnectionProfile(
            name: "Redirected",
            host: "transmission.example",
            rpcPath: "/legacy/rpc",
            username: "user",
            password: "pass"
        )
        let client = TransmissionRPCClient(
            profile: profile,
            urlSession: mockSession(),
            diagnostics: diagnostics
        )

        let rpcVersion = try await client.connect()
        let requests = recorder.requests
        let event = try XCTUnwrap(diagnostics.snapshot().events.last)

        XCTAssertEqual(rpcVersion, 17)
        XCTAssertEqual(requests.map(\.url?.path), [
            "/legacy/rpc",
            "/nested/transmission/rpc",
            "/nested/transmission/rpc",
        ])
        XCTAssertTrue(requests.allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization") == "Basic dXNlcjpwYXNz"
        })
        XCTAssertNil(requests[0].value(forHTTPHeaderField: "X-Transmission-Session-Id"))
        XCTAssertNil(requests[1].value(forHTTPHeaderField: "X-Transmission-Session-Id"))
        XCTAssertEqual(
            requests[2].value(forHTTPHeaderField: "X-Transmission-Session-Id"),
            "repaired-session"
        )
        XCTAssertEqual(event.httpAttemptCount, 3)
        XCTAssertEqual(event.sessionChallengeRetryCount, 1)
        XCTAssertNil(event.errorClass)
    }

    func testEndpointRepairPolicyAcceptsOnlySameOriginWebSuffixes() throws {
        let endpoint = try XCTUnwrap(URL(string: "https://Transmission.Example:443/explicit/custom/rpc"))
        let relativeRepair = try XCTUnwrap(
            TransmissionRPCEndpointRedirectPolicy.repairedEndpoint(
                currentEndpoint: endpoint,
                location: "/nested/web"
            )
        )
        let absoluteRepair = try XCTUnwrap(
            TransmissionRPCEndpointRedirectPolicy.repairedEndpoint(
                currentEndpoint: endpoint,
                location: "https://transmission.example:443/another/web/"
            )
        )

        XCTAssertEqual(relativeRepair.scheme, "https")
        XCTAssertEqual(relativeRepair.host?.lowercased(), "transmission.example")
        XCTAssertEqual(relativeRepair.port, 443)
        XCTAssertEqual(relativeRepair.path, "/nested/rpc")
        XCTAssertEqual(absoluteRepair.scheme, "https")
        XCTAssertEqual(absoluteRepair.host?.lowercased(), "transmission.example")
        XCTAssertEqual(absoluteRepair.port, 443)
        XCTAssertEqual(absoluteRepair.path, "/another/rpc")
    }

    func testConnectRejectsCrossOriginWebRedirectWithoutForwardingCredentials() async throws {
        let recorder = RequestRecorder()
        MockURLProtocol.requestHandler = { request in
            _ = recorder.record(request)
            return Self.response(
                statusCode: 301,
                headers: ["Location": "http://other.example/transmission/web/"],
                body: ""
            )
        }
        let profile = ConnectionProfile(
            name: "Redirected",
            host: "transmission.example",
            rpcPath: "/legacy/rpc",
            username: "user",
            password: "pass"
        )
        let client = TransmissionRPCClient(profile: profile, urlSession: mockSession())

        do {
            _ = try await client.connect()
            XCTFail("cross-origin redirect should fail")
        } catch TransmissionRPCError.httpStatus(let statusCode, _) {
            XCTAssertEqual(statusCode, 301)
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        XCTAssertEqual(recorder.requests.count, 1)
        XCTAssertEqual(recorder.requests[0].url?.host, "transmission.example")
        XCTAssertEqual(
            recorder.requests[0].value(forHTTPHeaderField: "Authorization"),
            "Basic dXNlcjpwYXNz"
        )
    }

    func testConnectRejectsUnsafeOrUnsupportedRedirects() async throws {
        for redirect in [
            (301, "http://transmission.example:443/transmission/web/"),
            (301, "ftp://transmission.example:443/transmission/web/"),
            (301, "https://transmission.example:8443/transmission/web/"),
            (301, "https://transmission.example:443/login"),
            (301, "https://user:secret@transmission.example:443/transmission/web/"),
            (301, "https://transmission.example:443/transmission/web/?token=secret"),
            (302, "https://transmission.example:443/transmission/web/"),
        ] {
            let recorder = RequestRecorder()
            MockURLProtocol.requestHandler = { request in
                _ = recorder.record(request)
                return Self.response(
                    statusCode: redirect.0,
                    headers: ["Location": redirect.1],
                    body: ""
                )
            }
            let profile = ConnectionProfile(
                name: "HTTPS",
                scheme: "https",
                host: "transmission.example",
                port: 443,
                rpcPath: "/custom/rpc"
            )
            let client = TransmissionRPCClient(profile: profile, urlSession: mockSession())

            do {
                _ = try await client.connect()
                XCTFail("unsafe redirect should fail: \(redirect)")
            } catch TransmissionRPCError.httpStatus(let statusCode, _) {
                XCTAssertEqual(statusCode, redirect.0, "\(redirect)")
            } catch {
                XCTFail("unexpected error for \(redirect): \(error)")
            }
            XCTAssertEqual(recorder.requests.count, 1, "\(redirect)")
            XCTAssertEqual(recorder.requests[0].url?.path, "/custom/rpc", "\(redirect)")
        }
    }

    func testConnectAllowsOnlyOneEndpointRepairAndCommitsItOnlyAfterSuccess() async throws {
        let recorder = RequestRecorder()
        MockURLProtocol.requestHandler = { request in
            let requestNumber = recorder.record(request)
            if requestNumber == 2 {
                return Self.response(
                    statusCode: 200,
                    body: #"{"result":"success","arguments":{"rpc-version":17}}"#
                )
            }
            return Self.response(
                statusCode: 301,
                headers: [
                    "Location": requestNumber == 0
                        ? "/first/web/"
                        : "/second/web/"
                ],
                body: ""
            )
        }
        let profile = ConnectionProfile(
            name: "Redirected",
            host: "transmission.example",
            rpcPath: "/legacy/rpc"
        )
        let client = TransmissionRPCClient(profile: profile, urlSession: mockSession())

        do {
            _ = try await client.connect()
            XCTFail("a second endpoint repair should fail")
        } catch TransmissionRPCError.httpStatus(let statusCode, _) {
            XCTAssertEqual(statusCode, 301)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        let rpcVersion = try await client.connect()

        XCTAssertEqual(rpcVersion, 17)
        XCTAssertEqual(recorder.requests.map(\.url?.path), [
            "/legacy/rpc",
            "/first/rpc",
            "/legacy/rpc",
        ])
    }

    func testRejectedRedirectDoesNotReplaceExplicitCustomRPCPath() async throws {
        let recorder = RequestRecorder()
        MockURLProtocol.requestHandler = { request in
            let requestNumber = recorder.record(request)
            if requestNumber == 0 {
                return Self.response(
                    statusCode: 301,
                    headers: ["Location": "/unrelated/login"],
                    body: ""
                )
            }
            return Self.response(
                statusCode: 200,
                body: #"{"result":"success","arguments":{"rpc-version":17}}"#
            )
        }
        let profile = ConnectionProfile(
            name: "Custom",
            host: "transmission.example",
            rpcPath: "/explicit/custom/rpc"
        )
        let client = TransmissionRPCClient(profile: profile, urlSession: mockSession())

        do {
            _ = try await client.connect()
            XCTFail("non-Transmission redirect should fail")
        } catch TransmissionRPCError.httpStatus(let statusCode, _) {
            XCTAssertEqual(statusCode, 301)
        }
        let rpcVersion = try await client.connect()

        XCTAssertEqual(rpcVersion, 17)
        XCTAssertEqual(recorder.requests.map(\.url?.path), [
            "/explicit/custom/rpc",
            "/explicit/custom/rpc",
        ])
    }

    func testGetSessionDecodesVersionDownloadDirectoryAndCapabilities() async throws {
        MockURLProtocol.requestHandler = { _ in
            Self.response(
                statusCode: 200,
                body: #"{"result":"success","arguments":{"rpc-version":17,"version":"4.0.6","download-dir":"/srv/downloads","encryption":"required","speed-limit-down-enabled":true,"speed-limit-down":800,"speed-limit-up-enabled":false,"speed-limit-up":250,"alt-speed-enabled":true,"alt-speed-down":100,"alt-speed-up":50,"download-queue-enabled":true,"download-queue-size":3,"seed-queue-enabled":true,"seed-queue-size":4,"queue-stalled-enabled":true,"queue-stalled-minutes":30}}"#
            )
        }

        let client = TransmissionRPCClient(profile: .localDefault, urlSession: mockSession())
        let session = try await client.getSession()

        XCTAssertEqual(session.rpcVersion, 17)
        XCTAssertEqual(session.version, "4.0.6")
        XCTAssertEqual(session.downloadDir, "/srv/downloads")
        XCTAssertEqual(session.daemonOptions.encryption, .required)
        XCTAssertEqual(session.daemonOptions.downloadSpeedLimit, SessionSpeedLimit(isEnabled: true, limitKBps: 800))
        XCTAssertEqual(session.daemonOptions.uploadSpeedLimit, SessionSpeedLimit(isEnabled: false, limitKBps: 250))
        XCTAssertEqual(session.daemonOptions.alternateSpeedEnabled, true)
        XCTAssertEqual(session.daemonOptions.alternateSpeedDownKBps, 100)
        XCTAssertEqual(session.daemonOptions.alternateSpeedUpKBps, 50)
        XCTAssertEqual(session.daemonOptions.downloadQueueEnabled, true)
        XCTAssertEqual(session.daemonOptions.downloadQueueSize, 3)
        XCTAssertEqual(session.daemonOptions.seedQueueEnabled, true)
        XCTAssertEqual(session.daemonOptions.seedQueueSize, 4)
        XCTAssertEqual(session.daemonOptions.queueStalledEnabled, true)
        XCTAssertEqual(session.daemonOptions.queueStalledMinutes, 30)
        XCTAssertTrue(session.capabilities.hasSessionStats)
        XCTAssertTrue(session.capabilities.hasLabels)
        XCTAssertTrue(session.capabilities.hasTorrentTableFormat)
        XCTAssertTrue(session.capabilities.hasTrackerListEditing)
    }

    func testGetSessionStatsDecodesCurrentAndCumulativeStats() async throws {
        MockURLProtocol.requestHandler = { _ in
            Self.response(
                statusCode: 200,
                body: #"{"result":"success","arguments":{"activeTorrentCount":2,"pausedTorrentCount":5,"torrentCount":9,"downloadSpeed":1234,"uploadSpeed":5678,"current-stats":{"uploadedBytes":1000,"downloadedBytes":2000,"filesAdded":3,"sessionCount":1,"secondsActive":60},"cumulative-stats":{"uploadedBytes":4000,"downloadedBytes":5000,"filesAdded":6,"sessionCount":7,"secondsActive":8000}}}"#
            )
        }

        let client = TransmissionRPCClient(profile: .localDefault, urlSession: mockSession())
        let stats = try await client.getSessionStats()

        XCTAssertEqual(stats.activeTorrentCount, 2)
        XCTAssertEqual(stats.pausedTorrentCount, 5)
        XCTAssertEqual(stats.torrentCount, 9)
        XCTAssertEqual(stats.downloadSpeed, 1_234)
        XCTAssertEqual(stats.uploadSpeed, 5_678)
        XCTAssertEqual(stats.current.uploadedBytes, 1_000)
        XCTAssertEqual(stats.current.downloadedBytes, 2_000)
        XCTAssertEqual(stats.current.filesAdded, 3)
        XCTAssertEqual(stats.current.sessionCount, 1)
        XCTAssertEqual(stats.current.secondsActive, 60)
        XCTAssertEqual(stats.cumulative.uploadedBytes, 4_000)
        XCTAssertEqual(stats.cumulative.downloadedBytes, 5_000)
        XCTAssertEqual(stats.cumulative.filesAdded, 6)
        XCTAssertEqual(stats.cumulative.sessionCount, 7)
        XCTAssertEqual(stats.cumulative.secondsActive, 8_000)
    }

    func testFetchTorrentListMapsMissingOptionalFieldsWithoutCrashing() async throws {
        MockURLProtocol.requestHandler = { _ in
            Self.response(
                statusCode: 200,
                body: #"{"result":"success","arguments":{"torrents":[{"id":1,"name":"Ubuntu ISO","status":4}]}}"#
            )
        }

        let client = TransmissionRPCClient(profile: .localDefault, urlSession: mockSession())
        let update = try await client.fetchTorrentList(mode: .fullSnapshot)
        let torrents = update.torrents.map { TorrentMapper.map($0, rpcVersion: 0) }

        XCTAssertEqual(torrents.count, 1)
        XCTAssertEqual(torrents[0].id, 1)
        XCTAssertEqual(torrents[0].name, "Ubuntu ISO")
        XCTAssertEqual(torrents[0].status, .downloading)
        XCTAssertEqual(torrents[0].leftUntilDone, 0)
        XCTAssertEqual(torrents[0].labels, [])
    }

    func testGetTorrentsRequestsAndDecodesRPC16TableFormat() async throws {
        let recorder = RequestRecorder()
        MockURLProtocol.requestHandler = { request in
            let requestNumber = recorder.record(request)
            if requestNumber == 0 {
                return Self.response(
                    statusCode: 200,
                    body: #"{"result":"success","arguments":{"rpc-version":16,"version":"3.00","download-dir":"/downloads"}}"#
                )
            }

            return Self.response(
                statusCode: 200,
                body: #"{"result":"success","arguments":{"fields":["id","name","status","labels"],"torrents":[[2,"Debian ISO",6,["linux","iso"]]]}}"#
            )
        }

        let client = TransmissionRPCClient(profile: .localDefault, urlSession: mockSession())
        _ = try await client.connect()
        let response = try await client.getTorrents()
        let request = try XCTUnwrap(recorder.requests.last)
        let torrentRequest = try decodedBody(from: request)
        let requestedFields = torrentRequest.arguments["fields"]?.arrayValue?.compactMap(\.stringValue) ?? []

        XCTAssertEqual(torrentRequest.arguments["format"]?.stringValue, "table")
        XCTAssertTrue(requestedFields.contains("labels"))
        XCTAssertEqual(response.torrents.count, 1)
        XCTAssertEqual(response.torrents[0].id, 2)
        XCTAssertEqual(response.torrents[0].name, "Debian ISO")
        XCTAssertEqual(response.torrents[0].labels, ["linux", "iso"])
    }

    func testExplicitTorrentFieldPlanDrivesEveryListRequestCadence() async throws {
        let recorder = RequestRecorder()
        MockURLProtocol.requestHandler = { request in
            _ = recorder.record(request)
            return Self.response(
                statusCode: 200,
                body: #"{"result":"success","arguments":{"torrents":[]}}"#
            )
        }
        let client = TransmissionRPCClient(profile: .localDefault, urlSession: mockSession())

        for rpcVersion in [6, 7, 16, 18] {
            let plan = TorrentListFieldPlan(
                revision: rpcVersion,
                rpcVersion: rpcVersion,
                visibleColumns: [.name, .eta, .labels],
                activeSortColumn: .uploaded
            )
            let modes: [(TorrentListFetchMode, [String])] = [
                (.fullSnapshot, plan.fullFields),
                (.recentlyActive, plan.deltaFields),
                (.targeted([42]), plan.bootstrapFields),
            ]

            for (mode, expectedFields) in modes {
                let update = try await client.fetchTorrentList(mode: mode, fieldPlan: plan)
                let request = try decodedBody(from: XCTUnwrap(recorder.requests.last))
                let fields = request.arguments["fields"]?.arrayValue?.compactMap(\.stringValue)

                XCTAssertEqual(fields, expectedFields, "RPC \(rpcVersion), mode \(mode)")
                XCTAssertEqual(update.fieldPlanRevision, rpcVersion)
                XCTAssertFalse(expectedFields.contains("trackers") && expectedFields.contains("trackerStats"))
            }
        }
    }

    func testDetailPaneRequestUsesConnectedRPCVersionTrackerGeneration() async throws {
        let recorder = RequestRecorder()
        MockURLProtocol.requestHandler = { request in
            let requestNumber = recorder.record(request)
            if requestNumber == 0 {
                return Self.response(
                    statusCode: 200,
                    body: #"{"result":"success","arguments":{"rpc-version":7}}"#
                )
            }
            return Self.response(
                statusCode: 200,
                body: #"{"result":"success","arguments":{"torrents":[{"id":42,"trackerStats":[]}]}}"#
            )
        }

        let client = TransmissionRPCClient(profile: .localDefault, urlSession: mockSession())
        _ = try await client.connect()
        _ = try await client.fetchTorrentDetail(id: 42, pane: .trackers)
        let request = try decodedBody(from: XCTUnwrap(recorder.requests.last))
        let fields = request.arguments["fields"]?.arrayValue?.compactMap(\.stringValue)

        XCTAssertEqual(fields, ["hashString", "id", "trackerStats"])
        XCTAssertFalse(fields?.contains("trackers") == true)
        XCTAssertFalse(fields?.contains("nextAnnounceTime") == true)
    }

    func testDetailFetchReportsWhenTheTorrentDisappeared() async throws {
        MockURLProtocol.requestHandler = { _ in
            Self.response(
                statusCode: 200,
                body: #"{"result":"success","arguments":{"torrents":[]}}"#
            )
        }
        let client = TransmissionRPCClient(profile: .localDefault, urlSession: mockSession())

        do {
            _ = try await client.fetchTorrentDetail(id: 42, pane: .overview)
            XCTFail("missing torrent should not produce an empty detail snapshot")
        } catch TransmissionRPCError.torrentNotFound(let id) {
            XCTAssertEqual(id, 42)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testGetTorrentsDecodesLegacyTableWithFieldsInFirstTorrentRow() async throws {
        MockURLProtocol.requestHandler = { _ in
            Self.response(
                statusCode: 200,
                body: #"{"result":"success","arguments":{"torrents":[["id","name","status"],[3,"Fedora ISO",0]]}}"#
            )
        }

        let client = TransmissionRPCClient(profile: .localDefault, urlSession: mockSession())
        let response = try await client.getTorrents()

        XCTAssertEqual(response.torrents.count, 1)
        XCTAssertEqual(response.torrents[0].id, 3)
        XCTAssertEqual(response.torrents[0].name, "Fedora ISO")
        XCTAssertEqual(response.torrents[0].status, 0)
    }

    func testFetchTorrentListRequestsLegacyDeltaAndDecodesRemovedIDs() async throws {
        let recorder = RequestRecorder()
        MockURLProtocol.requestHandler = { request in
            _ = recorder.record(request)
            return Self.response(
                statusCode: 200,
                body: #"{"result":"success","arguments":{"torrents":[{"id":2,"name":"Changed"}],"removed":[3,1,3]}}"#
            )
        }

        let client = TransmissionRPCClient(profile: .localDefault, urlSession: mockSession())
        let update = try await client.fetchTorrentList(mode: .recentlyActive)
        let request = try decodedBody(from: XCTUnwrap(recorder.requests.first))

        XCTAssertEqual(request.arguments["ids"], .string("recently-active"))
        XCTAssertEqual(update.mode, .recentlyActive)
        XCTAssertEqual(update.torrents.map(\.id), [2])
        XCTAssertEqual(update.removedIDs, [1, 3])
    }

    func testFetchTorrentListUsesJSONRPCRecentlyActiveSelector() async throws {
        let recorder = RequestRecorder()
        MockURLProtocol.requestHandler = { request in
            let requestNumber = recorder.record(request)
            if requestNumber == 0 {
                return Self.response(
                    statusCode: 409,
                    headers: [
                        "X-Transmission-Session-Id": "json-session",
                        "X-Transmission-Rpc-Version": "6.0.0",
                    ],
                    body: ""
                )
            }

            let root = try request.decodedJSONValueBody().objectValue ?? [:]
            let id = root["id"] ?? .null
            if requestNumber == 1 {
                XCTAssertEqual(root["method"], .string("session_get"))
                let response = JSONValue.object([
                    "jsonrpc": .string("2.0"),
                    "result": .object(["rpc_version": .int(18)]),
                    "id": id,
                ])
                return Self.response(
                    statusCode: 200,
                    body: String(decoding: try JSONEncoder().encode(response), as: UTF8.self)
                )
            }

            XCTAssertEqual(root["method"], .string("torrent_get"))
            let params = root["params"]?.objectValue ?? [:]
            XCTAssertEqual(params["ids"], .string("recently_active"))
            let response = JSONValue.object([
                "jsonrpc": .string("2.0"),
                "result": .object([
                    "torrents": .array([.object([
                        "id": .int(7),
                        "name": .string("JSON delta"),
                    ])]),
                    "removed": .array([.int(6)]),
                ]),
                "id": id,
            ])
            return Self.response(
                statusCode: 200,
                body: String(decoding: try JSONEncoder().encode(response), as: UTF8.self)
            )
        }

        let client = TransmissionRPCClient(profile: .localDefault, urlSession: mockSession())
        _ = try await client.connect()
        let update = try await client.fetchTorrentList(mode: .recentlyActive)

        XCTAssertEqual(update.mode, .recentlyActive)
        XCTAssertEqual(update.torrents.map(\.id), [7])
        XCTAssertEqual(update.removedIDs, [6])
        XCTAssertEqual(recorder.requests.count, 3)
    }

    func testFetchTorrentListFallsBackToFullAndKeepsFallbackAfterDeltaRejection() async throws {
        let recorder = RequestRecorder()
        MockURLProtocol.requestHandler = { request in
            let requestNumber = recorder.record(request)
            let body = try request.decodedJSONValueBody().objectValue ?? [:]
            let arguments = body["arguments"]?.objectValue ?? [:]
            if requestNumber == 0 {
                XCTAssertEqual(arguments["ids"], .string("recently-active"))
                return Self.response(
                    statusCode: 200,
                    body: #"{"result":"invalid argument: ids","arguments":{}}"#
                )
            }

            XCTAssertNil(arguments["ids"])
            let torrentID = requestNumber
            return Self.response(
                statusCode: 200,
                body: #"{"result":"success","arguments":{"torrents":[{"id":\#(torrentID),"name":"Full"}]}}"#
            )
        }

        let client = TransmissionRPCClient(profile: .localDefault, urlSession: mockSession())
        let fallback = try await client.fetchTorrentList(mode: .recentlyActive)
        let stickyFallback = try await client.fetchTorrentList(mode: .recentlyActive)

        XCTAssertEqual(fallback.mode, .fullSnapshot)
        XCTAssertEqual(fallback.torrents.map(\.id), [1])
        XCTAssertEqual(stickyFallback.mode, .fullSnapshot)
        XCTAssertEqual(stickyFallback.torrents.map(\.id), [2])
        XCTAssertEqual(recorder.requests.count, 3)
    }

    func testFetchTorrentListDoesNotDisableDeltaForArbitraryRPCFailure() async throws {
        let recorder = RequestRecorder()
        MockURLProtocol.requestHandler = { request in
            let requestNumber = recorder.record(request)
            if requestNumber > 0 {
                return Self.response(
                    statusCode: 200,
                    body: #"{"result":"success","arguments":{"torrents":[]}}"#
                )
            }
            return Self.response(
                statusCode: 200,
                body: #"{"result":"temporary daemon failure","arguments":{}}"#
            )
        }

        let client = TransmissionRPCClient(profile: .localDefault, urlSession: mockSession())
        do {
            _ = try await client.fetchTorrentList(mode: .recentlyActive)
            XCTFail("Expected the unrelated RPC failure to propagate")
        } catch let error as TransmissionRPCError {
            guard case .rpcFailure(let message) = error else {
                return XCTFail("Expected rpcFailure, received \(error)")
            }
            XCTAssertEqual(message, "temporary daemon failure")
        }

        let retry = try await client.fetchTorrentList(mode: .recentlyActive)
        XCTAssertEqual(retry.mode, .recentlyActive)
        XCTAssertEqual(recorder.requests.count, 2)
        for request in recorder.requests {
            let arguments = try request.decodedJSONValueBody().objectValue?["arguments"]?.objectValue
            XCTAssertEqual(arguments?["ids"], .string("recently-active"))
        }
    }

    func testFetchTorrentListDoesNotDisableDeltaForMalformedArguments() async throws {
        let recorder = RequestRecorder()
        MockURLProtocol.requestHandler = { request in
            let requestNumber = recorder.record(request)
            if requestNumber > 0 {
                return Self.response(
                    statusCode: 200,
                    body: #"{"result":"success","arguments":{"torrents":[]}}"#
                )
            }
            return Self.response(
                statusCode: 200,
                body: #"{"result":"success","arguments":[]}"#
            )
        }

        let client = TransmissionRPCClient(profile: .localDefault, urlSession: mockSession())
        do {
            _ = try await client.fetchTorrentList(mode: .recentlyActive)
            XCTFail("Expected malformed arguments to propagate")
        } catch let error as TransmissionRPCError {
            guard case .invalidArguments = error else {
                return XCTFail("Expected invalidArguments, received \(error)")
            }
        }

        let retry = try await client.fetchTorrentList(mode: .recentlyActive)
        XCTAssertEqual(retry.mode, .recentlyActive)
        XCTAssertEqual(recorder.requests.count, 2)
        for request in recorder.requests {
            let arguments = try request.decodedJSONValueBody().objectValue?["arguments"]?.objectValue
            XCTAssertEqual(arguments?["ids"], .string("recently-active"))
        }
    }

    func testFetchTorrentFilesRequestsAndMapsFileFields() async throws {
        let recorder = RequestRecorder()
        MockURLProtocol.requestHandler = { request in
            _ = recorder.record(request)
            return Self.response(
                statusCode: 200,
                body: """
                {"result":"success","arguments":{"torrents":[{
                    "id":42,
                    "peers":[{
                        "address":"203.0.113.5",
                        "port":51413,
                        "clientName":"Transmission 4",
                        "flagStr":"DXE",
                        "progress":0.5,
                        "rateToClient":2048,
                        "rateToPeer":4096
                    }],
                    "trackerStats":[{
                        "id":7,
                        "announce":"https://tracker.example/announce",
                        "host":"tracker.example",
                        "hasAnnounced":true,
                        "lastAnnounceSucceeded":true,
                        "seederCount":12,
                        "leecherCount":3
                    }],
                    "files":[{
                        "name":"Folder/Readme.txt",
                        "length":1000,
                        "bytesCompleted":250
                    },{
                        "name":"Folder/Video.mkv",
                        "length":3000,
                        "bytesCompleted":0
                    }],
                    "fileStats":[{
                        "bytesCompleted":500,
                        "wanted":true,
                        "priority":1
                    },{
                        "bytesCompleted":1500,
                        "wanted":false,
                        "priority":-1
                    }]
                }]}}
                """
            )
        }

        let client = TransmissionRPCClient(profile: .localDefault, urlSession: mockSession())
        let detail = try await client.fetchTorrentDetail(id: 42, pane: .files)
        let request = try XCTUnwrap(recorder.requests.first)
        let torrentRequest = try decodedBody(from: request)
        let requestedFields = torrentRequest.arguments["fields"]?.arrayValue?.compactMap(\.stringValue) ?? []

        XCTAssertEqual(torrentRequest.method, "torrent-get")
        XCTAssertEqual(torrentRequest.arguments["ids"]?.arrayValue?.compactMap(\.intValue), [42])
        XCTAssertTrue(requestedFields.contains("files"))
        XCTAssertTrue(requestedFields.contains("fileStats"))
        XCTAssertTrue(requestedFields.contains("priorities"))
        XCTAssertTrue(requestedFields.contains("wanted"))
        XCTAssertEqual(detail.id, 42)
        XCTAssertEqual(detail.files.count, 2)
        XCTAssertEqual(detail.files[0].relativePath, "Folder/Readme.txt")
        XCTAssertEqual(detail.files[0].bytesCompleted, 500)
        XCTAssertEqual(detail.files[0].wanted, true)
        XCTAssertEqual(detail.files[0].priority, 1)
        XCTAssertEqual(detail.files[1].relativePath, "Folder/Video.mkv")
        XCTAssertEqual(detail.files[1].bytesCompleted, 1_500)
        XCTAssertEqual(detail.files[1].wanted, false)
        XCTAssertEqual(detail.files[1].priority, -1)
        XCTAssertEqual(detail.fileTree.first?.name, "Folder")
        XCTAssertEqual(detail.fileTree.first?.wanted, .mixed)
        XCTAssertEqual(detail.fileTree.first?.priority, .mixed)
        XCTAssertEqual(detail.fileTree.first?.fileIndexes, [0, 1])
    }

    func testFetchTorrentOverviewDetailRequestsAndMapsGeneralInfoFields() async throws {
        let recorder = RequestRecorder()
        MockURLProtocol.requestHandler = { request in
            let requestNumber = recorder.record(request)
            if requestNumber == 0 {
                return Self.response(
                    statusCode: 200,
                    body: #"{"result":"success","arguments":{"rpc-version":18}}"#
                )
            }
            return Self.response(
                statusCode: 200,
                body: """
                {"result":"success","arguments":{"torrents":[{
                    "id":42,
                    "hashString":"abc123",
                    "magnetLink":"magnet:?xt=urn:btih:abc123",
                    "comment":"Release notes",
                    "creator":"mktorrent",
                    "dateCreated":1700000000,
                    "pieceCount":128,
                    "pieceSize":262144,
                    "haveValid":1048576,
                    "haveUnchecked":524288,
                    "secondsDownloading":3600,
                    "desiredAvailable":2097152
                }]}}
                """
            )
        }

        let client = TransmissionRPCClient(profile: .localDefault, urlSession: mockSession())
        _ = try await client.connect()
        let detail = try await client.fetchTorrentDetail(id: 42, pane: .overview)
        let request = try XCTUnwrap(recorder.requests.last)
        let torrentRequest = try decodedBody(from: request)
        let requestedFields = torrentRequest.arguments["fields"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let generalInfo = try XCTUnwrap(detail.generalInfo)

        XCTAssertEqual(torrentRequest.arguments["ids"]?.arrayValue?.compactMap(\.intValue), [42])
        XCTAssertTrue(requestedFields.contains("hashString"))
        XCTAssertTrue(requestedFields.contains("magnetLink"))
        XCTAssertTrue(requestedFields.contains("comment"))
        XCTAssertTrue(requestedFields.contains("creator"))
        XCTAssertTrue(requestedFields.contains("dateCreated"))
        XCTAssertTrue(requestedFields.contains("pieceCount"))
        XCTAssertTrue(requestedFields.contains("pieceSize"))
        XCTAssertTrue(requestedFields.contains("haveValid"))
        XCTAssertTrue(requestedFields.contains("haveUnchecked"))
        XCTAssertTrue(requestedFields.contains("secondsDownloading"))
        XCTAssertTrue(requestedFields.contains("desiredAvailable"))
        XCTAssertEqual(generalInfo.hashString, "abc123")
        XCTAssertEqual(generalInfo.magnetLink, "magnet:?xt=urn:btih:abc123")
        XCTAssertEqual(generalInfo.comment, "Release notes")
        XCTAssertEqual(generalInfo.creator, "mktorrent")
        XCTAssertEqual(generalInfo.dateCreated, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(generalInfo.pieceCount, 128)
        XCTAssertEqual(generalInfo.pieceSize, 262_144)
        XCTAssertEqual(generalInfo.haveValid, 1_048_576)
        XCTAssertEqual(generalInfo.haveUnchecked, 524_288)
        XCTAssertEqual(generalInfo.secondsDownloading, 3_600)
        XCTAssertEqual(generalInfo.desiredAvailable, 2_097_152)
    }

    func testFetchTorrentDetailUsesSafeDefaultsForMissingPayloadFields() async throws {
        MockURLProtocol.requestHandler = { _ in
            Self.response(
                statusCode: 200,
                body: #"{"result":"success","arguments":{"torrents":[{"id":9,"peers":[{}],"trackers":[{}]}]}}"#
            )
        }

        let client = TransmissionRPCClient(profile: .localDefault, urlSession: mockSession())
        let detail = try await client.fetchTorrentDetail(id: 9, pane: .trackers)

        XCTAssertEqual(detail.id, 9)
        XCTAssertEqual(detail.trackers.count, 1)
        XCTAssertEqual(detail.trackers[0].announce, "")
        XCTAssertEqual(detail.trackers[0].seederCount, -1)
    }

    func testFetchTorrentDetailFallsBackToLegacyFileArraysWhenFileStatsArePartial() async throws {
        MockURLProtocol.requestHandler = { _ in
            Self.response(
                statusCode: 200,
                body: """
                {"result":"success","arguments":{"torrents":[{
                    "id":11,
                    "files":[{
                        "name":"one.bin",
                        "length":10,
                        "bytesCompleted":4
                    },{
                        "name":"dir/two.bin",
                        "length":20,
                        "bytesCompleted":8
                    }],
                    "fileStats":[{
                        "bytesCompleted":5,
                        "wanted":1,
                        "priority":0
                    }],
                    "wanted":[1,0],
                    "priorities":[0,-1]
                }]}}
                """
            )
        }

        let client = TransmissionRPCClient(profile: .localDefault, urlSession: mockSession())
        let detail = try await client.fetchTorrentDetail(id: 11, pane: .files)

        XCTAssertEqual(detail.files.count, 2)
        XCTAssertEqual(detail.files[0].bytesCompleted, 5)
        XCTAssertEqual(detail.files[0].wanted, true)
        XCTAssertEqual(detail.files[0].priority, 0)
        XCTAssertEqual(detail.files[1].bytesCompleted, 8)
        XCTAssertEqual(detail.files[1].wanted, false)
        XCTAssertEqual(detail.files[1].priority, -1)
        XCTAssertEqual(detail.fileTree.map(\.name), ["dir", "one.bin"])
    }

    func testPortTestGatesVersionsAndOmitsAutomaticProtocolArgument() async throws {
        let recorder = RequestRecorder()
        MockURLProtocol.requestHandler = { request in
            _ = recorder.record(request)
            return Self.response(
                statusCode: 200,
                body: #"{"result":"success","arguments":{"port-is-open":true}}"#
            )
        }
        let client = TransmissionRPCClient(profile: .localDefault, urlSession: mockSession())

        do {
            _ = try await client.testPort(.automatic, rpcVersion: 4)
            XCTFail("RPC 4 should reject port testing")
        } catch TransmissionRPCError.unsupportedRPCVersion(_, let required, let actual) {
            XCTAssertEqual(required, 5)
            XCTAssertEqual(actual, 4)
        }
        let result = try await client.testPort(.automatic, rpcVersion: 5)
        let request = try decodedBody(from: XCTUnwrap(recorder.requests.first))

        XCTAssertTrue(result.isOpen)
        XCTAssertEqual(result.requestedProtocol, .automatic)
        XCTAssertNil(result.reportedProtocol)
        XCTAssertEqual(request.method, "port-test")
        XCTAssertNil(request.arguments["ip-protocol"])
    }

    func testPortTestRequiresRPC18ForExplicitFamilyAndValidatesResponse() async throws {
        let recorder = RequestRecorder()
        MockURLProtocol.requestHandler = { request in
            _ = recorder.record(request)
            return Self.response(
                statusCode: 200,
                body: #"{"result":"success","arguments":{"port-is-open":false,"ip-protocol":"ipv6"}}"#
            )
        }
        let client = TransmissionRPCClient(profile: .localDefault, urlSession: mockSession())

        do {
            _ = try await client.testPort(.ipv6, rpcVersion: 17)
            XCTFail("RPC 17 should reject protocol-specific port testing")
        } catch TransmissionRPCError.unsupportedRPCVersion(_, let required, let actual) {
            XCTAssertEqual(required, 18)
            XCTAssertEqual(actual, 17)
        }
        XCTAssertTrue(recorder.requests.isEmpty)

        let result = try await client.testPort(.ipv6, rpcVersion: 18)
        let request = try decodedBody(from: XCTUnwrap(recorder.requests.first))
        XCTAssertFalse(result.isOpen)
        XCTAssertEqual(result.reportedProtocol, .ipv6)
        XCTAssertEqual(request.arguments["ip-protocol"], .string("ipv6"))
    }

    func testMaintenanceResultsRejectMalformedValuesAndBlocklistOverridesTimeout() async throws {
        let recorder = RequestRecorder()
        MockURLProtocol.requestHandler = { request in
            let index = recorder.record(request)
            if index == 0 {
                return Self.response(
                    statusCode: 200,
                    body: #"{"result":"success","arguments":{"port-is-open":"yes"}}"#
                )
            }
            return Self.response(
                statusCode: 200,
                body: #"{"result":"success","arguments":{"blocklist-size":42}}"#
            )
        }
        let profile = ConnectionProfile(
            name: "Timeout",
            host: "127.0.0.1",
            requestTimeoutSeconds: 17
        )
        let client = TransmissionRPCClient(profile: profile, urlSession: mockSession())

        do {
            _ = try await client.testPort(.automatic, rpcVersion: 5)
            XCTFail("Malformed port state should fail")
        } catch TransmissionRPCError.invalidArguments {
        }
        let blocklist = try await client.updateBlocklist(rpcVersion: 5)

        XCTAssertEqual(blocklist.entryCount, 42)
        XCTAssertEqual(recorder.requests[0].timeoutInterval, 17)
        XCTAssertEqual(recorder.requests[1].timeoutInterval, 180)
    }

    private func mockSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func decodedBody(from request: URLRequest) throws -> RPCRequest {
        let data: Data
        if let httpBody = request.httpBody {
            data = httpBody
        } else {
            let stream = try XCTUnwrap(request.httpBodyStream)
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

    private static func response(
        statusCode: Int,
        headers: [String: String]? = nil,
        body: String
    ) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: URL(string: "http://127.0.0.1:9091/transmission/rpc")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: headers
        )!
        return (response, Data(body.utf8))
    }
}

private final class RequestRecorder {
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

private final class MockURLProtocol: URLProtocol {
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

private extension URLRequest {
    func decodedJSONValueBody() throws -> JSONValue {
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
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }
}
