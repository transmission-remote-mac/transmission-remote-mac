// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Network
import XCTest
@testable import TransmissionRemoteMac

final class ConnectionProfileURLSessionTransportTests: XCTestCase {
    func testDirectTransportExplicitlyDisablesApplicationProxyTypes() {
        let configuration = ConnectionProfileURLSessionTransport.makeConfiguration(for: .localDefault)
        let dictionary = configuration.connectionProxyDictionary

        XCTAssertEqual(dictionary?["HTTPEnable"] as? Int, 0)
        XCTAssertEqual(dictionary?["HTTPSEnable"] as? Int, 0)
        XCTAssertEqual(dictionary?["SOCKSEnable"] as? Int, 0)
        XCTAssertEqual(configuration.proxyConfigurations.count, 0)
    }

    func testEveryConfiguredProxyTransportCreatesOneNonFailingOverNetworkProxy() throws {
        for transport in [ProxyTransport.http, .https, .socks5] {
            let profile = try ConnectionProfile.validated(
                name: transport.displayName,
                host: "transmission.example",
                proxySettings: ProxySettings(
                    transport: transport,
                    host: transport == .socks5 ? "[2001:db8::1]" : "proxy.example",
                    port: transport.defaultPort
                )
            )
            let configuration = ConnectionProfileURLSessionTransport.makeConfiguration(for: profile)
            let proxyConfiguration = try XCTUnwrap(configuration.proxyConfigurations.first)

            XCTAssertNil(configuration.connectionProxyDictionary)
            XCTAssertEqual(configuration.proxyConfigurations.count, 1, transport.displayName)
            XCTAssertFalse(proxyConfiguration.allowFailover)
        }
    }

    func testAuthenticatedProxyUsesNetworkConfigurationInsteadOfLegacyCredentialDictionary() throws {
        let profile = try ConnectionProfile.validated(
            name: "Proxied",
            host: "transmission.example",
            proxySettings: ProxySettings(
                transport: .http,
                host: "proxy.example",
                port: 3128,
                authenticationEnabled: true,
                username: "proxy-user"
            ),
            proxyPassword: "proxy-secret"
        )

        let configuration = ConnectionProfileURLSessionTransport.makeConfiguration(for: profile)

        XCTAssertNil(configuration.connectionProxyDictionary)
        XCTAssertEqual(configuration.proxyConfigurations.count, 1)
    }

    func testTaskDelegateUsesCredentialOnlyForConfiguredProxyFirstChallenge() throws {
        let profile = try ConnectionProfile.validated(
            name: "Proxied",
            host: "transmission.example",
            proxySettings: ProxySettings(
                transport: .http,
                host: "proxy.example",
                port: 3128,
                authenticationEnabled: true,
                username: "proxy-user"
            ),
            proxyPassword: "proxy-secret"
        )
        let delegate = ConnectionProfileURLSessionTransport.makeTaskDelegate(for: profile)
        let configuredProxy = URLProtectionSpace(
            proxyHost: "proxy.example",
            port: 3128,
            type: "http",
            realm: nil,
            authenticationMethod: NSURLAuthenticationMethodHTTPBasic
        )

        let first = delegate.authenticationResponse(for: configuredProxy, previousFailureCount: 0)
        let repeated = delegate.authenticationResponse(for: configuredProxy, previousFailureCount: 1)

        XCTAssertEqual(first.disposition, .useCredential)
        XCTAssertEqual(first.credential?.user, "proxy-user")
        XCTAssertEqual(first.credential?.password, "proxy-secret")
        XCTAssertEqual(first.credential?.persistence, .forSession)
        XCTAssertEqual(repeated.disposition, .cancelAuthenticationChallenge)
        XCTAssertNil(repeated.credential)
    }

