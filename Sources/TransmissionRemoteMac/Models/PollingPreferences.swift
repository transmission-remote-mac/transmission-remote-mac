// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation

enum PollingVisibilityState: Equatable, Sendable {
    case foreground
    case background
}

enum BackgroundPollingPolicy: String, CaseIterable, Codable, Identifiable, Sendable {
    case pollSlowly
    case suspend

    var id: Self { self }

    var title: String {
        switch self {
        case .pollSlowly: "Poll slowly"
        case .suspend: "Suspend polling"
        }
    }
}

struct PollingPreferences: Equatable, Sendable {
    static let allowedIntervalSeconds = 1...999
    static let defaults = PollingPreferences(
        foregroundIntervalSeconds: 5,
        backgroundIntervalSeconds: 20,
        backgroundPolicy: .pollSlowly,
        adaptiveIdleEnabled: false
    )

    var foregroundIntervalSeconds: Int
    var backgroundIntervalSeconds: Int
    var backgroundPolicy: BackgroundPollingPolicy
    var adaptiveIdleEnabled: Bool

    init(
        foregroundIntervalSeconds: Int,
        backgroundIntervalSeconds: Int,
        backgroundPolicy: BackgroundPollingPolicy,
        adaptiveIdleEnabled: Bool = false
    ) {
        self.foregroundIntervalSeconds = foregroundIntervalSeconds
        self.backgroundIntervalSeconds = backgroundIntervalSeconds
        self.backgroundPolicy = backgroundPolicy
        self.adaptiveIdleEnabled = adaptiveIdleEnabled
    }

    var validationIssues: [String] {
        var issues: [String] = []
        if !Self.allowedIntervalSeconds.contains(foregroundIntervalSeconds) {
            issues.append("Foreground polling must be between 1 and 999 seconds.")
        }
        if !Self.allowedIntervalSeconds.contains(backgroundIntervalSeconds) {
            issues.append("Background polling must be between 1 and 999 seconds.")
        }
        return issues
    }

    func intervalSeconds(for visibility: PollingVisibilityState) -> Int? {
        switch visibility {
        case .foreground:
            foregroundIntervalSeconds
        case .background where backgroundPolicy == .pollSlowly:
            backgroundIntervalSeconds
        case .background:
            nil
        }
    }

    static func load(from userDefaults: UserDefaults) -> PollingPreferences {
        let foregroundInterval = validPersistedInterval(
            userDefaults.object(forKey: DefaultsKey.foregroundIntervalSeconds)
        ) ?? defaults.foregroundIntervalSeconds
        let backgroundInterval = validPersistedInterval(
            userDefaults.object(forKey: DefaultsKey.backgroundIntervalSeconds)
        ) ?? defaults.backgroundIntervalSeconds
        let backgroundPolicy = userDefaults.string(forKey: DefaultsKey.backgroundPolicy)
            .flatMap(BackgroundPollingPolicy.init(rawValue:))
            ?? defaults.backgroundPolicy
        let adaptiveIdleEnabled = validPersistedBoolean(
            userDefaults.object(forKey: DefaultsKey.adaptiveIdleEnabled)
        ) ?? defaults.adaptiveIdleEnabled

        let preferences = PollingPreferences(
            foregroundIntervalSeconds: foregroundInterval,
            backgroundIntervalSeconds: backgroundInterval,
            backgroundPolicy: backgroundPolicy,
            adaptiveIdleEnabled: adaptiveIdleEnabled
        )
        preferences.save(to: userDefaults)
        return preferences
    }

    func save(to userDefaults: UserDefaults) {
        guard validationIssues.isEmpty else { return }
        userDefaults.set(foregroundIntervalSeconds, forKey: DefaultsKey.foregroundIntervalSeconds)
        userDefaults.set(backgroundIntervalSeconds, forKey: DefaultsKey.backgroundIntervalSeconds)
        userDefaults.set(backgroundPolicy.rawValue, forKey: DefaultsKey.backgroundPolicy)
        userDefaults.set(adaptiveIdleEnabled, forKey: DefaultsKey.adaptiveIdleEnabled)
    }

    private static func validPersistedInterval(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        let interval = number.intValue
        return allowedIntervalSeconds.contains(interval) ? interval : nil
    }

    private static func validPersistedBoolean(_ value: Any?) -> Bool? {
        guard
            let number = value as? NSNumber,
            CFGetTypeID(number) == CFBooleanGetTypeID()
        else {
            return nil
        }
        return number.boolValue
    }

    private enum DefaultsKey {
        static let foregroundIntervalSeconds = "application.polling.foregroundIntervalSeconds.v1"
        static let backgroundIntervalSeconds = "application.polling.backgroundIntervalSeconds.v1"
        static let backgroundPolicy = "application.polling.backgroundPolicy.v1"
        static let adaptiveIdleEnabled = "application.polling.adaptiveIdleEnabled.v1"
    }
}
