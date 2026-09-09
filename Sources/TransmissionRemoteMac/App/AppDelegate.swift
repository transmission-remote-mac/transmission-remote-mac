// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import AppKit
import Carbon

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum PendingOpenEvent {
        case remoteTorrentSource(String)
        case localTorrentDocument(URL)

        var pendingAddTorrentSource: AppStore.PendingAddTorrent.Source {
            switch self {
            case .remoteTorrentSource(let source):
                .remote(source)
            case .localTorrentDocument(let url):
                .localFile(url)
            }
        }
    }

    private weak var store: AppStore?
    private let pollingVisibilityResolver = ApplicationPollingVisibilityResolver()
    private var pendingOpenEvents: [PendingOpenEvent] = []
    private var visibilityObservers: [NSObjectProtocol] = []
#if DEBUG
    private var performanceVisibilityProofRecorder: PerformanceHarnessPollingVisibilityProofRecorder?
    private var lastProvenPollingVisibility: PollingVisibilityState?
    private var performanceApplicationStateProofRecorder:
        PerformanceHarnessApplicationStateProofRecorder?
    private var performanceApplicationActivationCount = 0
    private var lastProvenApplicationState: PerformanceHarnessApplicationState?
#endif

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
#if DEBUG
        configurePerformanceApplicationStateProof()
#endif
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        registerURLHandler()
    }

#if DEBUG
    func applicationDidBecomeActive(_ notification: Notification) {
        guard performanceApplicationStateProofRecorder != nil else { return }
        guard performanceApplicationActivationCount < Int.max else {
            preconditionFailure("Performance application activation count overflow")
        }
        performanceApplicationActivationCount += 1
        recordPerformanceApplicationState()
    }
#endif

    func application(_ application: NSApplication, open urls: [URL]) {
        open(urls)
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        open([URL(fileURLWithPath: filename)])
        return true
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        open(filenames.map { URL(fileURLWithPath: $0) })
        sender.reply(toOpenOrPrint: .success)
    }

    func attach(store: AppStore) {
        self.store = store
        installVisibilityBridgeIfNeeded()
        updatePollingVisibility()
        drainPendingOpenEvents()
        store.inspectClipboardForTorrent()
    }

    @objc private func handleGetURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let openEvent = pendingOpenEvent(forURLString: urlString) else { return }
        handle([openEvent])
    }

    private func registerURLHandler() {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    private func open(_ urls: [URL]) {
        handle(urls.compactMap(pendingOpenEvent))
    }

    private func pendingOpenEvent(forURLString urlString: String) -> PendingOpenEvent? {
        let source = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return nil }
        if source.lowercased().hasPrefix("magnet:?") {
            return .remoteTorrentSource(source)
        }
        guard let url = URL(string: source) else { return nil }
        return pendingOpenEvent(for: url)
    }

    private func pendingOpenEvent(for url: URL) -> PendingOpenEvent? {
        if url.scheme?.lowercased() == "magnet" {
            return .remoteTorrentSource(url.absoluteString)
        }
        guard url.isFileURL, url.pathExtension.lowercased() == "torrent" else { return nil }
        return .localTorrentDocument(url.standardizedFileURL)
    }

    private func handle(_ openEvents: [PendingOpenEvent]) {
        guard !openEvents.isEmpty else { return }
        guard store != nil else {
            pendingOpenEvents.append(contentsOf: openEvents)
            return
        }
        apply(openEvents)
    }

    private func drainPendingOpenEvents() {
        let events = pendingOpenEvents
        pendingOpenEvents = []
        apply(events)
    }

    private func apply(_ openEvents: [PendingOpenEvent]) {
        guard !openEvents.isEmpty else { return }
        store?.requestAddTorrents(openEvents.map { $0.pendingAddTorrentSource })
        NSApp.activate(ignoringOtherApps: true)
    }

    private func installVisibilityBridgeIfNeeded() {
        guard visibilityObservers.isEmpty else { return }
        let center = NotificationCenter.default
        let notificationNames: [Notification.Name] = [
            NSApplication.didBecomeActiveNotification,
            NSApplication.didResignActiveNotification,
            NSApplication.didHideNotification,
            NSApplication.didUnhideNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
            NSWindow.didBecomeMainNotification,
            NSWindow.didResignMainNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.willCloseNotification
        ]

        visibilityObservers = notificationNames.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated {
                    self?.handleVisibilityEvent(notification)
                }
            }
        }
    }

    private func handleVisibilityEvent(_ notification: Notification) {
        if notification.name == NSApplication.didBecomeActiveNotification {
            store?.inspectClipboardForTorrent()
        }
        updatePollingVisibility()
    }

    private func isMainApplicationWindow(_ window: NSWindow) -> Bool {
        window.title == "Transmission Remote Mac"
    }

    private func updatePollingVisibility() {
        guard let store else { return }
        let windows = NSApp.windows.map { window in
            ApplicationWindowVisibilitySnapshot(
                isMainApplicationWindow: isMainApplicationWindow(window),
                isVisible: window.isVisible,
                isMiniaturized: window.isMiniaturized,
                isOcclusionVisible: window.occlusionState.contains(.visible)
            )
        }
        let visibility = pollingVisibilityResolver.visibility(
            isApplicationActive: NSApp.isActive,
            windows: windows
        )
#if DEBUG
        recordPerformanceApplicationState()
#endif
        store.updatePollingVisibility(visibility)
#if DEBUG
        recordPerformancePollingVisibility(visibility)
#endif
    }

