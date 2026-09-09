// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var navigation: SettingsNavigationModel

    var body: some View {
        // Keep the window's preferred size independent of the selected page.
        GeometryReader { geometry in
            settingsTabs
                .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .frame(
            minWidth: 700, idealWidth: 760, maxWidth: .infinity,
            minHeight: 500, idealHeight: 760, maxHeight: .infinity
        )
        .background {
            SettingsWindowLifecycleBridge(
                onPresentation: navigation.settingsDidAppear,
                onExit: {
                    store.connectionSettingsCoordinatorController.clientIdentityLoadState.cancel()
                    navigation.settingsDidDisappear()
                }
            )
            .frame(width: 0, height: 0)
        }
    }

    private var settingsTabs: some View {
        TabView(selection: $navigation.selectedSection) {
            ApplicationSettingsView(
                preferences: store.pollingPreferences,
                interactionPreferencesStore: store.interactionPreferencesController,
                behaviorPreferencesStore: store.behaviorPreferencesController,
                intakeAutomationPreferencesStore: store.intakeAutomationPreferencesController,
                watchFolderPreferencesStore: store.watchFolderPreferencesController,
                workspacePreferencesStore: store.workspacePreferencesController,
                peerResolutionPreferencesStore: store.peerResolutionPreferencesController,
                peerCountryDatabaseController: store.peerCountryDatabaseController,
                draftSession: store.applicationSettingsDraftSessionController,
                onClearPeerResolutionCache: store.clearPeerResolutionCaches,
                onPersistPollingPreferences: store.persistApplicationPollingPreferences,
                onApplyRuntimeSnapshot: store.applyApplicationSettingsSnapshot
            )
            .tabItem {
                Label("Application", systemImage: "gear")
            }
            .tag(SettingsSection.application)

            ConnectionSettingsView(
                profiles: store.profiles,
                selectedProfileID: store.selectedProfileID,
                coordinator: store.connectionSettingsCoordinatorController,
                onApply: store.applyConnectionProfiles
            )
            .tabItem {
                Label("Servers", systemImage: "server.rack")
            }
            .tag(SettingsSection.servers)

            DaemonSessionView(
                optionsController: store.daemonOptionsSettingsController,
                sessionInfo: store.sessionInfo,
                sessionStats: store.sessionStats,
                isApplyingOptions: store.isApplyingDaemonOptions,
                isTestingPort: store.isTestingPort,
                isUpdatingBlocklist: store.isUpdatingBlocklist,
                maintenanceNotice: store.daemonMaintenanceNotice,
                onApplyOptions: store.applyDaemonOptions,
                onTestPort: store.testPort,
                onUpdateBlocklist: store.updateBlocklist,
                onDismissMaintenanceNotice: store.dismissDaemonMaintenanceNotice
            )
            .tabItem {
                Label("Daemon", systemImage: "gearshape")
            }
            .tag(SettingsSection.daemon)

            SettingsPortabilityView(
                coordinator: store.settingsPortabilityController
            )
            .tabItem {
                Label("Portability", systemImage: "arrow.up.arrow.down.circle")
            }
            .tag(SettingsSection.portability)
        }
    }
}
