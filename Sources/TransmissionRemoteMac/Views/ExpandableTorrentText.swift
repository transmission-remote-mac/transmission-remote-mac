// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import SwiftUI

struct ExpandableTorrentText: View, Equatable {
    var value: String
    var accessibilityLabel: String
    var lineLimit: Int
    var accessibilityValue: String? = nil

    var body: some View {
        ExpandableTorrentTextContent(text: self)
            .id(value)
    }
}

private struct ExpandableTorrentTextContent: View {
    var text: ExpandableTorrentText

    @State private var isExpanded = false
    @State private var overflows: Bool?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            selectableValue
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    if !isExpanded {
                        GeometryReader { geometry in
                            // The hidden counterpart measures the other line limit at the same width.
                            valueText(lineLimit: showsFullValue ? text.lineLimit : nil)
                                .textSelection(.disabled)
                                .frame(width: geometry.size.width, alignment: .leading)
                                .background {
                                    GeometryReader { counterpart in
                                        Color.clear.preference(
                                            key: TorrentTextMeasurementKey.self,
                                            value: TorrentTextMeasurement(
                                                width: geometry.size.width,
                                                fullHeight: showsFullValue ? geometry.size.height : counterpart.size.height,
                                                cappedHeight: showsFullValue ? counterpart.size.height : geometry.size.height
                                            )
                                        )
                                    }
                                }
                                .hidden()
                                .accessibilityHidden(true)
                                .allowsHitTesting(false)
                        }
                    }
                }
                .accessibilityLabel(text.accessibilityLabel)
                .accessibilityValue(text.accessibilityValue ?? text.value)

            if overflows == true {
                Button(isExpanded ? "Show Less" : "Show More") {
                    isExpanded.toggle()
                }
                .buttonStyle(.link)
                .font(.caption)
                .accessibilityLabel("\(isExpanded ? "Collapse" : "Show full") \(text.accessibilityLabel)")
                .accessibilityIdentifier(
                    "torrent-overview-\(isExpanded ? "collapse" : "expand")-\(text.accessibilityLabel)"
                )
            }
        }
        .onPreferenceChange(TorrentTextMeasurementKey.self) { measurement in
            guard let measurement, measurement.width > 0 else { return }
            let valueOverflows = measurement.fullHeight > measurement.cappedHeight + 0.5
            if overflows != valueOverflows {
                overflows = valueOverflows
            }
            if !valueOverflows {
                isExpanded = false
            }
        }
    }

    private var showsFullValue: Bool {
        isExpanded || overflows == false
    }

    @ViewBuilder
    private var selectableValue: some View {
        if showsFullValue {
            valueText(lineLimit: nil)
                .textSelection(.enabled)
        } else {
            // Native selection can expand a truncated Text without remeasuring its SwiftUI parent.
            valueText(lineLimit: text.lineLimit)
                .textSelection(.disabled)
                .onTapGesture {
                    if overflows == true {
                        isExpanded = true
                    }
                }
        }
    }

    private func valueText(lineLimit: Int?) -> some View {
        Text(text.value)
            .lineLimit(lineLimit)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct TorrentTextMeasurement: Equatable {
    var width: CGFloat
    var fullHeight: CGFloat
    var cappedHeight: CGFloat
}

private struct TorrentTextMeasurementKey: PreferenceKey {
    static var defaultValue: TorrentTextMeasurement? { nil }

    static func reduce(value: inout TorrentTextMeasurement?, nextValue: () -> TorrentTextMeasurement?) {
        value = nextValue() ?? value
    }
}
