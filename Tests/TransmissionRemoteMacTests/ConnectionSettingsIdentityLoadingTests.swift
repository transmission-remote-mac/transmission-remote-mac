// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import AppKit
import Combine
import SwiftUI
import XCTest
@testable import TransmissionRemoteMac

@MainActor
final class ConnectionSettingsIdentityLoadingTests: XCTestCase {
    func testNativeSettingsCloseInvalidatesIdentityLoadBeforeNavigationAndLateCompletion() async throws {
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
            downloadCompletionNotifier: SettingsIdentityTestNotifier()
        )
        let profile = ConnectionProfile(name: "Server", scheme: "https", host: "server.example")
        store.profiles = [profile]
        store.selectedProfileID = profile.id
        let coordinator = store.connectionSettingsCoordinatorController
        let navigation = SettingsNavigationModel()
        navigation.present(.servers, openSettings: {})
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 760),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsView(store: store, navigation: navigation))
        window.contentView?.layoutSubtreeIfNeeded()
        defer {
            window.contentView = nil
            window.close()
        }
        XCTAssertTrue(navigation.isSettingsPresented)
        XCTAssertEqual(navigation.selectedSection, .servers)
        let request = try XCTUnwrap(coordinator.beginClientIdentityLoad(for: profile.id))
        let lateCompletion = Task { @MainActor in
            await Task.yield()
            return coordinator.completeClientIdentityLoad(request, fileName: "late.p12", data: Data([1]))
        }
        var observedNavigationExit = false
        let observer = navigation.$selectedSection.sink { section in
            guard section == .application else { return }
            observedNavigationExit = true
            XCTAssertFalse(coordinator.clientIdentityLoadState.isLoading)
        }

        window.close()

        XCTAssertTrue(observedNavigationExit)
        XCTAssertFalse(navigation.isSettingsPresented)
        XCTAssertFalse(coordinator.clientIdentityLoadState.isLoading)
        let accepted = await lateCompletion.value
        XCTAssertFalse(accepted)
        XCTAssertNil(coordinator.draftProfile(id: profile.id)?.pendingClientIdentityImport)
        withExtendedLifetime(observer) {}
    }

    func testCapturedLastSlotBindingSurvivesDeletionAndLateImportCannotWriteReplacement() async throws {
        let (coordinator, first, second) = makeCoordinator()
        let captured = ConnectionSettingsView.draftBinding(
            for: try XCTUnwrap(coordinator.draftProfile(id: second.id)), coordinator: coordinator
        )
        let request = try XCTUnwrap(coordinator.beginClientIdentityLoad(for: second.id))
        let completion = Task { @MainActor in
            await Task.yield()
            XCTAssertEqual(captured.wrappedValue.id, second.id)
            return coordinator.completeClientIdentityLoad(request, fileName: "late.p12", data: Data([1]))
        }

        coordinator.deleteSelectedProfile()

        XCTAssertFalse(coordinator.clientIdentityLoadState.isLoading)
        XCTAssertEqual(coordinator.draftProfiles.map(\.id), [first.id])
        var removedDraft = captured.wrappedValue
        removedDraft.name = "Stale edit"
        removedDraft.stageClientIdentityImport(fileName: "stale.p12", data: Data([2]))
        captured.wrappedValue = removedDraft
        XCTAssertEqual(coordinator.draftProfiles[0].name, first.name)
        let accepted = await completion.value
        XCTAssertFalse(accepted)
        XCTAssertNil(coordinator.draftProfiles[0].pendingClientIdentityImport)
    }

    func testCapturedBindingResolvesIDAfterReorderAndCurrentImportUsesThatID() throws {
        let (coordinator, first, second) = makeCoordinator()
        let captured = ConnectionSettingsView.draftBinding(
            for: try XCTUnwrap(coordinator.draftProfile(id: second.id)), coordinator: coordinator
        )
        let request = try XCTUnwrap(coordinator.beginClientIdentityLoad(for: second.id))

        coordinator.draftProfiles.reverse()
        captured.wrappedValue.name = "Second renamed"

        XCTAssertEqual(coordinator.draftProfiles.map(\.id), [second.id, first.id])
        XCTAssertEqual(coordinator.draftProfiles[0].name, "Second renamed")
        XCTAssertEqual(coordinator.draftProfiles[1].name, first.name)
        XCTAssertTrue(coordinator.completeClientIdentityLoad(request, fileName: "current.p12", data: Data([1])))
        XCTAssertEqual(coordinator.draftProfiles[0].pendingClientIdentityImport?.pkcs12Data, Data([1]))
        XCTAssertNil(coordinator.draftProfiles[1].pendingClientIdentityImport)
    }

    func testRevertResolvesPersistedDraftButNeverAcceptsEarlierIdentityLoad() throws {
        let (coordinator, _, second) = makeCoordinator()
        let captured = ConnectionSettingsView.draftBinding(
            for: try XCTUnwrap(coordinator.draftProfile(id: second.id)), coordinator: coordinator
        )
        captured.wrappedValue.name = "Unsaved name"
        let request = try XCTUnwrap(coordinator.beginClientIdentityLoad(for: second.id))

        coordinator.resetDrafts()

        XCTAssertEqual(captured.wrappedValue.name, second.name)
        XCTAssertFalse(coordinator.completeClientIdentityLoad(request, fileName: "late.p12", data: Data([1])))
        XCTAssertFalse(coordinator.hasChanges)
        XCTAssertNil(captured.wrappedValue.pendingClientIdentityImport)
    }

    func testOwnerChangingIntentsInvalidateSynchronouslyWithoutViewCallbacks() throws {
        let mutations: [(ConnectionSettingsCoordinator, UUID) -> Void] = [
            { coordinator, firstID in coordinator.editingProfileID = firstID },
            { coordinator, _ in coordinator.addProfile() },
            { coordinator, _ in coordinator.duplicateSelectedProfile() },
            { coordinator, _ in coordinator.deleteSelectedProfile() },
            { coordinator, _ in coordinator.resetDrafts() },
            { coordinator, _ in coordinator.draftProfiles.removeLast() },
            { coordinator, _ in coordinator.draftProfiles[1].scheme = "http" }
        ]
        for mutation in mutations {
            let (coordinator, first, second) = makeCoordinator()
            let request = try XCTUnwrap(coordinator.beginClientIdentityLoad(for: second.id))
            mutation(coordinator, first.id)
            XCTAssertFalse(coordinator.clientIdentityLoadState.isLoading)
            XCTAssertFalse(coordinator.completeClientIdentityLoad(request, fileName: "late.p12", data: Data([1])))
            XCTAssertFalse(coordinator.failClientIdentityLoad(request))
            XCTAssertTrue(coordinator.draftProfiles.allSatisfy { $0.pendingClientIdentityImport == nil })
        }
    }

    func testReplacementLoadAndSaveGuardRemainOwnedByCurrentRequest() throws {
        let (coordinator, first, second) = makeCoordinator()
        XCTAssertNil(coordinator.beginClientIdentityLoad(for: first.id))
        let previous = try XCTUnwrap(coordinator.beginClientIdentityLoad(for: second.id))
        let current = try XCTUnwrap(coordinator.beginClientIdentityLoad(for: second.id))
        XCTAssertNil(coordinator.apply { _, _ in
            XCTFail("Save must not run while identity bytes are loading")
            return .success(())
        })
        XCTAssertTrue(coordinator.blocksSettingsImport)
        XCTAssertFalse(coordinator.failClientIdentityLoad(previous))
        XCTAssertFalse(coordinator.completeClientIdentityLoad(previous, fileName: "old.p12", data: Data([1])))
        XCTAssertEqual(coordinator.clientIdentityLoadState.request, current)
        XCTAssertTrue(coordinator.failClientIdentityLoad(current))
        XCTAssertFalse(coordinator.clientIdentityLoadState.isLoading)
        XCTAssertFalse(coordinator.blocksSettingsImport)
    }

    private func makeCoordinator() -> (ConnectionSettingsCoordinator, ConnectionProfile, ConnectionProfile) {
        let first = ConnectionProfile(name: "First", scheme: "https", host: "first.example")
        let second = ConnectionProfile(name: "Second", scheme: "https", host: "second.example")
        return (
            ConnectionSettingsCoordinator(profiles: [first, second], selectedProfileID: second.id),
            first,
            second
        )
    }
}

private struct SettingsIdentityTestNotifier: DownloadCompletionNotifying {
    func notifyDownloadCompleted(torrentName: String) {}
}
