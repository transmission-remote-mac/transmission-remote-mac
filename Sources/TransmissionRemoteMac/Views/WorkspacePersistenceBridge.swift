// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import AppKit
import SwiftUI

enum MainWindowFramePersistencePolicy {
    static func permitsPersistence(
        isRestoring: Bool,
        isInLiveResize: Bool,
        styleMask: NSWindow.StyleMask
    ) -> Bool {
        !isRestoring && !isInLiveResize && !styleMask.contains(.fullScreen)
    }
}

struct MainWindowWorkspaceBridge: NSViewRepresentable {
    let savedPlacement: MainWindowPlacement?
    let savedPlacementSourceID: UUID?
    let onPlacementChange: @MainActor (MainWindowPlacement, UUID) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WorkspaceHierarchyProbeView {
        let view = WorkspaceHierarchyProbeView()
        view.hierarchyDidChange = { [weak coordinator = context.coordinator] view in
            coordinator?.attach(to: view.window)
        }
        context.coordinator.update(
            savedPlacement: savedPlacement,
            savedPlacementSourceID: savedPlacementSourceID,
            onPlacementChange: onPlacementChange
        )
        return view
    }

    func updateNSView(_ view: WorkspaceHierarchyProbeView, context: Context) {
        context.coordinator.update(
            savedPlacement: savedPlacement,
            savedPlacementSourceID: savedPlacementSourceID,
            onPlacementChange: onPlacementChange
        )
        context.coordinator.attach(to: view.window)
    }

    @MainActor
    final class Coordinator {
        private weak var window: NSWindow?
        private var observers: [NSObjectProtocol] = []
        private var placementSourceID = UUID()
        private var savedPlacement: MainWindowPlacement?
        private var onPlacementChange: (@MainActor (MainWindowPlacement, UUID) -> Void)?
        private var restoredWindowIdentifier: ObjectIdentifier?
        private var lastPublishedPlacement: MainWindowPlacement?
        private var hasPendingExternalRestoration = false
        private var pendingPersistence: DispatchWorkItem?
        private var isRestoring = false

        deinit {
            pendingPersistence?.cancel()
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
        }

        func update(
            savedPlacement: MainWindowPlacement?,
            savedPlacementSourceID: UUID? = nil,
            onPlacementChange: @escaping @MainActor (MainWindowPlacement, UUID) -> Void
        ) {
            let placementChanged = self.savedPlacement != savedPlacement
            self.savedPlacement = savedPlacement
            self.onPlacementChange = onPlacementChange
            guard placementChanged else { return }
            if savedPlacementSourceID == placementSourceID { return }
            lastPublishedPlacement = nil
            guard let window else { return }
            if window.inLiveResize || window.styleMask.contains(.fullScreen) {
                hasPendingExternalRestoration = true
                return
            }

            hasPendingExternalRestoration = false
            restoredWindowIdentifier = nil
            restoreIfNeeded(window)
        }

        func attach(to window: NSWindow?) {
            guard let window else { return }
            guard self.window !== window else { return }

            detach()
            placementSourceID = UUID()
            lastPublishedPlacement = nil
            hasPendingExternalRestoration = false
            window.minSize = Self.minimumWindowSize
            self.window = window
            installObservers(for: window)

            restoreIfNeeded(window)
            schedulePersistence()
        }

        private func detach() {
            pendingPersistence?.cancel()
            pendingPersistence = nil
            persistNow()
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
            observers = []
            window = nil
        }

