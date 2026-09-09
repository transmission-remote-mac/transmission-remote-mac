// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import XCTest
@testable import TransmissionRemoteMac

final class ProxySettingsTests: XCTestCase {
    func testDefaultsToDirectTransport() {
        XCTAssertEqual(ProxySettings(), .direct)
        XCTAssertEqual(ProxySettings.direct.transport, .direct)
        XCTAssertEqual(ProxySettings.direct.host, "")
        XCTAssertEqual(ProxySettings.direct.port, 8080)
        XCTAssertFalse(ProxySettings.direct.authenticationEnabled)
        XCTAssertEqual(ProxySettings.direct.username, "")
        XCTAssertEqual(ProxyTransport.allCases, [.direct, .http, .https, .socks5])
        XCTAssertEqual(ProxyTransport.http.defaultPort, 8080)
        XCTAssertEqual(ProxyTransport.https.defaultPort, 443)
        XCTAssertEqual(ProxyTransport.socks5.defaultPort, 1080)
    }

    func testHTTPSProxyValidationUsesTheSameStrictHostRules() throws {
        let settings = try ProxySettings.validated(
            transport: .https,
            host: " Proxy.Example ",
            port: 8443,
            authenticationEnabled: true,
            username: "proxy-user"
        )

        XCTAssertEqual(settings.transport, .https)
        XCTAssertEqual(settings.host, "proxy.example")
        XCTAssertEqual(settings.port, 8443)
        XCTAssertTrue(settings.authenticationEnabled)
    }

    func testHTTPProxyValidationNormalizesHostAndUsername() throws {
        let settings = try ProxySettings.validated(
            transport: .http,
            host: "  proxy.example  ",
            port: 3128,
            authenticationEnabled: true,
            username: "  proxy-user  "
        )

        XCTAssertEqual(
            settings,
            ProxySettings(
                transport: .http,
                host: "proxy.example",
                port: 3128,
                authenticationEnabled: true,
                username: "proxy-user"
            )
        )
    }

    func testSOCKS5ProxyValidationSupportsUnauthenticatedTransport() throws {
        let settings = try ProxySettings.validated(
            transport: .socks5,
            host: "192.0.2.10",
            port: 1080,
            authenticationEnabled: false,
            username: "stale-user"
        )

        XCTAssertEqual(settings.transport, .socks5)
        XCTAssertEqual(settings.host, "192.0.2.10")
        XCTAssertEqual(settings.port, 1080)
        XCTAssertFalse(settings.authenticationEnabled)
        XCTAssertEqual(settings.username, "")
    }

    func testDirectValidationClearsInactiveProxyMetadata() throws {
        let settings = try ProxySettings.validated(
            transport: .direct,
            host: "ignored.example",
            port: 3128,
            authenticationEnabled: true,
            username: "ignored-user"
        )

        XCTAssertEqual(settings, .direct)
    }

    func testValidationRejectsMissingOrMalformedHosts() {
        XCTAssertThrowsError(
            try ProxySettings.validated(transport: .http, host: "", port: 8080)
        ) { error in
            XCTAssertEqual(error as? ProxySettingsValidationError, .hostRequired)
        }

        for host in [
            "http://proxy.example",
            "proxy.example/path",
            "proxy.example\\path",
            "user@proxy.example",
            "proxy example",
            "proxy.example?query",
            "proxy.example#fragment"
        ] {
            XCTAssertThrowsError(
                try ProxySettings.validated(transport: .http, host: host, port: 8080),
                "Expected proxy host to be rejected: \(host)"
            ) { error in
                XCTAssertEqual(error as? ProxySettingsValidationError, .invalidHost(host))
            }
        }
    }

    func testValidationNormalizesUnicodeAndPunycodeHostsToASCII() throws {
        let unicode = try ProxySettings.validated(
            transport: .http,
            host: "bücher.example",
            port: 8080
        )
        let punycode = try ProxySettings.validated(
            transport: .http,
            host: "xn--bcher-kva.example",
            port: 8080
        )

        XCTAssertEqual(unicode.host, "xn--bcher-kva.example")
        XCTAssertEqual(punycode.host, "xn--bcher-kva.example")
    }

    func testValidationAcceptsAndCanonicalizesBracketedIPv6() throws {
        let settings = try ProxySettings.validated(
            transport: .socks5,
            host: "[2001:0DB8:0:0:0:0:0:1]",
            port: 1080
        )

        XCTAssertEqual(settings.host, "[2001:db8::1]")
    }

    func testValidationRejectsMalformedDotLabelsAndHyphens() {
        for host in [
            ".proxy.example",
            "proxy.example.",
            "proxy..example",
            "-proxy.example",
            "proxy-.example",
            "proxy.-example"
        ] {
            XCTAssertThrowsError(
                try ProxySettings.validated(transport: .http, host: host, port: 8080),
                "Expected malformed DNS host to be rejected: \(host)"
            ) { error in
                XCTAssertEqual(error as? ProxySettingsValidationError, .invalidHost(host))
            }
        }
    }

