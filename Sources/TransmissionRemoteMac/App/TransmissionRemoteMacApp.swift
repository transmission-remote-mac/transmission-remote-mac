// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import SwiftUI

@MainActor
private final class ApplicationConnectionLifecycle: ObservableObject {
    let store: AppStore
    let userDefaults: UserDefaults
    private var launchTask: Task<Void, Never>?

    init() {
        let profileStore = ConnectionProfileStore()
        let userDefaults = ApplicationUserDefaultsFactory.defaultStore
        let store = AppStore(profileStore: profileStore, userDefaults: userDefaults)
        self.store = store
        self.userDefaults = userDefaults
        launchTask = Task { @MainActor [weak store] in
            await store?.start()
        }
    }

    deinit {
        launchTask?.cancel()
    }
}

@main
struct TransmissionRemoteMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var lifecycle = ApplicationConnectionLifecycle()
    @StateObject private var settingsNavigation = SettingsNavigationModel()

    var body: some Scene {
        Window("Transmission Remote Mac", id: "main") {
            ApplicationContentView(
                store: lifecycle.store,
                settingsNavigation: settingsNavigation
            )
            .defaultAppStorage(lifecycle.userDefaults)
            .environmentObject(settingsNavigation)
            .onAppear {
                appDelegate.attach(store: lifecycle.store)
            }
        }
        .commands {
            AppCommands(
                store: lifecycle.store,
                settingsNavigation: settingsNavigation,
                interactionPreferencesStore: lifecycle.store.interactionPreferencesController
            )
        }

        Settings {
            SettingsView(
                store: lifecycle.store,
                navigation: settingsNavigation
            )
            .defaultAppStorage(lifecycle.userDefaults)
        }
        .windowResizability(.contentMinSize)
    }
}

private struct ApplicationContentView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var settingsNavigation: SettingsNavigationModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        ContentView(store: store)
            .task(id: store.needsConnectionSetup) {
                settingsNavigation.presentServersForFirstRunIfNeeded(
                    needsConnectionSetup: store.needsConnectionSetup
                ) {
                    openSettings()
                }
            }
    }
}