        private func installObservers(for window: NSWindow) {
            let center = NotificationCenter.default
            observers.append(center.addObserver(
                forName: NSWindow.didMoveNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.schedulePersistence()
                }
            })
            observers.append(center.addObserver(
                forName: NSWindow.didResizeNotification,
                object: window,
                queue: .main
            ) { [weak self, weak window] _ in
                MainActor.assumeIsolated {
                    guard let self, let window else { return }
                    if window.inLiveResize {
                        self.pendingPersistence?.cancel()
                        self.pendingPersistence = nil
                    } else {
                        self.schedulePersistence()
                    }
                }
            })
            observers.append(center.addObserver(
                forName: NSWindow.didEndLiveResizeNotification,
                object: window,
                queue: .main
            ) { [weak self, weak window] _ in
                MainActor.assumeIsolated {
                    guard let self, let window else { return }
                    self.restorePendingExternalPlacementIfPossible(in: window)
                    self.schedulePersistence()
                }
            })
            observers.append(center.addObserver(
                forName: NSWindow.didExitFullScreenNotification,
                object: window,
                queue: .main
            ) { [weak self, weak window] _ in
                MainActor.assumeIsolated {
                    guard let self, let window else { return }
                    self.restorePendingExternalPlacementIfPossible(in: window)
                    self.schedulePersistence()
                }
            })
            observers.append(center.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.pendingPersistence?.cancel()
                    self?.persistNow()
                }
            })
            observers.append(center.addObserver(
                forName: NSApplication.willTerminateNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.pendingPersistence?.cancel()
                    self?.persistNow()
                }
            })
        }

        private func restoreIfNeeded(_ window: NSWindow) {
            guard !window.styleMask.contains(.fullScreen) else {
                hasPendingExternalRestoration = savedPlacement != nil
                return
            }
            let identifier = ObjectIdentifier(window)
            guard restoredWindowIdentifier != identifier else { return }
            restoredWindowIdentifier = identifier
            guard let savedPlacement else { return }

            guard let plan = MainWindowRestorationPlanner.plan(
                savedPlacement: savedPlacement,
                displays: workspaceDisplays,
                minimumSize: .defaultMainWindowMinimum
            ) else {
                return
            }

            isRestoring = true
            window.setFrame(plan.frame.nsRect, display: false)
            isRestoring = false
        }

        private func restorePendingExternalPlacementIfPossible(in window: NSWindow) {
            guard hasPendingExternalRestoration,
                  !window.inLiveResize,
                  !window.styleMask.contains(.fullScreen) else {
                return
            }
            hasPendingExternalRestoration = false
            restoredWindowIdentifier = nil
            restoreIfNeeded(window)
        }

        private func schedulePersistence() {
            guard let window,
                  MainWindowFramePersistencePolicy.permitsPersistence(
                      isRestoring: isRestoring,
                      isInLiveResize: window.inLiveResize,
                      styleMask: window.styleMask
                  ) else {
                return
            }
            pendingPersistence?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    self?.persistNow()
                }
            }
            pendingPersistence = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: workItem)
        }

        private func persistNow() {
            guard let window,
                  MainWindowFramePersistencePolicy.permitsPersistence(
                      isRestoring: isRestoring,
                      isInLiveResize: window.inLiveResize,
                      styleMask: window.styleMask
                  ),
                  let onPlacementChange else {
                return
            }
            let frame = window.frame
            guard frame.width > 0, frame.height > 0 else { return }
            let placement = MainWindowPlacement(
                frame: WorkspaceRect(
                    x: Double(frame.origin.x),
                    y: Double(frame.origin.y),
                    width: Double(frame.width),
                    height: Double(frame.height)
                ),
                displayIdentifier: window.screen?.workspaceIdentifier
            )
            guard placement != savedPlacement,
                  placement != lastPublishedPlacement else {
                return
            }
            lastPublishedPlacement = placement
            onPlacementChange(placement, placementSourceID)
        }

        private var workspaceDisplays: [WorkspaceDisplayDescriptor] {
            NSScreen.screens.enumerated().map { index, screen in
                WorkspaceDisplayDescriptor(
                    identifier: screen.workspaceIdentifier ?? "display-\(index)",
                    visibleFrame: WorkspaceRect(screen.visibleFrame)
                )
            }
        }

        private static var minimumWindowSize: NSSize {
            NSSize(
                width: WorkspaceSize.defaultMainWindowMinimum.width,
                height: WorkspaceSize.defaultMainWindowMinimum.height
            )
        }
    }
}

struct SidebarWidthWorkspaceBridge: NSViewRepresentable {
    let savedWidth: Double
    let onWidthChange: @MainActor (Double) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WorkspaceHierarchyProbeView {
        let view = WorkspaceHierarchyProbeView()
        view.hierarchyDidChange = { [weak coordinator = context.coordinator] view in
            coordinator?.attach(from: view)
        }
        context.coordinator.update(savedWidth: savedWidth, onWidthChange: onWidthChange)
        return view
    }

    func updateNSView(_ view: WorkspaceHierarchyProbeView, context: Context) {
        context.coordinator.update(savedWidth: savedWidth, onWidthChange: onWidthChange)
        context.coordinator.attach(from: view)
    }

    @MainActor
    final class Coordinator {
        private static let stableAutosaveName = NSSplitView.AutosaveName(
            "TransmissionRemoteMac.MainSidebar"
        )

