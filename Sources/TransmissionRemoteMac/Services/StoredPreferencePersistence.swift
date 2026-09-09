// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation

/// Shared byte storage only. Typed preference models retain decoding, migration
/// and validation, while their observable stores retain publication ownership.
@MainActor
struct StoredPreferencePersistence {
    let userDefaults: UserDefaults
    let storageKey: String
    let encoder: JSONEncoder
    let decoder: JSONDecoder

    func load<Value: Codable>(defaults: Value, currentSchemaVersion: Int) -> Value {
        let storedData = userDefaults.data(forKey: storageKey)
        guard !StoredPreferenceSchema.isFutureVersion(
            in: storedData,
            key: "schemaVersion",
            currentVersion: currentSchemaVersion
        ) else {
            // A newer app owns these bytes until the user explicitly saves.
            return defaults
        }

        let value = storedData.flatMap { try? decoder.decode(Value.self, from: $0) } ?? defaults
        if let canonicalData = try? encoder.encode(value),
           !Self.hasSameJSONContent(storedData, canonicalData) {
            userDefaults.set(canonicalData, forKey: storageKey)
        }
        return value
    }

    func save<Value: Encodable>(_ value: Value) throws {
        let data = try encoder.encode(value)
        userDefaults.set(data, forKey: storageKey)
    }

    private static func hasSameJSONContent(_ storedData: Data?, _ canonicalData: Data) -> Bool {
        guard let storedData else { return false }
        if storedData == canonicalData { return true }
        guard
            let storedObject = try? JSONSerialization.jsonObject(with: storedData),
            let canonicalObject = try? JSONSerialization.jsonObject(with: canonicalData),
            let stored = try? JSONSerialization.data(withJSONObject: storedObject, options: .sortedKeys),
            let canonical = try? JSONSerialization.data(withJSONObject: canonicalObject, options: .sortedKeys)
        else {
            return false
        }
        // Ignore whitespace/key order, not JSON types: NSDictionary equality
        // would conflate true with 1 and leave malformed typed fields on disk.
        return stored == canonical
    }
}
