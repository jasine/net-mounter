import SwiftUI

struct ServerDetailView: View {
    @Environment(\.presentationMode) var presentationMode
    @EnvironmentObject var appState: AppState

    @State var config: ServerConfig
    @State private var password: String = ""
    @State private var reachability = ReachabilityCheckState()
    @State private var removeSavedPassword = false
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var saveNotice: String?
    @State private var isNew: Bool
    
    init(config: ServerConfig? = nil, isNew: Bool? = nil) {
        if let existing = config {
            _config = State(initialValue: existing)
            _isNew = State(initialValue: isNew ?? false)
        } else {
            _config = State(initialValue: ServerConfig(alias: "", hostname: "", sharePath: ""))
            _isNew = State(initialValue: true)
        }
    }
    
    var body: some View {
        ZStack {
            LiquidGlassBackground()
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
            
            VStack(spacing: 0) {
                Form {
                    Section(header: Text("Server Details").foregroundColor(.secondary)) {
                        TextField("Name", text: $config.alias)
                        Text("A label for this server, e.g. \"Home NAS\".")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Picker("Protocol", selection: $config.serverProtocol) {
                            ForEach(NetworkProtocol.allCases, id: \.self) { proto in
                                Text(proto.displayName).tag(proto)
                            }
                        }

                        TextField("Hostname / IP", text: $config.hostname)
                        Text("IP or hostname only — no protocol prefix or slashes. e.g. 192.168.1.50, nas.local, or a Tailscale IP like 100.101.102.103.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        TextField(sharePathPlaceholder, text: $config.sharePath)
                        Text(sharePathHelp)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Section(header: Text("Authentication").foregroundColor(.secondary)) {
                        if config.serverProtocol == .nfs {
                            Text("NFS uses host-based access control. No credentials needed.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            TextField("Username", text: Binding(
                                get: { config.username ?? "" },
                                set: { config.username = $0.isEmpty ? nil : $0 }
                            ))
                            SecureField("Password", text: $password)
                                .disabled(removeSavedPassword)
                            if config.keychainItemId != nil {
                                Text("A password is saved in Keychain. Leave this field blank to keep it.", bundle: .module)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Toggle(isOn: $removeSavedPassword) {
                                    Text("Remove saved password when saving", bundle: .module)
                                }
                            }
                        }

                        if config.serverProtocol == .nfs && !PrivilegedMountInstaller.isInstalled() {
                            Text("Saving sets up a persistent NFS helper with one-time administrator authorization. Later mounts will not ask again.", bundle: .module)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Section {
                        HStack {
                            Button(action: testConnection) {
                                Text("Check server reachability", bundle: .module)
                            }
                            .disabled(!config.isValidHostname || reachability.isRunning)
                            if reachability.isRunning {
                                ProgressView().controlSize(.small)
                            }
                        }
                        if let result = reachability.result {
                            Text(result
                                 ? String(localized: "Server port is reachable. Account and share access have not been verified.", bundle: .module)
                                 : String(localized: "Server port is unreachable. Check the address, network, and server service.", bundle: .module))
                                .foregroundColor(result ? .primary : .red)
                                .font(.caption)
                        }
                    }

                    Section(header: Text("Pinned Folders").foregroundColor(.secondary)) {
                        ForEach(config.pinnedFolders) { pin in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(pin.name).font(.body)
                                    Text(pin.subpath).font(.caption).foregroundColor(.secondary)
                                }
                                Spacer()
                                Button(action: {
                                    config.pinnedFolders.removeAll { $0.id == pin.id }
                                }) {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundColor(.red)
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        Button(action: pickFolder) {
                            Label("Choose Folder…", systemImage: "folder.badge.plus")
                        }
                        .disabled(mountPath == nil)

                        if mountPath == nil {
                            Text("Mount the server first to browse folders.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Section {
                        Toggle("Auto-Mount", isOn: Binding(
                            get: { config.hasEnabledAutoMountRules },
                            set: { config.setAutoMountEnabled($0, fingerprint: NetworkMonitor.shared.currentFingerprint) }
                        ))
                        .toggleStyle(.switch)
                        .disabled(NetworkMonitor.shared.currentFingerprint == nil && config.autoMountRules.isEmpty)
                        Text(config.autoMountRules.isEmpty
                             ? String(localized: "Enable to remember the current network. No automatic mount occurs until you save.", bundle: .module)
                             : String(localized: "Automatic mounting uses saved networks or a VPN route. Turning it off keeps your saved networks and stops future attempts; existing mounts stay connected.", bundle: .module))
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if !isNew {
                        Section(header: Text("Wake-on-LAN").foregroundColor(.secondary)) {
                            Toggle("Wake before mount", isOn: $config.wolEnabled)
                                .toggleStyle(.switch)
                                .disabled(config.wolMACAddress == nil)

                            TextField("MAC Address", text: Binding(
                                get: { config.wolMACAddress ?? "" },
                                set: { config.wolMACAddress = $0.isEmpty ? nil : $0 }
                            ))
                            .textFieldStyle(.roundedBorder)

                            if config.wolMACAddress == nil {
                                Text("Enter MAC address or connect to server to auto-detect.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            DisclosureGroup("Advanced") {
                                TextField("Broadcast Address", text: Binding(
                                    get: { config.wolBroadcastAddress ?? "255.255.255.255" },
                                    set: { config.wolBroadcastAddress = ($0 == "255.255.255.255" || $0.isEmpty) ? nil : $0 }
                                ))
                                TextField("Port", value: $config.wolPort, format: .number)
                            }
                        }
                    }
                    if let message = config.validationMessage {
                        Section {
                            Text(message).font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
                .formStyle(.grouped)
                .disabled(isSaving)
                .scrollContentBackground(.hidden)

                Divider()
                HStack {
                    Button {
                        presentationMode.wrappedValue.dismiss()
                    } label: { Text("Cancel", bundle: .module) }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSaving)
                    Spacer()
                    Button(action: save) {
                        HStack(spacing: 6) {
                            if isSaving { ProgressView().controlSize(.small) }
                            Text(isSaving ? "Saving…" : "Save", bundle: .module)
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(config.validationMessage != nil || isSaving || appState.isSavingServer)
                }
                .padding(12)
            }
        }
        .frame(width: 380, height: 600)
        .interactiveDismissDisabled(isSaving)
        .onChange(of: config.hostname) { reachability.reset() }
        .onChange(of: config.serverProtocol) { reachability.reset() }
        .onChange(of: config.sharePath) { reachability.reset() }
        .onChange(of: config.username) { reachability.reset() }
        .onChange(of: password) { reachability.reset() }
        .onChange(of: removeSavedPassword) { reachability.reset() }
        .onDisappear { reachability.reset() }
        .alert(String(localized: "Could not save", bundle: .module), isPresented: Binding(
            get: { saveError != nil }, set: { if !$0 { saveError = nil } }
        )) {
            Button("OK", role: .cancel) { saveError = nil }
        } message: { Text(saveError ?? "") }
        .alert(String(localized: "Configuration saved", bundle: .module), isPresented: Binding(
            get: { saveNotice != nil }, set: { if !$0 { saveNotice = nil } }
        )) {
            Button("Done") { presentationMode.wrappedValue.dismiss() }
        } message: { Text(saveNotice ?? "") }
    }

    private var sharePathPlaceholder: String {
        config.serverProtocol == .nfs ? "Export Path" : "Share Path"
    }

    private var sharePathHelp: String {
        switch config.serverProtocol {
        case .smb, .afp:
            return "The share name only, without slashes. For \\\\server\\media enter: media"
        case .nfs:
            return "The full export path from the server, e.g. /volume1/media (required for NFS)."
        case .webdav:
            return "Path to the WebDAV folder, e.g. remote.php/dav/files/user."
        }
    }

    private var mountPath: String? {
        guard let url = URL(string: config.urlString) else { return nil }
        return MountingManager.shared.findExistingMountPath(for: url)
    }

    private func pickFolder() {
        guard let root = mountPath,
              let pin = PinnedFolderPicker.pick(root: root) else { return }
        config.pinnedFolders.append(pin)
    }

    private func testConnection() {
        guard config.isValidHostname, !reachability.isRunning else { return }
        let request = reachability.start()
        ConnectionTester.shared.checkReachability(host: config.hostname, port: config.serverProtocol.defaultPort) { result in
            DispatchQueue.main.async {
                reachability.complete(request: request, reachable: (try? result.get()) == true)
            }
        }
    }

    private func save() {
        guard config.validationMessage == nil, !isSaving, !appState.isSavingServer else { return }
        isSaving = true
        appState.isSavingServer = true
        let appDelegate = NSApp.delegate as? AppDelegate
        appDelegate?.preventPopoverClose = true
        let change: PasswordChange = config.serverProtocol == .nfs ? .unchanged
            : removeSavedPassword ? .remove : password.isEmpty ? .unchanged : .replace(password)
        Task { @MainActor in
            defer {
                isSaving = false
                appState.isSavingServer = false
                appDelegate?.preventPopoverClose = false
            }
            let result = await ServerConfigurationSaver.save(
                config: config, passwordChange: change,
                savePassword: { password, account in
                    await Task.detached { KeychainManager.shared.save(password: password, for: account) }.value
                },
                deletePassword: { account in
                    await Task.detached { KeychainManager.shared.delete(account: account) }.value
                },
                persist: { isNew ? appState.addServer($0) : appState.updateServer($0) }
            )
            switch result {
            case .failure(let error):
                saveError = error.localizedDescription
            case .success(let outcome):
                config = outcome.config
                isNew = false
                password = ""
                removeSavedPassword = false
                var notices: [String] = []
                if outcome.credentialCleanupFailed {
                    notices.append(String(localized: "The configuration is saved, but the old password could not be removed from Keychain.", bundle: .module))
                }
                if notices.isEmpty {
                    presentationMode.wrappedValue.dismiss()
                } else {
                    saveNotice = notices.joined(separator: "\n\n")
                }
            }
        }
    }
}
