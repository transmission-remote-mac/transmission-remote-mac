// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import SwiftUI

struct PasswordPromptView: View {
    let prompt: AppStore.PasswordPrompt
    let onCancel: () -> Void
    let onConnect: (String) -> Void

    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Password Required")
                    .font(.title3.bold())
                Text(prompt.profileName)
                    .foregroundStyle(.secondary)
            }

            if !prompt.username.isEmpty {
                LabeledContent("Username", value: prompt.username)
            }

            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)

            Text(prompt.savesPassword ? "This password will be saved in macOS Keychain for future connections." : "This password is used for this connection only and is not saved to Keychain.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Connect", action: submit)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 380)
    }

    private func submit() {
        onConnect(password)
    }
}
