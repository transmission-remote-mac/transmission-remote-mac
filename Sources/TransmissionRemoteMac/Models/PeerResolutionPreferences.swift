// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation

/// Privacy-sensitive peer enrichment is opt-in. Country lookup is local-only
/// and cannot become effective until a validated country database is installed.
struct PeerResolutionPreferences: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 2
    static let defaults = PeerResolutionPreferences(
        resolveHostNames: false,
        resolveCountries: false,
        showCountryFlags: false
    )

    var resolveHostNames: Bool
    var resolveCountries: Bool
    var showCountryFlags: Bool
    /// Blank selects the latest DB-IP Country Lite download when requested.
    var countryDatabaseSourceURL: String

    init(
        resolveHostNames: Bool,
        resolveCountries: Bool,
        showCountryFlags: Bool,
        countryDatabaseSourceURL: String = ""
    ) {
        self.resolveHostNames = resolveHostNames
        self.resolveCountries = resolveCountries
        self.showCountryFlags = showCountryFlags
        self.countryDatabaseSourceURL = countryDatabaseSourceURL
    }

    /// The download source is not a runtime resolution setting. Leaving it out
    /// prevents a source-only preference edit from restarting peer lookups.
    func effective(countryDatabaseAvailable: Bool) -> PeerResolutionPreferences {
        guard countryDatabaseAvailable else {
            return PeerResolutionPreferences(
                resolveHostNames: resolveHostNames,
                resolveCountries: false,
                showCountryFlags: false
            )
        }
        return PeerResolutionPreferences(
            resolveHostNames: resolveHostNames,
            resolveCountries: resolveCountries,
            showCountryFlags: resolveCountries && showCountryFlags
        )
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case resolveHostNames
        case resolveCountries
        case showCountryFlags
        case countryDatabaseSourceURL
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = (try? container.decode(Int.self, forKey: .schemaVersion)) ?? 0
        guard (0 ... Self.currentSchemaVersion).contains(schemaVersion) else {
            self = .defaults
            return
        }
        self.init(
            resolveHostNames: (try? container.decode(Bool.self, forKey: .resolveHostNames))
                ?? Self.defaults.resolveHostNames,
            resolveCountries: (try? container.decode(Bool.self, forKey: .resolveCountries))
                ?? Self.defaults.resolveCountries,
            showCountryFlags: (try? container.decode(Bool.self, forKey: .showCountryFlags))
                ?? Self.defaults.showCountryFlags,
            countryDatabaseSourceURL: (try? container.decode(String.self, forKey: .countryDatabaseSourceURL))
                ?? Self.defaults.countryDatabaseSourceURL
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(resolveHostNames, forKey: .resolveHostNames)
        try container.encode(resolveCountries, forKey: .resolveCountries)
        try container.encode(showCountryFlags, forKey: .showCountryFlags)
        try container.encode(countryDatabaseSourceURL, forKey: .countryDatabaseSourceURL)
    }
}
