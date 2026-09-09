// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation

/// Opaque SwiftUI table state. The encoded value remains authoritative so
/// dragged order and resized widths survive portability alongside visibility.
struct PortableTableColumnCustomization: Codable, Equatable, Sendable {
    var encodedValue: Data
}

struct PortableTableColumnCustomizations: Codable, Equatable, Sendable {
    var main: PortableTableColumnCustomization
    var files: PortableTableColumnCustomization
    var peers: PortableTableColumnCustomization
    var trackers: PortableTableColumnCustomization
}
