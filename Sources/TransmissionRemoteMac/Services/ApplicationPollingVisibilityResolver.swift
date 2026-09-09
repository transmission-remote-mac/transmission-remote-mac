// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

struct ApplicationWindowVisibilitySnapshot: Equatable, Sendable {
    let isMainApplicationWindow: Bool
    let isVisible: Bool
    let isMiniaturized: Bool
    let isOcclusionVisible: Bool
}

struct ApplicationPollingVisibilityResolver {
    func visibility(
        isApplicationActive: Bool,
        windows: [ApplicationWindowVisibilitySnapshot]
    ) -> PollingVisibilityState {
        guard isApplicationActive else { return .background }
        let hasForegroundMainWindow = windows.contains { window in
            window.isMainApplicationWindow
                && window.isVisible
                && !window.isMiniaturized
                && window.isOcclusionVisible
        }
        return hasForegroundMainWindow ? .foreground : .background
    }
}
