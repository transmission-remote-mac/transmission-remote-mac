// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation

enum StoredPreferenceSchema {
    static func isFutureVersion(
        in data: Data?,
        key: String,
        currentVersion: Int
    ) -> Bool {
        guard
            let data,
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let version = object[key] as? Int
        else {
            return false
        }
        return version > currentVersion
    }
}
