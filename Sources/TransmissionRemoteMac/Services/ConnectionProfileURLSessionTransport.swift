// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation
import Network

enum ConnectionProfileURLSessionTransport {
    private enum ProxyKey {
        static let httpEnable = "HTTPEnable"
        static let httpsEnable = "HTTPSEnable"
        static let socksEnable = "SOCKSEnable"
    }

    static func makeSession(for profile: ConnectionProfile) -> URLSession {
        URLSession(configuration: makeConfiguration(for: profile))
    }

    static func makeConfiguration(for profile: ConnectionProfile) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = TimeInterval(profile.requestTimeoutSeconds)
        configuration.timeoutIntervalForResource = TimeInterval(profile.requestTimeoutSeconds)
        if profile.proxySettings.transport == .direct {
            configuration.connectionProxyDictionary = directProxyDictionary
            configuration.proxyConfigurations = []
        } else {
            configuration.connectionProxyDictionary = nil
            configuration.proxyConfigurations = [proxyConfiguration(for: profile)]
        }
        return configuration
    }

    static func makeTaskDelegate(
        for profile: ConnectionProfile,
        clientIdentityCredentialResolver: any ClientIdentityCredentialResolving = KeychainClientIdentityCredentialResolver()
    ) -> ConnectionProfileURLSessionTaskDelegate {
        ConnectionProfileURLSessionTaskDelegate(
            profile: profile,
            clientIdentityCredentialResolver: clientIdentityCredentialResolver
        )
    }

    static let directProxyDictionary: [AnyHashable: Any] = [
        ProxyKey.httpEnable: 0,
        ProxyKey.httpsEnable: 0,
        ProxyKey.socksEnable: 0
    ]

    private static func proxyConfiguration(for profile: ConnectionProfile) -> ProxyConfiguration {
        let settings = profile.proxySettings
        guard let rawPort = UInt16(exactly: settings.port),
              let port = NWEndpoint.Port(rawValue: rawPort) else {
            preconditionFailure("Validated proxy port is outside the TCP range")
        }
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(networkHost(settings.host)),
            port: port
        )
        var configuration: ProxyConfiguration
        switch settings.transport {
        case .direct:
            preconditionFailure("Direct connections do not create a proxy configuration")
        case .http:
            configuration = ProxyConfiguration(httpCONNECTProxy: endpoint)
        case .https:
            configuration = ProxyConfiguration(
                httpCONNECTProxy: endpoint,
                tlsOptions: NWProtocolTLS.Options()
            )
        case .socks5:
            configuration = ProxyConfiguration(socksv5Proxy: endpoint)
        }
        configuration.allowFailover = false
        if settings.authenticationEnabled {
            configuration.applyCredential(
                username: settings.username,
                password: profile.proxyPassword
            )
        }
        return configuration
    }

    private static func networkHost(_ host: String) -> String {
        guard host.hasPrefix("["), host.hasSuffix("]") else { return host }
        return String(host.dropFirst().dropLast())
    }
}

final class ConnectionProfileURLSessionTaskDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let profile: ConnectionProfile
    private let expectedEndpointHost: String
    private let expectedEndpointPort: Int
    private let clientIdentityCredentialResolver: any ClientIdentityCredentialResolving
    private let expectedProxyHost: String?
    private let expectedProxyPort: Int?
    private let proxyCredential: URLCredential?
    private let metricsCollector = RPCURLSessionTaskMetricsCollector()

    init(
        profile: ConnectionProfile,
        clientIdentityCredentialResolver: any ClientIdentityCredentialResolving = KeychainClientIdentityCredentialResolver()
    ) {
        self.profile = profile
        expectedEndpointHost = Self.networkHost(profile.host).lowercased()
        expectedEndpointPort = profile.port
        self.clientIdentityCredentialResolver = clientIdentityCredentialResolver
        let settings = profile.proxySettings
        if settings.transport != .direct, settings.authenticationEnabled {
            expectedProxyHost = Self.networkHost(settings.host).lowercased()
            expectedProxyPort = settings.port
            proxyCredential = URLCredential(
                user: settings.username,
                password: profile.proxyPassword,
                persistence: .forSession
            )
        } else {
            expectedProxyHost = nil
            expectedProxyPort = nil
            proxyCredential = nil
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let response = authenticationResponse(
            for: challenge.protectionSpace,
            previousFailureCount: challenge.previousFailureCount
        )
        completionHandler(response.disposition, response.credential)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(requestForHTTPRedirect(request))
    }

    func requestForHTTPRedirect(_ proposedRequest: URLRequest) -> URLRequest? {
        // Transmission endpoint discovery is handled by the RPC client after validating
        // the original response. Never let URLSession carry request credentials itself.
        nil
    }

    func authenticationResponse(
        for protectionSpace: URLProtectionSpace,
        previousFailureCount: Int
    ) -> (disposition: URLSession.AuthChallengeDisposition, credential: URLCredential?) {
        if protectionSpace.authenticationMethod == NSURLAuthenticationMethodClientCertificate {
            guard !protectionSpace.isProxy() else {
                return (.cancelAuthenticationChallenge, nil)
            }
            guard isExactRPCEndpoint(protectionSpace), profile.hasClientIdentity else {
                return (.cancelAuthenticationChallenge, nil)
            }
            guard previousFailureCount == 0 else {
                return (.cancelAuthenticationChallenge, nil)
            }
            do {
                return (.useCredential, try clientIdentityCredentialResolver.credential(for: profile))
            } catch {
                return (.cancelAuthenticationChallenge, nil)
            }
        }

        guard protectionSpace.isProxy(),
              Self.proxyPasswordAuthenticationMethods.contains(protectionSpace.authenticationMethod),
              let expectedProxyHost,
              let expectedProxyPort,
              Self.networkHost(protectionSpace.host).lowercased() == expectedProxyHost,
              protectionSpace.port == expectedProxyPort,
              let proxyCredential else {
            return (.performDefaultHandling, nil)
        }

        guard previousFailureCount == 0 else {
            return (.cancelAuthenticationChallenge, nil)
        }
        return (.useCredential, proxyCredential)
    }

    private func isExactRPCEndpoint(_ protectionSpace: URLProtectionSpace) -> Bool {
        !protectionSpace.isProxy()
            && protectionSpace.protocol?.lowercased() == "https"
            && Self.networkHost(protectionSpace.host).lowercased() == expectedEndpointHost
            && protectionSpace.port == expectedEndpointPort
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        metricsCollector.urlSession(session, task: task, didFinishCollecting: metrics)
    }

    func metricsSnapshot() -> RPCTransportMetrics {
        metricsCollector.snapshot()
    }

    private static func networkHost(_ host: String) -> String {
        guard host.hasPrefix("["), host.hasSuffix("]") else { return host }
        return String(host.dropFirst().dropLast())
    }

    private static let proxyPasswordAuthenticationMethods: Set<String> = [
        NSURLAuthenticationMethodDefault,
        NSURLAuthenticationMethodHTTPBasic,
        NSURLAuthenticationMethodHTTPDigest,
        NSURLAuthenticationMethodNTLM,
        NSURLAuthenticationMethodNegotiate,
    ]
}