    func testTaskDelegateLeavesServerTrustAndOtherProxyHostsToSystemHandling() throws {
        let profile = try ConnectionProfile.validated(
            name: "Proxied",
            scheme: "https",
            host: "transmission.example",
            port: 443,
            proxySettings: ProxySettings(
                transport: .https,
                host: "proxy.example",
                port: 8443,
                authenticationEnabled: true,
                username: "proxy-user"
            ),
            proxyPassword: "proxy-secret"
        )
        let delegate = ConnectionProfileURLSessionTransport.makeTaskDelegate(for: profile)
        let server = URLProtectionSpace(
            host: "transmission.example",
            port: 443,
            protocol: "https",
            realm: nil,
            authenticationMethod: NSURLAuthenticationMethodServerTrust
        )
        let otherProxy = URLProtectionSpace(
            proxyHost: "other-proxy.example",
            port: 8443,
            type: "https",
            realm: nil,
            authenticationMethod: NSURLAuthenticationMethodHTTPBasic
        )

        let serverResponse = delegate.authenticationResponse(for: server, previousFailureCount: 0)
        let otherProxyResponse = delegate.authenticationResponse(for: otherProxy, previousFailureCount: 0)

        XCTAssertEqual(serverResponse.disposition, .performDefaultHandling)
        XCTAssertNil(serverResponse.credential)
        XCTAssertEqual(otherProxyResponse.disposition, .performDefaultHandling)
        XCTAssertNil(otherProxyResponse.credential)
    }

    func testTaskDelegateCancelsAutomaticRedirectsBeforeURLSessionCanForwardHeaders() throws {
        let profile = try ConnectionProfile.validated(
            name: "Authenticated",
            scheme: "https",
            host: "transmission.example",
            port: 443,
            username: "rpc-user",
            password: "rpc-secret"
        )
        let delegate = ConnectionProfileURLSessionTransport.makeTaskDelegate(for: profile)
        var proposedRequest = URLRequest(url: URL(string: "https://other.example/transmission/web/")!)
        proposedRequest.setValue("Basic sensitive", forHTTPHeaderField: "Authorization")
        proposedRequest.setValue("sensitive-session", forHTTPHeaderField: "X-Transmission-Session-Id")

        XCTAssertNil(delegate.requestForHTTPRedirect(proposedRequest))
    }

    func testTaskDelegateDefaultsServerTrustButRejectsProxyClientIdentityChallenges() throws {
        let profile = try ConnectionProfile.validated(
            name: "Proxied",
            scheme: "https",
            host: "transmission.example",
            port: 443,
            proxySettings: ProxySettings(
                transport: .https,
                host: "proxy.example",
                port: 8443,
                authenticationEnabled: true,
                username: "proxy-user"
            ),
            proxyPassword: "proxy-secret"
        )
        let delegate = ConnectionProfileURLSessionTransport.makeTaskDelegate(for: profile)
        let methods = [
            (
                NSURLAuthenticationMethodServerTrust,
                URLSession.AuthChallengeDisposition.performDefaultHandling
            ),
            (
                NSURLAuthenticationMethodClientCertificate,
                URLSession.AuthChallengeDisposition.cancelAuthenticationChallenge
            ),
        ]

        for (method, expectedDisposition) in methods {
            let challenge = URLProtectionSpace(
                proxyHost: "proxy.example",
                port: 8443,
                type: "https",
                realm: nil,
                authenticationMethod: method
            )
            let response = delegate.authenticationResponse(for: challenge, previousFailureCount: 0)

            XCTAssertEqual(response.disposition, expectedDisposition, method)
            XCTAssertNil(response.credential, method)
        }
    }

    func testClientIdentityIsUsedOnlyForExactHTTPSRPCEndpointFirstChallenge() throws {
        let metadata = makeClientIdentityMetadata()
        let profile = try ConnectionProfile.validated(
            name: "Mutual TLS",
            scheme: "https",
            host: "transmission.example",
            port: 443,
            clientIdentityMetadata: metadata
        )
        let resolver = FakeClientIdentityCredentialResolver()
        let delegate = ConnectionProfileURLSessionTransport.makeTaskDelegate(
            for: profile,
            clientIdentityCredentialResolver: resolver
        )
        let exactEndpoint = URLProtectionSpace(
            host: "TRANSMISSION.EXAMPLE",
            port: 443,
            protocol: "https",
            realm: nil,
            authenticationMethod: NSURLAuthenticationMethodClientCertificate
        )

        let first = delegate.authenticationResponse(for: exactEndpoint, previousFailureCount: 0)
        let repeated = delegate.authenticationResponse(for: exactEndpoint, previousFailureCount: 1)

        XCTAssertEqual(first.disposition, .useCredential)
        XCTAssertEqual(first.credential?.user, "bound-client-identity")
        XCTAssertEqual(repeated.disposition, .cancelAuthenticationChallenge)
        XCTAssertNil(repeated.credential)
        XCTAssertEqual(resolver.requestedProfileIDs, [profile.id])
    }

