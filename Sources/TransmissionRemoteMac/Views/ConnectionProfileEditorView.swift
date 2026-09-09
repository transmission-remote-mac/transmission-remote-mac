// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import SwiftUI
import UniformTypeIdentifiers

struct ConnectionProfileEditorView: View {
    @Binding var profile: ConnectionProfileDraft
    @Binding var clientIdentityLoadState: ClientIdentityFileLoader.LoadState
    var onClientIdentityLoadStarted: (ConnectionProfile.ID) -> ClientIdentityFileLoader.Request?
    var onClientIdentityLoaded: (ClientIdentityFileLoader.Request, String, Data) -> Bool
    var onClientIdentityLoadFailed: (ClientIdentityFileLoader.Request) -> Bool
    @State private var isSelectingClientIdentity = false
    @State private var clientIdentitySelectionOwner: ConnectionProfile.ID?
    @State private var clientIdentitySelectionError: String?
    @State private var clientIdentityTask: (request: ClientIdentityFileLoader.Request, task: Task<Void, Never>)?

    var body: some View {
        Form {
            Section("Server") {
                TextField("Name", text: $profile.name)

                Picker("Scheme", selection: $profile.scheme) {
                    Text("HTTP").tag("http")
                    Text("HTTPS").tag("https")
                }
                .pickerStyle(.segmented)

                TextField("Host", text: $profile.host)

                TextField("Port", text: $profile.port)
                    .monospacedDigit()

                TextField("RPC path", text: $profile.rpcPath)
            }

            Section("Authentication") {
                TextField("Username", text: $profile.username)

                Toggle("Ask for password when connecting", isOn: $profile.askPasswordAtConnect)

                SecureField("Password", text: $profile.password)
                    .disabled(profile.askPasswordAtConnect)
                    .foregroundStyle(profile.askPasswordAtConnect ? .secondary : .primary)

                Text("Saved passwords are stored in macOS Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("TLS Client Identity") {
                if profile.scheme.lowercased() != "https" {
                    Text("Client certificate authentication is available only for HTTPS servers.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    if let metadata = profile.clientIdentityMetadata {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(metadata.displayName)
                                .font(.headline)
                            Text("Issued by \(metadata.issuer)")
                            Text("Valid until \(metadata.notAfter.formatted(date: .abbreviated, time: .omitted))")
                            Text(metadata.sha256Fingerprint)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                        .foregroundStyle(
                            profile.removeClientIdentityOnApply ? Color.secondary : Color.primary
                        )
                    }

                    if clientIdentityLoadState.isLoading {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("Loading client identity file…")
                            Button("Cancel Loading") { cancelClientIdentityLoad() }
                        }
                    } else if profile.removeClientIdentityOnApply {
                        Label("This client identity will be removed when you Apply.", systemImage: "trash")
                            .foregroundStyle(.secondary)

                        Button("Undo Removal") {
                            profile.restoreClientIdentity()
                        }
                    } else if let pendingImport = profile.pendingClientIdentityImport {
                        Label(pendingImport.sourceFileName, systemImage: "checkmark.shield")

                        SecureField("PKCS#12 password", text: pendingClientIdentityPassphrase)

                        Text("The password is used once during Apply and is never saved.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        HStack {
                            Button("Choose Different File…") {
                                presentClientIdentityImporter()
                            }

                            Button("Cancel Selection") {
                                profile.cancelPendingClientIdentityImport()
                            }
                        }
                    } else {
                        Button(profile.clientIdentityMetadata == nil ? "Import PKCS#12…" : "Replace PKCS#12…") {
                            presentClientIdentityImporter()
                        }

                        if profile.clientIdentityMetadata != nil {
                            Button("Remove Client Identity", role: .destructive) {
                                profile.removeClientIdentity()
                            }
                        }
                    }

                    Text("Private keys stay in macOS Keychain. The per-server binding is removed only when removal is applied; profile files and exports contain public certificate metadata only.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .onChange(of: profile.scheme) { _, scheme in
                guard scheme.lowercased() != "https" else { return }
                cancelClientIdentityLoad()
                cancelClientIdentitySelection()
                profile.removeClientIdentity()
            }

            Section("Connection") {
                Toggle("Connect when the app opens", isOn: $profile.connectOnLaunch)

                Text("Make one launch connection attempt to this server when it is the selected profile.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Always auto-reconnect", isOn: $profile.autoReconnect)

                Text("Retry unexpected transport failures with a gradually increasing delay.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField("Request timeout (seconds)", text: $profile.requestTimeoutSeconds)
                    .monospacedDigit()

                Text("Allow 1 to 300 seconds for each connection or RPC request.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Proxy") {
                Picker("Transport", selection: $profile.proxySettings.transport) {
                    ForEach(ProxyTransport.allCases) { transport in
                        Text(transport.displayName).tag(transport)
                    }
                }

                if profile.proxySettings.transport != .direct {
                    TextField("Host", text: $profile.proxySettings.host)

                    TextField("Port", value: $profile.proxySettings.port, format: .number.grouping(.never))
                        .monospacedDigit()

                    Toggle("Proxy requires authentication", isOn: $profile.proxySettings.authenticationEnabled)

                    if profile.proxySettings.authenticationEnabled {
                        TextField("Username", text: $profile.proxySettings.username)
                        SecureField("Password", text: $profile.proxyPassword)

                        Text("The proxy password is stored separately in macOS Keychain and is never included in profile files or exports.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Text(proxyTransportHelp)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Connect directly without an application-configured proxy.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .onChange(of: profile.proxySettings.transport) { oldTransport, newTransport in
                if oldTransport == .direct || profile.proxySettings.port == oldTransport.defaultPort {
                    profile.proxySettings.port = newTransport.defaultPort
                }
                if newTransport == .direct {
                    profile.proxySettings.authenticationEnabled = false
                    profile.proxySettings.username = ""
                    profile.proxyPassword = ""
                }
            }
            .onChange(of: profile.proxySettings.authenticationEnabled) { _, authenticationEnabled in
                if !authenticationEnabled {
                    profile.proxySettings.username = ""
                    profile.proxyPassword = ""
                }
            }

            Section("Transfer Presets and History") {
                ProfileTransferPreferencesView(preferences: $profile.transferPreferences)
            }

            Section("Path Mappings") {
                if profile.pathMappings.isEmpty {
                    Text("Map daemon paths to local Mac paths for Finder reveal/open actions.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ForEach($profile.pathMappings) { $mapping in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        TextField("Daemon path", text: $mapping.remotePathPrefix)
                            .textFieldStyle(.roundedBorder)

                        Image(systemName: "arrow.right")
                            .foregroundStyle(.secondary)

                        TextField("Local path", text: $mapping.localPathPrefix)
                            .textFieldStyle(.roundedBorder)

                        Button(role: .destructive) {
                            profile.pathMappings.removeAll { $0.id == mapping.id }
                        } label: {
                            Label("Remove Mapping", systemImage: "minus.circle")
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Remove path mapping")
                    }
                }

                Button {
                    profile.pathMappings.append(PathMappingDraft(remotePathPrefix: "", localPathPrefix: ""))
                } label: {
                    Label("Add Path Mapping", systemImage: "plus")
                }

                Text("Longest daemon prefix wins. Example: /downloads → /Volumes/Downloads")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        }
        .formStyle(.grouped)
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
        .onDisappear {
            cancelClientIdentityLoad()
            cancelClientIdentitySelection()
        }
        .onChange(of: profile.id) { _, _ in
            cancelClientIdentityLoad()
            cancelClientIdentitySelection()
        }
        .onChange(of: clientIdentityLoadState.isLoading) { _, isLoading in
            if !isLoading { cancelClientIdentityLoad() }
        }
        .fileImporter(
            isPresented: $isSelectingClientIdentity,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            selectClientIdentity(result)
        }
        .alert(
            "Client Identity",
            isPresented: Binding(
                get: { clientIdentitySelectionError != nil },
                set: { if !$0 { clientIdentitySelectionError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(clientIdentitySelectionError ?? "")
        }
    }

    private var pendingClientIdentityPassphrase: Binding<String> {
        Binding(
            get: { profile.pendingClientIdentityImport?.passphrase ?? "" },
            set: { passphrase in
                guard var pendingImport = profile.pendingClientIdentityImport else { return }
                pendingImport.passphrase = passphrase
                profile.pendingClientIdentityImport = pendingImport
            }
        )
    }

    private func selectClientIdentity(_ result: Result<[URL], Error>) {
        guard clientIdentitySelectionOwner == profile.id else { return }
        clientIdentitySelectionOwner = nil
        cancelClientIdentityLoad()
        do {
            guard let url = try result.get().first else { return }
            guard profile.scheme.lowercased() == "https" else { return }
            guard let request = onClientIdentityLoadStarted(profile.id) else { return }
            clientIdentitySelectionError = nil
            let task = Task { @MainActor in
                do {
                    let data = try await ClientIdentityFileLoader().load(at: url)
                    try Task.checkCancellation()
                    guard clientIdentityLoadState.request == request else { return }
                    _ = onClientIdentityLoaded(request, url.lastPathComponent, data)
                } catch is CancellationError {
                    clientIdentityLoadState.cancel(request)
                } catch {
                    guard clientIdentityLoadState.request == request,
                          onClientIdentityLoadFailed(request) else { return }
                    clientIdentitySelectionError = (error as? ClientIdentityFileSelectionError)?.localizedDescription
                        ?? "The selected PKCS#12 file could not be read."
                }
                if clientIdentityTask?.request == request { clientIdentityTask = nil }
            }
            clientIdentityTask = (request, task)
        } catch {
            clientIdentitySelectionError = "The selected PKCS#12 file could not be read."
        }
    }

    private func presentClientIdentityImporter() {
        clientIdentitySelectionOwner = profile.id
        isSelectingClientIdentity = true
    }

    private func cancelClientIdentitySelection() {
        clientIdentitySelectionOwner = nil
        isSelectingClientIdentity = false
    }

    private func cancelClientIdentityLoad() {
        guard let owned = clientIdentityTask else { return }
        owned.task.cancel()
        clientIdentityLoadState.cancel(owned.request)
        clientIdentityTask = nil
    }

    private var proxyTransportHelp: String {
        switch profile.proxySettings.transport {
        case .direct:
            ""
        case .http:
            "Route HTTP requests through this proxy. HTTPS RPC endpoints use an HTTP CONNECT tunnel through the same proxy."
        case .https:
            "Route HTTPS RPC requests through this proxy. macOS URL Loading handles the proxy tunnel and server trust remains system-managed."
        case .socks5:
            "Route RPC traffic through a SOCKS 5 proxy."
        }
    }
}
