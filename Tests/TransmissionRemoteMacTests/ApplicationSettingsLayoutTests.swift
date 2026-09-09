// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import AppKit
import SwiftUI
import XCTest
@testable import TransmissionRemoteMac

final class ApplicationSettingsLayoutTests: XCTestCase {
    @MainActor
    func testValueFieldsKeepNativeWidthAndSingleLineUnits() throws {
        _ = NSApplication.shared
        for width in [CGFloat(700), CGFloat(1_000)] {
            for control in valueFields {
                let host = NSHostingView(rootView: control)
                host.frame = NSRect(x: 0, y: 0, width: width, height: 60)
                host.layoutSubtreeIfNeeded()

                XCTAssertLessThanOrEqual(host.fittingSize.height, 32, control.accessibilityLabel)
                XCTAssertLessThanOrEqual(host.fittingSize.width, 190, control.accessibilityLabel)
                let fields = descendants(of: host).compactMap { $0 as? NSTextField }.filter(\.isEditable)
                let field = try XCTUnwrap(fields.first, control.accessibilityLabel)
                XCTAssertEqual(fields.count, 1)
                XCTAssertEqual(field.frame.width, control.fieldWidth, accuracy: 4)
            }
        }
    }

    @MainActor
    func testGroupedFormPreservesNativeFieldWidthsHeightsAndContainment() throws {
        _ = NSApplication.shared
        let controls = valueFields
        let titles = ["Samples", "Maximum window", "Peer limit"]
        let longName = String(repeating: "Long server name ", count: 6)
        for width in [CGFloat(700), CGFloat(1_000)] {
            let host = NSHostingView(rootView:
                Form {
                    Section {
                        ForEach(controls.indices, id: \.self) { index in
                            LabeledContent(titles[index]) {
                                controls[index]
                            }
                        }
                        TextField("Server name", text: .constant(longName))
                        LabeledContent {
                            Text("Ready")
                        } label: {
                            VStack(alignment: .leading) {
                                Text("While hidden")
                                Text("Use a lower polling rate when the application is inactive, minimized or occluded.")
                                    .font(.caption)
                            }
                        }
                    } header: {
                        Label("Speed averaging and new torrents", systemImage: "gauge.with.dots.needle.67percent")
                    } footer: {
                        Text("Numeric values and their units remain together inside the grouped settings form.")
                    }
                }
                .formStyle(.grouped)
            )
            host.frame = NSRect(x: 0, y: 0, width: width, height: 320)
            host.layoutSubtreeIfNeeded()

            let fields = descendants(of: host).compactMap { $0 as? NSTextField }.filter(\.isEditable)
            XCTAssertEqual(fields.count, controls.count + 1)
            for field in fields {
                let fieldFrame = field.convert(field.bounds, to: host)
                XCTAssertGreaterThanOrEqual(fieldFrame.minX, host.bounds.minX)
                XCTAssertLessThanOrEqual(fieldFrame.maxX, host.bounds.maxX)
            }
            for control in controls {
                let field = try XCTUnwrap(fields.first { $0.stringValue == control.text }, control.accessibilityLabel)
                XCTAssertEqual(field.frame.width, control.fieldWidth, accuracy: 4)
                XCTAssertLessThanOrEqual(field.frame.height, 32, control.accessibilityLabel)
            }
            let nameField = try XCTUnwrap(fields.first { $0.stringValue == longName })
            let fieldFrame = nameField.convert(nameField.bounds, to: host)
            XCTAssertGreaterThan(fieldFrame.width, 64)
        }
    }

    @MainActor
    func testDependentValueFieldsFollowSavedEnablementWithoutLosingValues() async throws {
        _ = NSApplication.shared
        let suiteName = "ApplicationSettingsVisibilityTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let behaviorStore = ApplicationBehaviorPreferencesStore(userDefaults: defaults)
        var behavior = ApplicationBehaviorPreferences.defaults
        behavior.speedAveraging = SpeedAveragingPolicy(isEnabled: true, sampleLimit: 67, windowSeconds: 777)
        try behaviorStore.save(behavior)
        let watchStore = WatchFolderPreferencesStore(userDefaults: defaults)
        try watchStore.saveConfiguration(WatchFolderConfiguration(
            isEnabled: true,
            sourceBookmarkData: Data("isolated-bookmark".utf8),
            remoteDestination: "/downloads/retained",
            scanIntervalSeconds: 137,
            successPolicy: .deleteSource,
            submissionPolicy: .submitDirectly,
            processedFolderBookmarkData: nil
        ))
        let store = AppStore(
            profileStore: ConnectionProfileStore(fileURL: directory.appendingPathComponent("profiles.json")),
            userDefaults: defaults,
            downloadCompletionNotifier: ApplicationSettingsVisibilityTestNotifier()
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 6_000),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer {
            window.contentView = nil
            window.close()
        }
        let host = NSHostingView(rootView: ApplicationSettingsView(
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
        ))
        window.contentView = host
        await settleLayout(in: host)
        let frame = window.frame
        let savedBehavior = store.behaviorPreferencesController.preferences
        let savedWatch = store.watchFolderPreferencesController.configuration
        for enabled in [true, false, true] {
            var updatedBehavior = savedBehavior
            updatedBehavior.speedAveraging = SpeedAveragingPolicy(
                isEnabled: enabled,
                sampleLimit: savedBehavior.speedAveraging.sampleLimit,
                windowSeconds: savedBehavior.speedAveraging.windowSeconds
            )
            try store.behaviorPreferencesController.save(updatedBehavior)
            try store.watchFolderPreferencesController.saveConfiguration(WatchFolderConfiguration(
                isEnabled: enabled,
                sourceBookmarkData: savedWatch.sourceBookmarkData,
                remoteDestination: savedWatch.remoteDestination,
                scanIntervalSeconds: savedWatch.scanIntervalSeconds,
                successPolicy: savedWatch.successPolicy,
                submissionPolicy: savedWatch.submissionPolicy,
                processedFolderBookmarkData: savedWatch.processedFolderBookmarkData
            ))
            await settleLayout(in: host)

            let values = descendants(of: host).compactMap { $0 as? NSTextField }.filter(\.isEditable).map(\.stringValue)
            for value in ["67", "777", "/downloads/retained", "137"] {
                XCTAssertEqual(values.contains(value), enabled, "\(value), enabled: \(enabled)")
            }
            XCTAssertEqual(window.frame, frame)
        }
        XCTAssertEqual(store.behaviorPreferencesController.preferences, savedBehavior)
        XCTAssertEqual(store.watchFolderPreferencesController.configuration, savedWatch)
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(window.isKeyWindow)
    }

    @MainActor
    private var valueFields: [ApplicationSettingsValueField] {
        [
            ApplicationSettingsValueField(accessibilityLabel: "Speed averaging samples", text: .constant("20")),
            ApplicationSettingsValueField(
                accessibilityLabel: "Maximum averaging window in seconds", text: .constant("120"), unit: "seconds"
            ),
            ApplicationSettingsValueField(
                accessibilityLabel: "New torrent peer limit", text: .constant(""), prompt: "Daemon default", fieldWidth: 110
            ),
        ]
    }

    @MainActor
    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    @MainActor
    private func settleLayout(in view: NSView) async {
        for _ in 0..<3 {
            view.layoutSubtreeIfNeeded()
            await Task.yield()
        }
        view.layoutSubtreeIfNeeded()
    }
}

private struct ApplicationSettingsVisibilityTestNotifier: DownloadCompletionNotifying {
    func notifyDownloadCompleted(torrentName: String) {}
}
