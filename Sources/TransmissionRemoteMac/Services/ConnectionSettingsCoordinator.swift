// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Combine
import Foundation

/// Owns the process-local server-settings editing session. Draft credentials,
/// TLS choices, and proxy settings remain here until the user explicitly saves
/// or reverts them; closing the Settings scene never persists them.
@MainActor
final class ConnectionSettingsCoordinator: ObservableObject {
    @Published var draftProfiles: [ConnectionProfileDraft] {
        willSet {
            guard let request = clientIdentityLoadState.request else { return }
            if !newValue.contains(where: { $0.id == request.profileID && $0.scheme.lowercased() == "https" }) {
                clientIdentityLoadState.cancel()
            }
        }
    }
    @Published var editingProfileID: ConnectionProfile.ID? {
        willSet {
            if newValue != editingProfileID { clientIdentityLoadState.cancel() }
        }
    }
    @Published var clientIdentityLoadState = ClientIdentityFileLoader.LoadState()
    @Published private(set) var saveFailure: ConnectionProfileApplyFailure?

    private var persistedProfiles: [ConnectionProfile]
    private var persistedDrafts: [ConnectionProfileDraft]
    private var selectedProfileID: ConnectionProfile.ID

    init(
        profiles: [ConnectionProfile],
        selectedProfileID: ConnectionProfile.ID
    ) {
        let initialDrafts = profiles.map(ConnectionProfileDraft.init)
        persistedProfiles = profiles
        persistedDrafts = initialDrafts
        self.selectedProfileID = selectedProfileID
        draftProfiles = initialDrafts
        editingProfileID = profiles.contains(where: { $0.id == selectedProfileID })
            ? selectedProfileID
            : profiles.first?.id
    }

    var selectedDraftIndex: Int? {
        guard let editingProfileID else { return nil }
        return draftProfiles.firstIndex { $0.id == editingProfileID }
    }

    func draftProfile(id: ConnectionProfile.ID) -> ConnectionProfileDraft? {
        draftProfiles.first { $0.id == id }
    }

    func updateDraftProfile(_ draft: ConnectionProfileDraft, matching id: ConnectionProfile.ID) {
        guard draft.id == id, let index = draftProfiles.firstIndex(where: { $0.id == id }) else { return }
        draftProfiles[index] = draft
    }

    func beginClientIdentityLoad(for profileID: ConnectionProfile.ID) -> ClientIdentityFileLoader.Request? {
        guard editingProfileID == profileID, draftProfile(id: profileID)?.scheme.lowercased() == "https" else {
            return nil
        }
        return clientIdentityLoadState.begin(profileID: profileID)
    }

    @discardableResult
    func completeClientIdentityLoad(
        _ request: ClientIdentityFileLoader.Request,
        fileName: String,
        data: Data
    ) -> Bool {
        guard let index = clientIdentityDraftIndex(for: request) else {
            clientIdentityLoadState.cancel(request)
            return false
        }
        guard clientIdentityLoadState.complete(request, profileID: request.profileID) else { return false }
        draftProfiles[index].stageClientIdentityImport(fileName: fileName, data: data)
        return true
    }

    func failClientIdentityLoad(_ request: ClientIdentityFileLoader.Request) -> Bool {
        guard clientIdentityDraftIndex(for: request) != nil else {
            clientIdentityLoadState.cancel(request)
            return false
        }
        return clientIdentityLoadState.complete(request, profileID: request.profileID)
    }

    var hasChanges: Bool {
        draftProfiles != persistedDrafts
    }

    var activeDraftProfileID: ConnectionProfile.ID? {
        draftProfiles.contains(where: { $0.id == selectedProfileID })
            ? selectedProfileID
            : nil
    }

    var validationIssues: [String] {
        var issues: [String] = []
        var seenNames = Set<String>()

        if draftProfiles.isEmpty {
            issues.append("At least one server is required.")
        }

        for profile in draftProfiles {
            let name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty {
                issues.append("Every server needs a name.")
            } else if !seenNames.insert(name.localizedLowercase).inserted {
                issues.append("Server names must be unique.")
            }

            do {
                _ = try profile.validatedProfile()
            } catch {
                issues.append(error.localizedDescription)
            }
        }

        return Array(issues.prefix(2))
    }

    var saveFailureMessage: String? {
        saveFailure?.localizedDescription
    }

    var hasExternalChangeConflict: Bool {
        saveFailure?.kind == .persistedProfilesChanged
    }

    var blocksSettingsImport: Bool {
        hasChanges || saveFailure != nil || clientIdentityLoadState.isLoading
    }

