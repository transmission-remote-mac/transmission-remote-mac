// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import AppKit
import SwiftUI
import XCTest
@testable import TransmissionRemoteMac

@MainActor
final class SettingsLayoutTests: XCTestCase {
    func testTabChangesPreserveUserSizeAndEveryPageFillsItsProposal() async throws {
        _ = NSApplication.shared
        let suiteName = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = AppStore(
            profileStore: ConnectionProfileStore(fileURL: directory.appendingPathComponent("profiles.json")),
            userDefaults: defaults,
            downloadCompletionNotifier: SettingsLayoutTestNotifier()
        )
        let profile = ConnectionProfile(
            name: String(repeating: "Long server name ", count: 6),
            scheme: "https",
            host: "server.example",
            pathMappings: [PathMapping(remotePathPrefix: "/downloads", localPathPrefix: "/Volumes/Downloads")],
            transferPreferences: ProfileTransferPreferences(
                addDestinationRules: try AddTorrentDestinationRulesSnapshot(
                    defaultDestination: "/downloads/recommended",
                    rules: [
                        AddTorrentDestinationRule(
                            label: "Video downloads with a descriptive destination rule name",
                            destination: "/downloads/video",
                            extensions: ["mkv", "mp4"]
                        )
                    ]
                )
            ),
            clientIdentityMetadata: ClientIdentityMetadata(
                displayName: "Example client certificate with a descriptive display name",
                sha256Fingerprint: String(repeating: "a", count: 64),
                subject: "Example client",
                issuer: "Example certificate authority",
                notBefore: Date(timeIntervalSince1970: 1_700_000_000),
                notAfter: Date(timeIntervalSince1970: 2_000_000_000)
            )
        )
        store.profiles = [profile]
        store.selectedProfileID = profile.id
        let navigation = SettingsNavigationModel()
        let sizes = [NSSize(width: 700, height: 600), NSSize(width: 1_000, height: 820)]
        let sections: [SettingsSection] = [.application, .servers, .daemon, .portability]
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: sizes[0]),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer {
            window.contentView = nil
            window.close()
        }
        let host = NSHostingView(rootView: SettingsView(store: store, navigation: navigation))
        window.contentView = host

        for size in sizes {
            window.setContentSize(size)
            await settleLayout(in: host)
            let userFrame = window.frame
            let fittingSize = host.fittingSize
            for section in sections + [.application] {
                navigation.selectedSection = section
                await settleLayout(in: host)
                XCTAssertEqual(window.frame, userFrame, "Switching to \(section) must not resize the window")
                XCTAssertEqual(host.fittingSize, fittingSize, "Root sizing must not depend on \(section)")
                XCTAssertEqual(host.frame.size, size)
            }
        }

        // Measure the production page before any parent frame can conceal a
        // fixed child size. Daemon and Portability also cover their empty states.
        for section in sections {
            var allocatedSize: CGSize?
            let pageHost = NSHostingView(rootView:
                page(for: section, store: store)
                    .background {
                        GeometryReader { geometry in
                            Color.clear
                                .onAppear { allocatedSize = geometry.size }
                                .onChange(of: geometry.size) { _, size in allocatedSize = size }
                        }
                    }
            )
            window.contentView = pageHost
            for size in sizes {
                window.setContentSize(size)
                await settleLayout(in: pageHost)
                let allocated = try XCTUnwrap(allocatedSize, "\(section) did not report its layout")
                XCTAssertEqual(allocated.width, size.width, accuracy: 1, "\(section) must fill the available width")
                XCTAssertEqual(allocated.height, size.height, accuracy: 1, "\(section) must fill the available height")
                for field in editableFields(in: pageHost) {
                    let frame = field.convert(field.bounds, to: pageHost)
                    XCTAssertGreaterThanOrEqual(frame.minX, -1, "\(section) field must not overflow the leading edge")
                    XCTAssertLessThanOrEqual(frame.maxX, size.width + 1, "\(section) field must not overflow the trailing edge")
                }
            }
        }
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(window.isKeyWindow)
    }

    private func settleLayout(in view: NSView) async {
        for _ in 0..<3 {
            view.layoutSubtreeIfNeeded()
            await Task.yield()
        }
        view.layoutSubtreeIfNeeded()
    }

    private func editableFields(in view: NSView) -> [NSTextField] {
        view.subviews.flatMap { child in
            let fields = editableFields(in: child)
            guard let field = child as? NSTextField, field.isEditable else { return fields }
            return [field] + fields
        }
    }

    @ViewBuilder
    private func page(for section: SettingsSection, store: AppStore) -> some View {
        switch section {
        case .application:
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
        case .servers:
            ConnectionSettingsView(
                profiles: store.profiles,
                selectedProfileID: store.selectedProfileID,
                coordinator: store.connectionSettingsCoordinatorController,
                onApply: store.applyConnectionProfiles
            )
        case .daemon:
            DaemonSessionView(
                optionsController: store.daemonOptionsSettingsController,
                sessionInfo: nil,
                sessionStats: nil
            )
        case .portability:
            SettingsPortabilityView(coordinator: store.settingsPortabilityController)
        }
    }
}

private struct SettingsLayoutTestNotifier: DownloadCompletionNotifying {
    func notifyDownloadCompleted(torrentName: String) {}
}
