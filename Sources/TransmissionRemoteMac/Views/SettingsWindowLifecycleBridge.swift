// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import AppKit
import SwiftUI

/// Publishes native Settings-window lifecycle events without relying on
/// `View.onDisappear`, which is not a window-close contract for Settings scenes.
struct SettingsWindowLifecycleBridge: NSViewRepresentable {
    let onPresentation: @MainActor () -> Void
    let onExit: @MainActor () -> Void

    init(
        onPresentation: @escaping @MainActor () -> Void = {},
        onExit: @escaping @MainActor () -> Void
    ) {
        self.onPresentation = onPresentation
        self.onExit = onExit
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onPresentation: onPresentation, onExit: onExit)
    }

    func makeNSView(context: Context) -> WorkspaceHierarchyProbeView {
        let view = WorkspaceHierarchyProbeView()
        view.hierarchyDidChange = { [weak coordinator = context.coordinator] view in
            coordinator?.attach(to: view.window)
        }
        return view
    }

    func updateNSView(_ view: WorkspaceHierarchyProbeView, context: Context) {
        context.coordinator.update(
            onPresentation: onPresentation,
            onExit: onExit
        )
        context.coordinator.attach(to: view.window)
    }

    @MainActor
    final class Coordinator {
        private weak var window: NSWindow?
        private var hasPublishedPresentation = false
        private var didPublishExit = false
        private var windowPresentationObserver: NSObjectProtocol?
        private var windowCloseObserver: NSObjectProtocol?
        private var applicationTerminationObserver: NSObjectProtocol?
        private var onPresentation: @MainActor () -> Void
        private var onExit: @MainActor () -> Void

        init(
            onPresentation: @escaping @MainActor () -> Void = {},
            onExit: @escaping @MainActor () -> Void
        ) {
            self.onPresentation = onPresentation
            self.onExit = onExit
            applicationTerminationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.publishExitIfNeeded()
                }
            }
        }

        deinit {
            if let windowPresentationObserver {
                NotificationCenter.default.removeObserver(windowPresentationObserver)
            }
            if let windowCloseObserver {
                NotificationCenter.default.removeObserver(windowCloseObserver)
            }
            if let applicationTerminationObserver {
                NotificationCenter.default.removeObserver(applicationTerminationObserver)
            }
        }

        func update(
            onPresentation: @escaping @MainActor () -> Void = {},
            onExit: @escaping @MainActor () -> Void
        ) {
            self.onPresentation = onPresentation
            self.onExit = onExit
        }

        func attach(to window: NSWindow?) {
            guard self.window !== window else { return }
            if let windowPresentationObserver {
                NotificationCenter.default.removeObserver(windowPresentationObserver)
                self.windowPresentationObserver = nil
            }
            if let windowCloseObserver {
                NotificationCenter.default.removeObserver(windowCloseObserver)
                self.windowCloseObserver = nil
            }
            self.window = window
            guard let window else { return }
            publishPresentationIfNeeded()
            windowPresentationObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.publishPresentationIfNeeded()
                }
            }
            windowCloseObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.publishExitIfNeeded()
                }
            }
        }

        private func publishPresentationIfNeeded() {
            guard !hasPublishedPresentation || didPublishExit else { return }
            hasPublishedPresentation = true
            didPublishExit = false
            onPresentation()
        }

        private func publishExitIfNeeded() {
            guard hasPublishedPresentation, !didPublishExit else { return }
            didPublishExit = true
            onExit()
        }
    }
}