    func synchronize(
        profiles: [ConnectionProfile],
        selectedProfileID: ConnectionProfile.ID
    ) {
        clientIdentityLoadState.cancel()
        let canReplaceDrafts = saveFailure == nil && draftProfiles == persistedDrafts
        let persistedProfilesChanged = profiles != persistedProfiles
        persistedProfiles = profiles
        persistedDrafts = profiles.map(ConnectionProfileDraft.init)
        self.selectedProfileID = selectedProfileID

        if canReplaceDrafts {
            resetDrafts()
        } else if persistedProfilesChanged {
            saveFailure = .persistedProfilesChanged
        }
    }

    func addProfile() {
        clientIdentityLoadState.cancel()
        let profile = ConnectionProfile(
            name: uniqueName(base: "New Server"),
            host: ""
        )
        let draft = ConnectionProfileDraft(profile: profile)
        draftProfiles.append(draft)
        editingProfileID = draft.id
    }

    func duplicateSelectedProfile() {
        guard let selectedDraftIndex else { return }
        clientIdentityLoadState.cancel()
        var profile = draftProfiles[selectedDraftIndex]
        profile.id = UUID()
        profile.name = uniqueName(base: "\(profile.name) Copy")
        draftProfiles.insert(profile, at: selectedDraftIndex + 1)
        editingProfileID = profile.id
    }

    func deleteSelectedProfile() {
        guard let selectedDraftIndex, draftProfiles.count > 1 else { return }
        clientIdentityLoadState.cancel()
        draftProfiles.remove(at: selectedDraftIndex)

        let nextIndex = min(selectedDraftIndex, draftProfiles.count - 1)
        editingProfileID = draftProfiles[nextIndex].id
    }

    func resetDrafts() {
        clientIdentityLoadState.cancel()
        draftProfiles = persistedDrafts
        editingProfileID = persistedDrafts.contains(where: { $0.id == selectedProfileID })
            ? selectedProfileID
            : persistedDrafts.first?.id
        saveFailure = nil
    }

    @discardableResult
    func apply(
        using save: ([ConnectionProfile], ConnectionProfile.ID?)
            -> Result<Void, ConnectionProfileApplyFailure>
    ) -> Result<Void, ConnectionProfileApplyFailure>? {
        guard !clientIdentityLoadState.isLoading else { return nil }
        if hasExternalChangeConflict {
            return .failure(.persistedProfilesChanged)
        }
        guard validationIssues.isEmpty else { return nil }

        let validatedProfiles: [ConnectionProfile]
        do {
            validatedProfiles = try makeValidatedProfiles()
        } catch {
            let failure = ConnectionProfileApplyFailure.invalidProfiles(error)
            saveFailure = failure
            return .failure(failure)
        }

        let nextSelectedProfileID = activeDraftProfileID
        let result = save(validatedProfiles, nextSelectedProfileID)
        switch result {
        case .success:
            let normalizedDrafts = validatedProfiles.map(ConnectionProfileDraft.init)
            persistedProfiles = validatedProfiles
            persistedDrafts = normalizedDrafts
            selectedProfileID = nextSelectedProfileID ?? validatedProfiles[0].id
            draftProfiles = normalizedDrafts
            if !draftProfiles.contains(where: { $0.id == editingProfileID }) {
                editingProfileID = selectedProfileID
            }
            saveFailure = nil
        case .failure(let failure):
            saveFailure = failure
        }
        return result
    }

    private func clientIdentityDraftIndex(for request: ClientIdentityFileLoader.Request) -> Int? {
        guard clientIdentityLoadState.request == request,
              editingProfileID == request.profileID,
              let index = draftProfiles.firstIndex(where: { $0.id == request.profileID }),
              draftProfiles[index].scheme.lowercased() == "https" else { return nil }
        return index
    }

    private func uniqueName(base: String) -> String {
        let existingNames = Set(draftProfiles.map { $0.name.localizedLowercase })
        var candidate = base.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.isEmpty {
            candidate = "Server"
        }

        guard existingNames.contains(candidate.localizedLowercase) else {
            return candidate
        }

        var index = 2
        while existingNames.contains("\(candidate) \(index)".localizedLowercase) {
            index += 1
        }
        return "\(candidate) \(index)"
    }

    private func makeValidatedProfiles() throws -> [ConnectionProfile] {
        let profiles = try draftProfiles.map { try $0.validatedProfile() }
        var names = Set<String>()
        for profile in profiles {
            guard names.insert(profile.name.localizedLowercase).inserted else {
                throw ConnectionProfileStoreError.duplicateProfileName(profile.name)
            }
        }
        return profiles
    }
}