    func testClientIdentityChallengeNeverFallsBackToOtherHostsPortsOrArbitraryIdentities() throws {
        let profile = try ConnectionProfile.validated(
            name: "Mutual TLS",
            scheme: "https",
            host: "transmission.example",
            port: 443,
            clientIdentityMetadata: makeClientIdentityMetadata()
        )
        let resolver = FakeClientIdentityCredentialResolver()
        let delegate = ConnectionProfileURLSessionTransport.makeTaskDelegate(
            for: profile,
            clientIdentityCredentialResolver: resolver
        )
        let challenges = [
            URLProtectionSpace(
                host: "other.example",
                port: 443,
                protocol: "https",
                realm: nil,
                authenticationMethod: NSURLAuthenticationMethodClientCertificate
            ),
            URLProtectionSpace(
                host: "transmission.example",
                port: 8443,
                protocol: "https",
                realm: nil,
                authenticationMethod: NSURLAuthenticationMethodClientCertificate
            ),
            URLProtectionSpace(
                proxyHost: "transmission.example",
                port: 443,
                type: "https",
                realm: nil,
                authenticationMethod: NSURLAuthenticationMethodClientCertificate
            )
        ]

        for challenge in challenges {
            let response = delegate.authenticationResponse(for: challenge, previousFailureCount: 0)
            XCTAssertEqual(response.disposition, .cancelAuthenticationChallenge)
            XCTAssertNil(response.credential)
        }
        XCTAssertEqual(resolver.requestedProfileIDs, [])
    }

    func testMissingOrUnresolvableConfiguredIdentityCancelsChallenge() throws {
        let plainProfile = try ConnectionProfile.validated(
            name: "HTTPS",
            scheme: "https",
            host: "transmission.example",
            port: 443
        )
        let failingResolver = FakeClientIdentityCredentialResolver(error: ClientIdentityStoreError.staleReference)
        let challenge = URLProtectionSpace(
            host: "transmission.example",
            port: 443,
            protocol: "https",
            realm: nil,
            authenticationMethod: NSURLAuthenticationMethodClientCertificate
        )
        let plainDelegate = ConnectionProfileURLSessionTransport.makeTaskDelegate(
            for: plainProfile,
            clientIdentityCredentialResolver: failingResolver
        )
        var configuredProfile = plainProfile
        configuredProfile.clientIdentityMetadata = makeClientIdentityMetadata()
        let configuredDelegate = ConnectionProfileURLSessionTransport.makeTaskDelegate(
            for: configuredProfile,
            clientIdentityCredentialResolver: failingResolver
        )

        XCTAssertEqual(
            plainDelegate.authenticationResponse(for: challenge, previousFailureCount: 0).disposition,
            .cancelAuthenticationChallenge
        )
        XCTAssertEqual(
            configuredDelegate.authenticationResponse(for: challenge, previousFailureCount: 0).disposition,
            .cancelAuthenticationChallenge
        )
    }

    private func makeClientIdentityMetadata() -> ClientIdentityMetadata {
        ClientIdentityMetadata(
            displayName: "RPC Client",
            sha256Fingerprint: "AABBCC",
            subject: "CN=rpc-client",
            issuer: "CN=test-ca",
            notBefore: Date(timeIntervalSince1970: 1_700_000_000),
            notAfter: Date(timeIntervalSince1970: 2_000_000_000)
        )
    }
}

private final class FakeClientIdentityCredentialResolver: ClientIdentityCredentialResolving, @unchecked Sendable {
    private let error: Error?
    private(set) var requestedProfileIDs: [ConnectionProfile.ID] = []

    init(error: Error? = nil) {
        self.error = error
    }

    func credential(for profile: ConnectionProfile) throws -> URLCredential {
        requestedProfileIDs.append(profile.id)
        if let error {
            throw error
        }
        return URLCredential(
            user: "bound-client-identity",
            password: "",
            persistence: .forSession
        )
    }
}
