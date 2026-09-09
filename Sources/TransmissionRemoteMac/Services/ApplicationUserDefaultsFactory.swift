// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation

enum ApplicationUserDefaultsFactory {
    static var defaultStore: UserDefaults {
#if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if environment[PerformancePasswordStoreIsolation.modeEnvironmentKey] != nil {
            guard let userDefaults = PerformancePreferencesIsolation.activeUserDefaults else {
                preconditionFailure("Rejected invalid performance preferences isolation context")
            }
            return userDefaults
        }
#endif
        return .standard
    }
}

#if DEBUG
enum PerformancePreferencesIsolation {
    static let suiteEnvironmentKey = "TRANSMISSION_REMOTE_MAC_PERFORMANCE_DEFAULTS_SUITE"
    static let foregroundIntervalEnvironmentKey =
        "TRANSMISSION_REMOTE_MAC_PERFORMANCE_FOREGROUND_INTERVAL"
    static let backgroundIntervalEnvironmentKey =
        "TRANSMISSION_REMOTE_MAC_PERFORMANCE_BACKGROUND_INTERVAL"
    static let backgroundPolicyEnvironmentKey =
        "TRANSMISSION_REMOTE_MAC_PERFORMANCE_BACKGROUND_POLICY"
    static let suitePrefix = "net.pokwer.TransmissionRemoteMac.performance"

    static let activeUserDefaults: UserDefaults? = activateIfRequested()

    private static func activateIfRequested(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        resolvedHomePath: String = NSHomeDirectory(),
        fileManager: FileManager = .default
    ) -> UserDefaults? {
        guard environment[PerformancePasswordStoreIsolation.modeEnvironmentKey] != nil else {
            return nil
        }
        guard
            environment[PerformancePasswordStoreIsolation.modeEnvironmentKey] == "1",
            let declaredHomePath = environment[PerformancePasswordStoreIsolation.homeEnvironmentKey],
            let token = environment[PerformancePasswordStoreIsolation.tokenEnvironmentKey],
            token.count >= 32,
            let suiteName = environment[suiteEnvironmentKey],
            suiteName == "\(suitePrefix).\(token)",
            let foregroundText = environment[foregroundIntervalEnvironmentKey],
            let foregroundInterval = Int(foregroundText),
            let backgroundText = environment[backgroundIntervalEnvironmentKey],
            let backgroundInterval = Int(backgroundText),
            let policyText = environment[backgroundPolicyEnvironmentKey],
            let backgroundPolicy = BackgroundPollingPolicy(rawValue: policyText),
            PollingPreferences.allowedIntervalSeconds.contains(foregroundInterval),
            PollingPreferences.allowedIntervalSeconds.contains(backgroundInterval)
        else {
            return nil
        }

        let declaredHome = canonicalURL(for: declaredHomePath)
        let resolvedHome = canonicalURL(for: resolvedHomePath)
        guard declaredHome.path != "/", declaredHome == resolvedHome else { return nil }

        let proofURL = declaredHome.appendingPathComponent(
            PerformancePasswordStoreIsolation.activationProofName,
            isDirectory: false
        )
        guard
            let proof = try? String(contentsOf: proofURL, encoding: .utf8),
            proof == "\(PerformancePasswordStoreIsolation.compiledMarker)\n\(token)\n",
            fileManager.fileExists(atPath: proofURL.path),
            let userDefaults = UserDefaults(suiteName: suiteName)
        else {
            return nil
        }

        userDefaults.removePersistentDomain(forName: suiteName)
        PollingPreferences(
            foregroundIntervalSeconds: foregroundInterval,
            backgroundIntervalSeconds: backgroundInterval,
            backgroundPolicy: backgroundPolicy,
            adaptiveIdleEnabled: true
        ).save(to: userDefaults)
        return userDefaults
    }

    private static func canonicalURL(for path: String) -> URL {
        URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
    }
}
#endif