#if DEBUG
    private func configurePerformanceApplicationStateProof() {
        let environment = ProcessInfo.processInfo.environment
        if environment[PerformanceHarnessApplicationStateProofRecorder.environmentKey] != nil {
            guard let proofRecorder =
                PerformanceHarnessApplicationStateProofRecorder.requestedFromEnvironment(
                    environment: environment
                )
            else {
                preconditionFailure("Rejected invalid performance application-state proof context")
            }
            performanceApplicationStateProofRecorder = proofRecorder
        }
        recordPerformanceApplicationState()
    }

    private func recordPerformanceApplicationState() {
        guard let performanceApplicationStateProofRecorder else { return }
        let state = PerformanceHarnessApplicationState(
            activationCount: performanceApplicationActivationCount,
            isMainWindowVisibleAndNonMiniaturized: !NSApp.isHidden
                && NSApp.windows.contains { window in
                    isMainApplicationWindow(window)
                        && window.isVisible
                        && !window.isMiniaturized
                }
        )
        guard state != lastProvenApplicationState else { return }
        guard performanceApplicationStateProofRecorder.record(state) else {
            preconditionFailure("Rejected invalid performance application-state proof context")
        }
        lastProvenApplicationState = state
    }

    private func recordPerformancePollingVisibility(_ visibility: PollingVisibilityState) {
        let environment = ProcessInfo.processInfo.environment
        guard environment[PerformanceHarnessPollingVisibilityProofRecorder.environmentKey] != nil else {
            return
        }
        guard lastProvenPollingVisibility != visibility else { return }
        if performanceVisibilityProofRecorder == nil {
            performanceVisibilityProofRecorder =
                PerformanceHarnessPollingVisibilityProofRecorder.requestedFromEnvironment(
                    environment: environment
                )
        }
        guard
            let performanceVisibilityProofRecorder,
            performanceVisibilityProofRecorder.record(visibility)
        else {
            preconditionFailure("Rejected invalid performance polling-visibility proof context")
        }
        lastProvenPollingVisibility = visibility
    }
#endif
}

#if DEBUG
struct PerformanceHarnessPollingVisibilityProofRecorder {
    static let environmentKey = "TRANSMISSION_REMOTE_MAC_PERFORMANCE_VISIBILITY_PROOF"
    static let proofName = ".transmission-remote-mac-performance-polling-visibility"
    static let compiledMarker = "TRM_PERFORMANCE_POLLING_VISIBILITY_V1"

    private let proofURL: URL
    private let token: String
    private let environment: [String: String]
    private let resolvedHomePath: String
    private let fileManager: FileManager

    static func requestedFromEnvironment(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        resolvedHomePath: String = NSHomeDirectory(),
        fileManager: FileManager = .default
    ) -> PerformanceHarnessPollingVisibilityProofRecorder? {
        guard
            let context = PerformanceHarnessContext.validatedIfRequested(
                featureEnvironmentKey: environmentKey,
                environment: environment,
                resolvedHomePath: resolvedHomePath,
                fileManager: fileManager
            ),
            context.token.utf8.count <= 128
        else {
            return nil
        }
        return PerformanceHarnessPollingVisibilityProofRecorder(
            proofURL: context.temporaryDirectoryURL.appendingPathComponent(proofName),
            token: context.token,
            environment: environment,
            resolvedHomePath: resolvedHomePath,
            fileManager: fileManager
        )
    }

    @discardableResult
    func record(_ visibility: PollingVisibilityState) -> Bool {
        guard
            let context = PerformanceHarnessContext.validatedIfRequested(
                featureEnvironmentKey: Self.environmentKey,
                environment: environment,
                resolvedHomePath: resolvedHomePath,
                fileManager: fileManager
            ),
            context.token == token,
            context.temporaryDirectoryURL.appendingPathComponent(Self.proofName) == proofURL
        else {
            return false
        }

        let state = switch visibility {
        case .foreground: "foreground"
        case .background: "background"
        }
        return PerformanceHarnessAtomicProofWriter.write(
            Array("\(Self.compiledMarker)\n\(token)\n\(state)\n".utf8),
            to: proofURL,
            maximumByteCount: 256
        )
    }
}
#endif
