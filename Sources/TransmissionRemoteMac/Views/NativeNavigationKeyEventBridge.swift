// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import AppKit
import SwiftUI

struct NativeNavigationKeyEventBridge: NSViewRepresentable {
    let shortcutBindings: [NativeCommandShortcutBinding]
    let onCommand: @MainActor (NativeCommandID) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NativeNavigationWindowProbeView {
        let view = NativeNavigationWindowProbeView()
        view.windowDidChange = { [weak coordinator = context.coordinator] window in
            coordinator?.attach(to: window)
        }
        context.coordinator.update(
            shortcutBindings: shortcutBindings,
            onCommand: onCommand
        )
        return view
    }

    func updateNSView(_ view: NativeNavigationWindowProbeView, context: Context) {
        context.coordinator.update(
            shortcutBindings: shortcutBindings,
            onCommand: onCommand
        )
        context.coordinator.attach(to: view.window)
    }

    static func dismantleNSView(
        _ view: NativeNavigationWindowProbeView,
        coordinator: Coordinator
    ) {
        view.windowDidChange = nil
        coordinator.stop()
    }

    @MainActor
    final class Coordinator {
        private weak var window: NSWindow?
        private var shortcutBindings: [NativeCommandShortcutBinding] = []
        private var onCommand: (@MainActor (NativeCommandID) -> Void)?
        private var eventMonitor: Any?
        private let eventPolicy = NativeNavigationShortcutEventPolicy()

        deinit {
            if let eventMonitor {
                NSEvent.removeMonitor(eventMonitor)
            }
        }

        func update(
            shortcutBindings: [NativeCommandShortcutBinding],
            onCommand: @escaping @MainActor (NativeCommandID) -> Void
        ) {
            self.shortcutBindings = shortcutBindings
            self.onCommand = onCommand
        }

        func attach(to window: NSWindow?) {
            guard self.window !== window else { return }
            self.window = window
            if window == nil {
                removeEventMonitor()
            } else {
                installEventMonitorIfNeeded()
            }
        }

        func stop() {
            window = nil
            onCommand = nil
            shortcutBindings = []
            removeEventMonitor()
        }

        private func installEventMonitorIfNeeded() {
            guard eventMonitor == nil else { return }
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let shouldConsume = MainActor.assumeIsolated {
                    self?.handle(event) ?? false
                }
                return shouldConsume ? nil : event
            }
        }

        private func removeEventMonitor() {
            guard let eventMonitor else { return }
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }

        private func handle(_ event: NSEvent) -> Bool {
            switch eventPolicy.disposition(
                for: event,
                targetWindow: window,
                bindings: shortcutBindings
            ) {
            case .passThrough:
                return false
            case .consume:
                return true
            case .perform(let commandID):
                onCommand?(commandID)
                return true
            }
        }
    }
}

@MainActor
final class NativeNavigationWindowProbeView: NSView {
    var windowDidChange: (@MainActor (NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowDidChange?(window)
    }
}
