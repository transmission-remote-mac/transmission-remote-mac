// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Combine

enum SettingsSection: Hashable {
    case application
    case servers
    case daemon
    case portability
}

@MainActor
final class SettingsNavigationModel: ObservableObject {
    @Published var selectedSection: SettingsSection = .application

    private(set) var isSettingsPresented = false
    private var requestedSection: SettingsSection?
    private var isOpenRequestInFlight = false
    private var didHandleFirstRun = false

    func present(_ section: SettingsSection, openSettings: () -> Void) {
        requestedSection = section
        selectedSection = section

        if isSettingsPresented {
            openSettings()
            return
        }

        guard !isOpenRequestInFlight else { return }
        isOpenRequestInFlight = true
        openSettings()
    }

    func presentServersForFirstRunIfNeeded(
        needsConnectionSetup: Bool,
        openSettings: () -> Void
    ) {
        guard needsConnectionSetup, !didHandleFirstRun else { return }
        didHandleFirstRun = true
        present(.servers, openSettings: openSettings)
    }

    func settingsDidAppear() {
        isSettingsPresented = true
        isOpenRequestInFlight = false
        selectedSection = requestedSection ?? .application
        requestedSection = nil
    }

    func settingsDidDisappear() {
        isSettingsPresented = false
        isOpenRequestInFlight = false
        requestedSection = nil
        selectedSection = .application
    }
}
