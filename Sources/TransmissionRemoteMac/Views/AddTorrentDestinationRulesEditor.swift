// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import SwiftUI

struct AddTorrentDestinationRulesEditor: View {
    @Binding private var preferences: ProfileTransferPreferences
    @State private var destinationRulesDraft: AddTorrentDestinationRulesDraft
    @State private var activeRuleDraft = AddTorrentDestinationRuleDraft()
    @State private var isEditingRule = false
    @State private var validationMessage: String?

    init(preferences: Binding<ProfileTransferPreferences>) {
        _preferences = preferences
        _destinationRulesDraft = State(
            initialValue: AddTorrentDestinationRulesDraft(
                snapshot: preferences.wrappedValue.addDestinationRules
            )
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Add Destination Rules")
                    .font(.headline)

                Spacer()

                Button("Add Rule", action: beginAddingRule)
                    .disabled(
                        isEditingRule
                            || hasDefaultTextChanges
                            || rules.count >= AddTorrentDestinationRulesSnapshot.maximumRuleCount
                    )
            }

            HStack {
                TextField(
                    "Default destination recommendation",
                    text: $destinationRulesDraft.defaultDestination
                )
                    .textFieldStyle(.roundedBorder)
                    .disabled(isEditingRule)

                Button("Cancel", action: cancelDefaultEdit)
                    .disabled(!hasDefaultTextChanges || isEditingRule)

                Button("Save Default", action: saveDefaultDestination)
                    .disabled(!hasDefaultTextChanges || isEditingRule)
            }

            if rules.isEmpty {
                Text("No destination rules. Add Torrent will keep its normal destination until you explicitly apply a recommendation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(rules.enumerated()), id: \.element.id) { index, rule in
                        destinationRuleRow(rule, index: index)

                        if index < rules.count - 1 {
                            Divider()
                        }
                    }
                }
                .padding(.horizontal, 8)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
            }

            if isEditingRule {
                ruleEditor
            }

