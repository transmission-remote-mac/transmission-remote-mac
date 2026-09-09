// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation

struct DaemonOptionsSettingsOwner: Equatable, Sendable {
    var profileID: ConnectionProfile.ID
    var connectionGeneration: UUID
}

struct DaemonOptionsSettingsSubmission: Equatable, Sendable {
    var id: UUID
    var owner: DaemonOptionsSettingsOwner
}
