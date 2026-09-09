// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import AppKit
import SwiftUI

struct PersistedDetailSplitView<Primary: View, Detail: View>: View {
    private static var dividerHeight: CGFloat { 9 }

    let isDetailVisible: Bool
    let minimumPrimaryHeight: CGFloat
    let minimumDetailHeight: CGFloat
    let primary: Primary
    let detail: Detail

    @Binding private var persistedDetailHeight: Double
    @State private var dragStartDetailHeight: CGFloat?
    @State private var draggedDetailHeight: CGFloat?
    @State private var isResizeCursorActive = false

    init(
        isDetailVisible: Bool,
        detailHeight: Binding<Double>,
        minimumPrimaryHeight: CGFloat,
        minimumDetailHeight: CGFloat,
        @ViewBuilder primary: () -> Primary,
        @ViewBuilder detail: () -> Detail
    ) {
        self.isDetailVisible = isDetailVisible
        self.minimumPrimaryHeight = max(0, minimumPrimaryHeight)
        self.minimumDetailHeight = max(0, minimumDetailHeight)
        self.primary = primary()
        self.detail = detail()
        _persistedDetailHeight = detailHeight
    }

    var body: some View {
        GeometryReader { geometry in
            let layout = splitLayout(for: geometry.size.height)

            VStack(spacing: 0) {
                primary
                    .frame(height: layout.primaryHeight)

                if isDetailVisible {
                    resizeDivider(availablePaneHeight: layout.availablePaneHeight)
                        .frame(height: layout.dividerHeight)

                    detail
                        .frame(height: layout.detailHeight)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .onChange(of: isDetailVisible) { _, isVisible in
            guard !isVisible else { return }
            finishDragging(persist: false)
            updateResizeCursor(isHovering: false)
        }
    }

    private func resizeDivider(availablePaneHeight: CGFloat) -> some View {
        ZStack {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(height: 1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onHover { isHovering in
            updateResizeCursor(isHovering: isHovering)
        }
        .onDisappear {
            updateResizeCursor(isHovering: false)
        }
        .gesture(resizeGesture(availablePaneHeight: availablePaneHeight))
        .accessibilityLabel("Info pane divider")
        .accessibilityValue(
            Text("\(primaryPercentage(for: availablePaneHeight)) percent from top")
        )
        .accessibilityAdjustableAction { direction in
            adjustDivider(direction, availablePaneHeight: availablePaneHeight)
        }
    }

    private func resizeGesture(availablePaneHeight: CGFloat) -> some Gesture {
        // The divider moves during a drag; its local coordinates would subtract
        // that movement from the pointer translation and make resizing lag behind.
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                guard availablePaneHeight > 0 else { return }

                if dragStartDetailHeight == nil {
                    dragStartDetailHeight = resolvedDetailHeight(
                        for: availablePaneHeight,
                        preferredHeight: displayedDetailHeight
                    )
                }

                let startHeight = dragStartDetailHeight ?? displayedDetailHeight
                draggedDetailHeight = resolvedDetailHeight(
                    for: availablePaneHeight,
                    preferredHeight: startHeight - value.translation.height
                )
            }
            .onEnded { _ in
                finishDragging(persist: true)
            }
    }

    private func splitLayout(for totalHeight: CGFloat) -> SplitLayout {
        let safeTotalHeight = totalHeight.isFinite ? max(0, totalHeight) : 0
        guard isDetailVisible else {
            return SplitLayout(
                primaryHeight: safeTotalHeight,
                detailHeight: 0,
                dividerHeight: 0,
                availablePaneHeight: safeTotalHeight
            )
        }

        let dividerHeight = min(Self.dividerHeight, safeTotalHeight)
        let availablePaneHeight = max(0, safeTotalHeight - dividerHeight)
        let detailHeight = resolvedDetailHeight(
            for: availablePaneHeight,
            preferredHeight: displayedDetailHeight
        )

        return SplitLayout(
            primaryHeight: max(0, availablePaneHeight - detailHeight),
            detailHeight: detailHeight,
            dividerHeight: dividerHeight,
            availablePaneHeight: availablePaneHeight
        )
    }

    private func resolvedDetailHeight(
        for availableHeight: CGFloat,
        preferredHeight: CGFloat
    ) -> CGFloat {
        guard availableHeight > 0 else { return 0 }

        let combinedMinimumHeight = minimumPrimaryHeight + minimumDetailHeight
        let minimumScale = combinedMinimumHeight > 0
            ? min(1, availableHeight / combinedMinimumHeight)
            : 1
        let lowerBound = minimumDetailHeight * minimumScale
        let upperBound = max(lowerBound, availableHeight - minimumPrimaryHeight * minimumScale)
        let proposedHeight = sanitized(preferredHeight)
        return min(max(proposedHeight, lowerBound), upperBound)
    }

    private var displayedDetailHeight: CGFloat {
        draggedDetailHeight ?? CGFloat(persistedDetailHeight)
    }

    private func sanitized(_ height: CGFloat) -> CGFloat {
        guard height.isFinite else { return CGFloat(InfoPaneWorkspacePreferences.defaultHeight) }
        return max(0, height)
    }

    private func finishDragging(persist: Bool) {
        if persist, let draggedDetailHeight {
            persistedDetailHeight = Double(sanitized(draggedDetailHeight))
        }
        dragStartDetailHeight = nil
        draggedDetailHeight = nil
    }

    private func adjustDivider(
        _ direction: AccessibilityAdjustmentDirection,
        availablePaneHeight: CGFloat
    ) {
        guard availablePaneHeight > 0 else { return }
        let adjustment: CGFloat
        switch direction {
        case .increment:
            adjustment = -20
        case .decrement:
            adjustment = 20
        @unknown default:
            return
        }

        let currentHeight = resolvedDetailHeight(
            for: availablePaneHeight,
            preferredHeight: displayedDetailHeight
        )
        let resolvedHeight = resolvedDetailHeight(
            for: availablePaneHeight,
            preferredHeight: currentHeight + adjustment
        )
        persistedDetailHeight = Double(resolvedHeight)
        dragStartDetailHeight = nil
        draggedDetailHeight = nil
    }

    private func primaryPercentage(for availablePaneHeight: CGFloat) -> Int {
        guard availablePaneHeight > 0 else { return 0 }
        let detailHeight = resolvedDetailHeight(
            for: availablePaneHeight,
            preferredHeight: displayedDetailHeight
        )
        return Int((((availablePaneHeight - detailHeight) / availablePaneHeight) * 100).rounded())
    }

    private func updateResizeCursor(isHovering: Bool) {
        guard isHovering != isResizeCursorActive else { return }
        if isHovering {
            NSCursor.resizeUpDown.push()
        } else {
            NSCursor.pop()
        }
        isResizeCursorActive = isHovering
    }
}

private struct SplitLayout {
    let primaryHeight: CGFloat
    let detailHeight: CGFloat
    let dividerHeight: CGFloat
    let availablePaneHeight: CGFloat
}