            if let validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Button("Reset Destination Rules", role: .destructive, action: resetRules)
                    .disabled(
                        preferences.addDestinationRules == .empty
                            && !destinationRulesDraft.hasChanges
                            && !isEditingRule
                    )
            }

            Text("Rules recommend a destination from torrent contents. More matched bytes wins; earlier rules win ties. Add Torrent still requires you to apply the recommendation, so no rule silently routes a torrent.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("Save Rule, Save Default, ordering, enablement, removal and reset stage changes for this server. Only the outer Connection Settings Apply persists them; Revert discards them.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onChange(of: preferences.addDestinationRules) { _, snapshot in
            synchronize(with: snapshot)
        }
    }

    private func destinationRuleRow(
        _ rule: AddTorrentDestinationRule,
        index: Int
    ) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Toggle(
                "Enable \(rule.label)",
                isOn: enabledBinding(for: rule.id)
            )
            .labelsHidden()
            .help(rule.isEnabled ? "Disable this rule" : "Enable this rule")
            .disabled(isEditingRule || hasDefaultTextChanges)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text("\(index + 1). \(rule.label)")
                        .fontWeight(.medium)

                    Text(rule.isEnabled ? "Enabled" : "Disabled")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(rule.destination)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 4)

            Button(action: { moveRuleUp(rule.id) }) {
                Label("Move Rule Up", systemImage: "arrow.up")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Move rule up. Earlier rules win ties.")
            .disabled(index == 0 || isEditingRule || hasDefaultTextChanges)

            Button(action: { moveRuleDown(rule.id) }) {
                Label("Move Rule Down", systemImage: "arrow.down")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Move rule down. Earlier rules win ties.")
            .disabled(index == rules.count - 1 || isEditingRule || hasDefaultTextChanges)

            Button("Edit", action: { beginEditingRule(rule.id) })
                .disabled(isEditingRule || hasDefaultTextChanges)

            Button("Remove", role: .destructive, action: { removeRule(rule.id) })
                .disabled(isEditingRule || hasDefaultTextChanges)
        }
        .padding(.vertical, 6)
    }

    private var ruleEditor: some View {
        GroupBox(activeRuleEditorTitle) {
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 7) {
                GridRow {
                    Text("Rule name")
                    TextField("Video", text: $activeRuleDraft.label)
                }

                GridRow {
                    Text("Destination")
                    TextField("/downloads/video", text: $activeRuleDraft.destination)
                        .font(.body.monospaced())
                }

                GridRow {
                    Text("Extensions")
                    TextField("mkv, mp4", text: $activeRuleDraft.extensionsText)
                }

                GridRow {
                    Text("Ordered name tokens")
                    TextField("season, episode", text: $activeRuleDraft.nameTokensText)
                }
            }
            .textFieldStyle(.roundedBorder)

            Toggle("Rule enabled", isOn: $activeRuleDraft.isEnabled)

            Text("Separate entries with commas. Extensions match file suffixes. Name tokens must appear in the entered order. Supply at least one extension or name token.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()

                Button("Cancel", action: cancelRuleEdit)
                Button("Save Rule", action: saveActiveRule)
            }
        }
    }

    private var activeRuleEditorTitle: String {
        rules.contains { $0.id == activeRuleDraft.id }
            ? "Edit Destination Rule"
            : "Add Destination Rule"
    }

    private var rules: [AddTorrentDestinationRule] {
        destinationRulesDraft.rules
    }

    private var hasDefaultTextChanges: Bool {
        destinationRulesDraft.defaultDestination
            != (preferences.addDestinationRules.defaultDestination ?? "")
    }

    private func enabledBinding(for ruleID: UUID) -> Binding<Bool> {
        Binding(
            get: {
                rules.first { $0.id == ruleID }?.isEnabled ?? false
            },
            set: { isEnabled in
                setRuleEnabled(ruleID, isEnabled: isEnabled)
            }
        )
    }

    private func beginAddingRule() {
        activeRuleDraft = AddTorrentDestinationRuleDraft()
        validationMessage = nil
        isEditingRule = true
    }

    private func beginEditingRule(_ ruleID: UUID) {
        guard let rule = rules.first(where: { $0.id == ruleID }) else { return }
        activeRuleDraft = AddTorrentDestinationRuleDraft(rule: rule)
        validationMessage = nil
        isEditingRule = true
    }

    private func cancelRuleEdit() {
        activeRuleDraft = AddTorrentDestinationRuleDraft()
        validationMessage = nil
        isEditingRule = false
    }

    private func saveActiveRule() {
        do {
            let validatedRule = try activeRuleDraft.validatedRule()
            var updatedRules = rules

            if let index = updatedRules.firstIndex(where: { $0.id == validatedRule.id }) {
                updatedRules[index] = validatedRule
            } else {
                guard updatedRules.count < AddTorrentDestinationRulesSnapshot.maximumRuleCount else {
                    throw AddTorrentDestinationRuleValidationError.tooManyRules
                }
                updatedRules.append(validatedRule)
            }

            try stageRules(updatedRules)
            cancelRuleEdit()
        } catch {
            validationMessage = error.localizedDescription
        }
    }

    private func setRuleEnabled(_ ruleID: UUID, isEnabled: Bool) {
        guard let index = rules.firstIndex(where: { $0.id == ruleID }) else { return }
        do {
            var updatedRules = rules
            var updatedRule = AddTorrentDestinationRuleDraft(rule: updatedRules[index])
            updatedRule.isEnabled = isEnabled
            updatedRules[index] = try updatedRule.validatedRule()
            try stageRules(updatedRules)
        } catch {
            validationMessage = error.localizedDescription
        }
    }

    private func moveRuleUp(_ ruleID: UUID) {
        guard let index = rules.firstIndex(where: { $0.id == ruleID }), index > 0 else {
            return
        }
        do {
            var updatedRules = rules
            updatedRules.swapAt(index, index - 1)
            try stageRules(updatedRules)
        } catch {
            validationMessage = error.localizedDescription
        }
    }

    private func moveRuleDown(_ ruleID: UUID) {
        guard let index = rules.firstIndex(where: { $0.id == ruleID }),
              index < rules.count - 1 else {
            return
        }
        do {
            var updatedRules = rules
            updatedRules.swapAt(index, index + 1)
            try stageRules(updatedRules)
        } catch {
            validationMessage = error.localizedDescription
        }
    }

    private func removeRule(_ ruleID: UUID) {
        do {
            try stageRules(rules.filter { $0.id != ruleID })
        } catch {
            validationMessage = error.localizedDescription
        }
    }

    private func resetRules() {
        destinationRulesDraft.reset()
        do {
            try applyDestinationRulesDraft()
            cancelRuleEdit()
        } catch {
            validationMessage = error.localizedDescription
        }
    }

    private func cancelDefaultEdit() {
        destinationRulesDraft.cancel()
        validationMessage = nil
    }

    private func saveDefaultDestination() {
        do {
            try applyDestinationRulesDraft()
        } catch {
            validationMessage = error.localizedDescription
        }
    }

    private func stageRules(_ rules: [AddTorrentDestinationRule]) throws {
        destinationRulesDraft.rules = rules
        try applyDestinationRulesDraft()
    }

    private func applyDestinationRulesDraft() throws {
        preferences.setAddDestinationRules(try destinationRulesDraft.apply())
        validationMessage = nil
    }

    private func synchronize(with snapshot: AddTorrentDestinationRulesSnapshot) {
        destinationRulesDraft = AddTorrentDestinationRulesDraft(snapshot: snapshot)
        cancelRuleEdit()
    }
}
