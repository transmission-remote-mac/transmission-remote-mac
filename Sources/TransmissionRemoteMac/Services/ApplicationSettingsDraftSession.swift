// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Combine
import Foundation

/// Keeps an unsaved application-settings draft alive while the Settings scene
/// is closed. This is process-local editing state, not a second preference store.
@MainActor
final class ApplicationSettingsDraftSession: ObservableObject {
    @Published private(set) var retainedDraft: ApplicationSettingsDraft?
    @Published private(set) var saveErrorMessage: String?
    private var lastAutomaticSaveAttemptDraft: ApplicationSettingsDraft?

    func beginPresentation() {
        lastAutomaticSaveAttemptDraft = nil
    }

    func claimAutomaticSaveAttempt(for draft: ApplicationSettingsDraft) -> Bool {
        guard lastAutomaticSaveAttemptDraft != draft else { return false }
        lastAutomaticSaveAttemptDraft = draft
        return true
    }

    func retain(_ draft: ApplicationSettingsDraft, errorMessage: String) {
        retainedDraft = draft
        saveErrorMessage = errorMessage
    }

    func handleSaveResult(
        _ result: Result<
            PersistedApplicationSettingsSnapshot?,
            ApplicationSettingsSaveError
        >,
        retaining draft: ApplicationSettingsDraft
    ) {
        switch result {
        case .success:
            clear()
        case .failure(let error):
            retain(draft, errorMessage: error.localizedDescription)
        }
    }

    func clear() {
        retainedDraft = nil
        saveErrorMessage = nil
    }
}