        private weak var splitView: NSSplitView?
        private var resizeObserver: NSObjectProtocol?
        private var savedWidth = UIWorkspacePreferences.defaultSidebarWidth
        private var onWidthChange: (@MainActor (Double) -> Void)?
        private var restoredSplitViewIdentifier: ObjectIdentifier?
        private var pendingPersistence: DispatchWorkItem?
        private var isApplyingWidth = false

        deinit {
            pendingPersistence?.cancel()
            if let resizeObserver {
                NotificationCenter.default.removeObserver(resizeObserver)
            }
        }

        func update(
            savedWidth: Double,
            onWidthChange: @escaping @MainActor (Double) -> Void
        ) {
            let normalizedWidth = UIWorkspacePreferences.normalizedSidebarWidth(savedWidth)
            let widthChanged = abs(self.savedWidth - normalizedWidth) >= 0.5
            self.savedWidth = normalizedWidth
            self.onWidthChange = onWidthChange
            if widthChanged {
                applySavedWidthIfNeeded()
            }
        }

        func attach(from probeView: NSView) {
            if let splitView, probeView.isDescendant(of: splitView) {
                return
            }
            DispatchQueue.main.async { [weak self, weak probeView] in
                guard let self, let probeView, let candidate = self.enclosingSplitView(for: probeView) else {
                    return
                }
                self.attach(to: candidate)
            }
        }

        private func attach(to splitView: NSSplitView) {
            if self.splitView !== splitView {
                if let resizeObserver {
                    NotificationCenter.default.removeObserver(resizeObserver)
                }
                self.splitView = splitView
                resizeObserver = NotificationCenter.default.addObserver(
                    forName: NSSplitView.didResizeSubviewsNotification,
                    object: splitView,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.schedulePersistence()
                    }
                }
            }

            splitView.autosaveName = Self.stableAutosaveName
            let identifier = ObjectIdentifier(splitView)
            if restoredSplitViewIdentifier != identifier {
                restoredSplitViewIdentifier = identifier
                applySavedWidthIfNeeded(force: true)
            }
        }

        private func enclosingSplitView(for probeView: NSView) -> NSSplitView? {
            var candidate = probeView.superview
            while let current = candidate {
                if
                    let splitView = current as? NSSplitView,
                    splitView.arrangedSubviews.count >= 2,
                    probeView.isDescendant(of: splitView.arrangedSubviews[0])
                {
                    return splitView
                }
                candidate = current.superview
            }
            return nil
        }

        private func applySavedWidthIfNeeded(force: Bool = false) {
            guard
                let splitView,
                splitView.arrangedSubviews.count >= 2,
                splitView.bounds.width > 0,
                !splitView.isSubviewCollapsed(splitView.arrangedSubviews[0])
            else {
                return
            }
            let currentWidth = Double(splitView.arrangedSubviews[0].frame.width)
            guard force || abs(currentWidth - savedWidth) >= 0.5 else { return }

            isApplyingWidth = true
            splitView.setPosition(CGFloat(savedWidth), ofDividerAt: 0)
            splitView.adjustSubviews()
            isApplyingWidth = false
        }

        private func schedulePersistence() {
            guard !isApplyingWidth else { return }
            pendingPersistence?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    self?.persistWidth()
                }
            }
            pendingPersistence = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: workItem)
        }

        private func persistWidth() {
            guard
                !isApplyingWidth,
                let splitView,
                let firstSubview = splitView.arrangedSubviews.first,
                !splitView.isSubviewCollapsed(firstSubview),
                firstSubview.frame.width > 0,
                let onWidthChange
            else {
                return
            }
            onWidthChange(Double(firstSubview.frame.width))
        }
    }
}

@MainActor
final class WorkspaceHierarchyProbeView: NSView {
    var hierarchyDidChange: (@MainActor (WorkspaceHierarchyProbeView) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        hierarchyDidChange?(self)
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        hierarchyDidChange?(self)
    }
}

private extension WorkspaceRect {
    init(_ rect: NSRect) {
        self.init(
            x: Double(rect.origin.x),
            y: Double(rect.origin.y),
            width: Double(rect.width),
            height: Double(rect.height)
        )
    }

    var nsRect: NSRect {
        NSRect(x: x, y: y, width: width, height: height)
    }
}

private extension NSScreen {
    var workspaceIdentifier: String? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue
    }
}
