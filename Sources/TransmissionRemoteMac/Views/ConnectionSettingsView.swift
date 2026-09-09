// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import SwiftUI

struct ConnectionSettingsView: View {
    var profiles: [ConnectionProfile]
    var selectedProfileID: ConnectionProfile.ID
    @ObservedObject var coordinator: ConnectionSettingsCoordinator
    var onApply: ([ConnectionProfile], ConnectionProfile.ID?)
        -> Result<Void, ConnectionProfileApplyFailure>

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                profileList
                    .frame(width: 220)

                Divider()

                editor
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()

            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear(perform: synchronizeDrafts)
        .onChange(of: profiles) { _, _ in
            synchronizeDrafts()
        }
        .onChange(of: selectedProfileID) { _, _ in
            synchronizeDrafts()
        }
        .onDisappear { coordinator.clientIdentityLoadState.cancel() }
    }

    private var profileList: some View {
        VStack(spacing: 0) {
            List(selection: $coordinator.editingProfileID) {
                ForEach(coordinator.draftProfiles, id: \.id) { profile in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(profile.name.isEmpty ? "Unnamed Server" : profile.name)
                                .font(.headline)
                            Text(endpointSummary(for: profile))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 4)

                        if profile.id == coordinator.activeDraftProfileID {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Color.accentColor)
                                .help("Active server")
                                .accessibilityHidden(true)
                        }
                    }
                    .padding(.vertical, 3)
                    .tag(profile.id)
                    .accessibilityLabel(profile.name.isEmpty ? "Unnamed Server" : profile.name)
                    .accessibilityValue(
                        profile.id == coordinator.activeDraftProfileID
                            ? "Active server"
                            : "Inactive server"
                    )
                }
            }
            .overlay {
                if coordinator.draftProfiles.isEmpty {
                    ContentUnavailableView("No Servers", systemImage: "server.rack")
                }
            }

            Divider()

            HStack(spacing: 8) {
                Button {
                    coordinator.addProfile()
                } label: {
                    Label("Add Server", systemImage: "plus")
                }
                .labelStyle(.iconOnly)
                .help("Add server")

                Button {
                    coordinator.duplicateSelectedProfile()
                } label: {
                    Label("Duplicate Server", systemImage: "plus.square.on.square")
                }
                .labelStyle(.iconOnly)
                .help("Duplicate selected server")
                .disabled(coordinator.selectedDraftIndex == nil)

                Button(role: .destructive) {
                    coordinator.deleteSelectedProfile()
                } label: {
                    Label("Delete Server", systemImage: "trash")
                }
                .labelStyle(.iconOnly)
                .help("Delete selected server")
                .disabled(
                    coordinator.selectedDraftIndex == nil
                        || coordinator.draftProfiles.count <= 1
                )

                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private var editor: some View {
        if let selectedProfileID = coordinator.editingProfileID,
           let draft = coordinator.draftProfile(id: selectedProfileID) {
            ConnectionProfileEditorView(
                profile: Self.draftBinding(for: draft, coordinator: coordinator),
                clientIdentityLoadState: $coordinator.clientIdentityLoadState,
                onClientIdentityLoadStarted: coordinator.beginClientIdentityLoad,
                onClientIdentityLoaded: coordinator.completeClientIdentityLoad,
                onClientIdentityLoadFailed: coordinator.failClientIdentityLoad
            )
                .id(draft.id)
        } else {
            ContentUnavailableView("Select a Server", systemImage: "server.rack")
        }
    }

    @MainActor
    static func draftBinding(
        for capturedDraft: ConnectionProfileDraft,
        coordinator: ConnectionSettingsCoordinator
    ) -> Binding<ConnectionProfileDraft> {
        Binding(
            get: { coordinator.draftProfile(id: capturedDraft.id) ?? capturedDraft },
            set: { coordinator.updateDraftProfile($0, matching: capturedDraft.id) }
        )
    }

    private var footer: some View {
        HStack {
            Text(statusText)
                .font(.caption)
                .foregroundStyle(hasBlockingStatus ? Color.red : Color.secondary)
                .lineLimit(2)

            Spacer()

            Button("Revert") {
                coordinator.resetDrafts()
            }
            .disabled(!coordinator.hasChanges && coordinator.saveFailure == nil && !coordinator.clientIdentityLoadState.isLoading)

            Button("Save Changes") {
                applyDrafts()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(
                !coordinator.hasChanges
                    || !coordinator.validationIssues.isEmpty
                    || coordinator.hasExternalChangeConflict
                    || coordinator.clientIdentityLoadState.isLoading
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var statusText: String {
        if coordinator.hasExternalChangeConflict,
           let saveFailureMessage = coordinator.saveFailureMessage {
            return saveFailureMessage
        }
        if let validationIssue = coordinator.validationIssues.first {
            return validationIssue
        }
        if let saveFailureMessage = coordinator.saveFailureMessage {
            return saveFailureMessage
        }
        if coordinator.hasChanges {
            return "Unsaved server changes."
        }
        return "Server settings are saved for future launches."
    }

    private var hasBlockingStatus: Bool {
        !coordinator.validationIssues.isEmpty || coordinator.saveFailureMessage != nil
    }

    private func applyDrafts() {
        coordinator.apply(using: onApply)
    }

    private func synchronizeDrafts() {
        coordinator.synchronize(
            profiles: profiles,
            selectedProfileID: selectedProfileID
        )
    }

    private func endpointSummary(for profile: ConnectionProfileDraft) -> String {
        let host = profile.host.isEmpty ? "host" : profile.host
        return "\(profile.scheme)://\(host):\(profile.port)\(profile.rpcPath)"
    }
}

#Preview {
    ConnectionSettingsPreview()
}

private struct ConnectionSettingsPreview: View {
    @State private var profiles: [ConnectionProfile] = [.localDefault]
    @State private var selectedProfileID: ConnectionProfile.ID = ConnectionProfile.localDefault.id
    @StateObject private var coordinator = ConnectionSettingsCoordinator(
        profiles: [.localDefault],
        selectedProfileID: ConnectionProfile.localDefault.id
    )

    var body: some View {
        ConnectionSettingsView(
            profiles: profiles,
            selectedProfileID: selectedProfileID,
            coordinator: coordinator,
            onApply: { profiles, selectedProfileID in
                self.profiles = profiles
                self.selectedProfileID = selectedProfileID ?? profiles[0].id
                return .success(())
            }
        )
    }
}
