// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation
@testable import TransmissionRemoteMac

func makeAppStoreMockSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [AppStoreMockURLProtocol.self]
    return URLSession(configuration: configuration)
}

func makePersistedConnectionProfileStore(
    fileURL: URL,
    passwordStore: any ConnectionPasswordStoring
) -> ConnectionProfileStore {
    let store = ConnectionProfileStore(fileURL: fileURL, passwordStore: passwordStore)
    try! store.save(try! ConnectionProfileCollection())
    return store
}

final class AppStoreRequestRecorder {
    private let lock = NSLock()
    private var recordedRequests: [URLRequest] = []

    var requests: [URLRequest] {
        lock.withLock { recordedRequests }
    }

    func record(_ request: URLRequest) {
        lock.withLock {
            recordedRequests.append(request)
        }
    }
}

final class AppStoreMockURLProtocol: URLProtocol {
    private static let callbackLock = NSLock()
    private static var storedRequestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    private static var storedRequestDidFinish: ((URLRequest) -> Void)?
    private let stateLock = NSLock()
    private var stopped = false

    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))? {
        get { callbackLock.withLock { storedRequestHandler } }
        set { callbackLock.withLock { storedRequestHandler = newValue } }
    }

    static var requestDidFinish: ((URLRequest) -> Void)? {
        get { callbackLock.withLock { storedRequestDidFinish } }
        set { callbackLock.withLock { storedRequestDidFinish = newValue } }
    }

    private static func callbacks() -> (
        requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?,
        requestDidFinish: ((URLRequest) -> Void)?
    ) {
        callbackLock.withLock { (storedRequestHandler, storedRequestDidFinish) }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let callbacks = Self.callbacks()
        guard let handler = callbacks.requestHandler else {
            client?.urlProtocol(self, didFailWithError: TransmissionRPCError.invalidResponse)
            return
        }

        let request = request
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            defer { callbacks.requestDidFinish?(request) }
            do {
                let (response, data) = try handler(request)
                guard !self.isStopped else { return }
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                self.client?.urlProtocol(self, didLoad: data)
                self.client?.urlProtocolDidFinishLoading(self)
            } catch {
                guard !self.isStopped else { return }
                self.client?.urlProtocol(self, didFailWithError: error)
            }
        }
    }

    override func stopLoading() {
        stateLock.withLock {
            stopped = true
        }
    }

    private var isStopped: Bool {
        stateLock.withLock { stopped }
    }
}

func appStoreRPCResponse(for method: String) -> (HTTPURLResponse, Data) {
    switch method {
    case "session-get":
        rpcTestResponse(
            body: #"{"result":"success","arguments":{"rpc-version":18,"version":"4.0","download-dir":"/downloads"}}"#
        )
    case "torrent-get":
        rpcTestResponse(body: #"{"result":"success","arguments":{"torrents":[]}}"#)
    default:
        rpcTestResponse(body: #"{"result":"success","arguments":{}}"#)
    }
}

func rpcTestResponse(body: String) -> (HTTPURLResponse, Data) {
    let response = HTTPURLResponse(
        url: URL(string: "http://127.0.0.1:9091/transmission/rpc")!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: nil
    )!
    return (response, Data(body.utf8))
}
