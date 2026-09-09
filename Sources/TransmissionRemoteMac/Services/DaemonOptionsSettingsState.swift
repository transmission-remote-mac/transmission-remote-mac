// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

struct DaemonOptionsSettingsState: Equatable, Sendable {
    private(set) var draft: DaemonOptionsDraft?
    private(set) var sourceOptions: DaemonOptions?
    private(set) var latestDaemonOptions: DaemonOptions?
    private(set) var isSubmitting = false
    private(set) var lastApplyResult: DaemonOptionsApplyResult?

    mutating func reset(with sessionInfo: SessionInfo?) {
        isSubmitting = false
        lastApplyResult = nil
        latestDaemonOptions = sessionInfo?.daemonOptions
        replaceDraft(with: sessionInfo?.daemonOptions)
    }

    mutating func synchronize(with sessionInfo: SessionInfo?) {
        guard let sessionInfo else {
            reset(with: nil)
            return
        }
        latestDaemonOptions = sessionInfo.daemonOptions
        guard let draft, let sourceOptions else {
            replaceDraft(with: sessionInfo.daemonOptions)
            return
        }

        let capabilities = sessionInfo.capabilities
        let hasLocalChanges = draft.hasChanges(
            comparedTo: sourceOptions,
            capabilities: capabilities
        )
        let differsFromDaemon = draft.hasChanges(
            comparedTo: sessionInfo.daemonOptions,
            capabilities: capabilities
        )
        guard !hasLocalChanges || !differsFromDaemon else { return }
        replaceDraft(with: sessionInfo.daemonOptions)
    }

    mutating func updateDraft(_ draft: DaemonOptionsDraft) {
        self.draft = draft
        lastApplyResult = nil
    }

    mutating func beginSubmission() {
        isSubmitting = true
        lastApplyResult = nil
    }

    mutating func completeSubmission(with result: DaemonOptionsApplyResult) {
        isSubmitting = false
        if result == .succeeded {
            replaceDraft(with: latestDaemonOptions)
        }
        lastApplyResult = result
    }

    func hasChanges(capabilities: SessionCapabilities) -> Bool {
        guard let draft, let sourceOptions else { return false }
        return draft.hasChanges(comparedTo: sourceOptions, capabilities: capabilities)
    }

    func validationIssues(capabilities: SessionCapabilities) -> [String] {
        draft?.validationIssues(capabilities: capabilities) ?? []
    }

    func update(capabilities: SessionCapabilities) -> DaemonOptionsUpdate? {
        guard let draft, let sourceOptions else { return nil }
        return draft.update(comparedTo: sourceOptions, capabilities: capabilities)
    }

    private mutating func replaceDraft(with options: DaemonOptions?) {
        guard let options else {
            draft = nil
            sourceOptions = nil
            return
        }
        draft = DaemonOptionsDraft(options: options)
        sourceOptions = options
    }
}
