// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Combine
import Foundation

@MainActor
final class DaemonOptionsSettingsController: ObservableObject {
    @Published private(set) var state = DaemonOptionsSettingsState()
    private(set) var currentOwner: DaemonOptionsSettingsOwner?

    private var activeSubmission: DaemonOptionsSettingsSubmission?

    var draft: DaemonOptionsDraft? { state.draft }
    var isSubmitting: Bool { state.isSubmitting }
    var lastApplyResult: DaemonOptionsApplyResult? { state.lastApplyResult }

    func synchronize(
        owner: DaemonOptionsSettingsOwner?,
        sessionInfo: SessionInfo?
    ) {
        guard owner == currentOwner else {
            currentOwner = owner
            activeSubmission = nil
            mutateState { $0.reset(with: sessionInfo) }
            return
        }
        mutateState { $0.synchronize(with: sessionInfo) }
    }

    func updateDraft(_ draft: DaemonOptionsDraft) {
        mutateState { $0.updateDraft(draft) }
    }

    func reset(with sessionInfo: SessionInfo?) {
        activeSubmission = nil
        mutateState { $0.reset(with: sessionInfo) }
    }

    func beginSubmission() -> DaemonOptionsSettingsSubmission? {
        guard let currentOwner, activeSubmission == nil else { return nil }
        let submission = DaemonOptionsSettingsSubmission(
            id: UUID(),
            owner: currentOwner
        )
        activeSubmission = submission
        mutateState { $0.beginSubmission() }
        return submission
    }

    func completeSubmission(
        _ submission: DaemonOptionsSettingsSubmission,
        with result: DaemonOptionsApplyResult
    ) {
        guard
            activeSubmission == submission,
            currentOwner == submission.owner
        else {
            return
        }
        activeSubmission = nil
        mutateState { $0.completeSubmission(with: result) }
    }

    func hasChanges(capabilities: SessionCapabilities) -> Bool {
        state.hasChanges(capabilities: capabilities)
    }

    func validationIssues(capabilities: SessionCapabilities) -> [String] {
        state.validationIssues(capabilities: capabilities)
    }

    func update(capabilities: SessionCapabilities) -> DaemonOptionsUpdate? {
        state.update(capabilities: capabilities)
    }

    private func mutateState(_ mutation: (inout DaemonOptionsSettingsState) -> Void) {
        var nextState = state
        mutation(&nextState)
        guard nextState != state else { return }
        state = nextState
    }
}