    func testValidationRejectsEmbeddedPortsAndBareIPv6() {
        for host in [
            "proxy.example:3128",
            "2001:db8::1",
            "[2001:db8::1]:1080"
        ] {
            XCTAssertThrowsError(
                try ProxySettings.validated(transport: .socks5, host: host, port: 1080),
                "Expected host with ambiguous port syntax to be rejected: \(host)"
            ) { error in
                XCTAssertEqual(error as? ProxySettingsValidationError, .invalidHost(host))
            }
        }
    }

    func testValidationRejectsPortsOutsideTCPRange() {
        for port in [0, 65_536] {
            XCTAssertThrowsError(
                try ProxySettings.validated(transport: .socks5, host: "proxy.example", port: port)
            ) { error in
                XCTAssertEqual(error as? ProxySettingsValidationError, .portOutOfRange(port))
            }
        }
    }

    func testAuthenticationRequiresUsername() {
        XCTAssertThrowsError(
            try ProxySettings.validated(
                transport: .http,
                host: "proxy.example",
                port: 8080,
                authenticationEnabled: true,
                username: "  "
            )
        ) { error in
            XCTAssertEqual(error as? ProxySettingsValidationError, .usernameRequired)
        }
    }

    func testConnectionProfileAndDraftCarryOnlyNonSecretProxySettings() throws {
        let proxySettings = ProxySettings(
            transport: .socks5,
            host: " proxy.example ",
            port: 1080,
            authenticationEnabled: true,
            username: " proxy-user "
        )
        let profile = try ConnectionProfile.validated(
            name: "Remote",
            host: "transmission.example",
            proxySettings: proxySettings
        )
        let draft = ConnectionProfileDraft(profile: profile)

        XCTAssertEqual(profile.proxySettings.host, "proxy.example")
        XCTAssertEqual(profile.proxySettings.username, "proxy-user")
        XCTAssertEqual(draft.proxySettings, profile.proxySettings)
        XCTAssertEqual(try draft.validatedProfile(), profile)
    }

    func testEncodedProfileNeverContainsProxyPassword() throws {
        let profileID = UUID()
        let profile = try ConnectionProfile.validated(
            id: profileID,
            name: "Remote",
            host: "transmission.example",
            proxySettings: ProxySettings(
                transport: .http,
                host: "proxy.example",
                port: 3128,
                authenticationEnabled: true,
                username: "proxy-user"
            )
        )
        let passwordStore = MemoryProxyPasswordStore()
        try passwordStore.setPassword("proxy-secret", for: profileID)

        let json = try XCTUnwrap(String(data: JSONEncoder().encode(profile), encoding: .utf8))

        XCTAssertTrue(json.contains("proxySettings"))
        XCTAssertTrue(json.contains("proxy-user"))
        XCTAssertFalse(json.contains("proxy-secret"))
        XCTAssertFalse(json.localizedCaseInsensitiveContains("proxyPassword"))
    }

    func testProxyPasswordStoreIdentityIsStableAndSeparatedFromRPCPasswords() {
        let profileID = UUID(uuidString: "A16E7D7A-7E66-40F4-B910-D623DB7E9411")!

        XCTAssertEqual(
            KeychainProxyPasswordStore.account(for: profileID),
            "stable-v1:A16E7D7A-7E66-40F4-B910-D623DB7E9411"
        )
        XCTAssertEqual(
            KeychainProxyPasswordStore.service,
            "net.pokwer.TransmissionRemoteMac.ProxyPassword.v1"
        )
        XCTAssertNotEqual(
            KeychainProxyPasswordStore.service,
            "net.pokwer.TransmissionRemoteMac.TransmissionRPC.v5"
        )
    }

    func testInjectableSecretLayerAcceptsEmptyAuthenticationPassword() throws {
        let profileID = UUID()
        let passwordStore: ConnectionProxyPasswordStoring = MemoryProxyPasswordStore()

        try passwordStore.setPassword("", for: profileID)

        XCTAssertEqual(try passwordStore.password(for: profileID), "")
    }
}

private final class MemoryProxyPasswordStore: ConnectionProxyPasswordStoring {
    private var passwords: [ConnectionProfile.ID: String] = [:]

    func password(for profileID: ConnectionProfile.ID) throws -> String? {
        passwords[profileID]
    }

    func setPassword(_ password: String, for profileID: ConnectionProfile.ID) throws {
        passwords[profileID] = password
    }

    func removePassword(for profileID: ConnectionProfile.ID) throws {
        passwords.removeValue(forKey: profileID)
    }
}
