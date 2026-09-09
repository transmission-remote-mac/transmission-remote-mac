// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Darwin
import Foundation

enum PeerIPAddressFamily: Int, Comparable, Sendable {
    case ipv4 = 4
    case ipv6 = 6

    static func < (lhs: PeerIPAddressFamily, rhs: PeerIPAddressFamily) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct PeerIPAddress: Comparable, Hashable, Sendable {
    let family: PeerIPAddressFamily
    let bytes: [UInt8]

    init?(parsing rawValue: String) {
        var candidate = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.hasPrefix("["), candidate.hasSuffix("]") {
            candidate.removeFirst()
            candidate.removeLast()
        }
        var ipv4 = in_addr()
        if inet_pton(AF_INET, candidate, &ipv4) == 1 {
            family = .ipv4
            bytes = withUnsafeBytes(of: &ipv4) { Array($0) }
            return
        }

        if let zoneIndex = candidate.firstIndex(of: "%") {
            candidate = String(candidate[..<zoneIndex])
        }

        var ipv6 = in6_addr()
        guard inet_pton(AF_INET6, candidate, &ipv6) == 1 else { return nil }
        let ipv6Bytes = withUnsafeBytes(of: &ipv6) { Array($0) }
        if ipv6Bytes.prefix(10).allSatisfy({ $0 == 0 }),
           ipv6Bytes[10] == 0xff,
           ipv6Bytes[11] == 0xff {
            family = .ipv4
            bytes = Array(ipv6Bytes.suffix(4))
        } else {
            family = .ipv6
            bytes = ipv6Bytes
        }
    }

    var canonicalString: String {
        var storage = bytes
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let addressFamily = family == .ipv4 ? AF_INET : AF_INET6
        let result = storage.withUnsafeMutableBytes { rawBuffer in
            inet_ntop(
                addressFamily,
                rawBuffer.baseAddress,
                &buffer,
                socklen_t(buffer.count)
            )
        }
        guard result != nil else { return "" }
        return String(cString: buffer)
    }

    static func < (lhs: PeerIPAddress, rhs: PeerIPAddress) -> Bool {
        if lhs.family != rhs.family {
            return lhs.family < rhs.family
        }
        return lhs.bytes.lexicographicallyPrecedes(rhs.bytes)
    }
}

struct PeerEndpoint: Hashable, Sendable {
    var address: PeerIPAddress
    var rawAddress: String
    var port: Int

    init?(rawAddress: String, port: Int) {
        guard let address = PeerIPAddress(parsing: rawAddress) else { return nil }
        self.address = address
        self.rawAddress = rawAddress
        self.port = max(0, port)
    }
}

struct PeerResolvedMetadata: Equatable, Sendable {
    var address: PeerIPAddress
    var hostName: String?
    var countryCode: String?
    var countryName: String?
    var countryFlag: String?
}

struct PeerResolutionContext: Equatable, Sendable {
    var profileID: UUID
    var connectionToken: UUID
    var selectionGeneration: Int
    var torrentID: Int
    var detailGeneration: Int
    var peersSnapshotRevision: UUID
}

struct PeerResolutionRequest: Sendable {
    var context: PeerResolutionContext
    var endpoints: [PeerEndpoint]
    var preferences: PeerResolutionPreferences

    /// DNS and country lookup operate on canonical addresses, independent of
    /// ports, ordering and per-poll peer statistics. Selection generation also
    /// fences torrent hash replacement at a reused numeric ID.
    func canReuseResolution(for next: PeerResolutionRequest) -> Bool {
        context.profileID == next.context.profileID
            && context.connectionToken == next.context.connectionToken
            && context.selectionGeneration == next.context.selectionGeneration
            && context.torrentID == next.context.torrentID
            && preferences == next.preferences
            && Set(endpoints.map(\.address)) == Set(next.endpoints.map(\.address))
    }
}

struct PeerResolutionBatch: Equatable, Sendable {
    var context: PeerResolutionContext
    var metadataByAddress: [PeerIPAddress: PeerResolvedMetadata]
}

enum PeerResolutionPublicationGuard {
    static func canPublish(
        expected: PeerResolutionContext,
        profileID: UUID,
        connectionToken: UUID,
        selectionGeneration: Int,
        torrentID: Int?,
        detailGeneration: Int,
        peersSnapshotRevision: UUID?
    ) -> Bool {
        expected.profileID == profileID
            && expected.connectionToken == connectionToken
            && expected.selectionGeneration == selectionGeneration
            && expected.torrentID == torrentID
            && expected.detailGeneration == detailGeneration
            && expected.peersSnapshotRevision == peersSnapshotRevision
    }
}

enum PeerCountryPresentation {
    static func localizedName(for countryCode: String, locale: Locale = .current) -> String? {
        let normalized = normalizedCountryCode(countryCode)
        guard normalized.count == 2 else { return nil }
        return locale.localizedString(forRegionCode: normalized) ?? normalized
    }

    static func flag(for countryCode: String) -> String? {
        let normalized = normalizedCountryCode(countryCode)
        guard normalized.unicodeScalars.count == 2,
              normalized.unicodeScalars.allSatisfy({ (65 ... 90).contains($0.value) }) else {
            return nil
        }
        let scalars = normalized.unicodeScalars.compactMap {
            UnicodeScalar(127_397 + $0.value)
        }
        guard scalars.count == 2 else { return nil }
        return String(scalars.map { Character(String($0)) })
    }

    static func normalizedCountryCode(_ countryCode: String) -> String {
        countryCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }
}
