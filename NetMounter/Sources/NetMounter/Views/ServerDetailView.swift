import SwiftUI

struct ServerDetailView: View {
    @Environment(\.presentationMode) var presentationMode
    @EnvironmentObject var appState: AppState

    @State var config: ServerConfig
    @State private var password: String = ""
    @State private var isTestRunning = false
    @State private var testResult: Bool? = nil
    var isNew: Bool
    
    init(config: ServerConfig? = nil) {
        if let existing = config {
            _config = State(initialValue: existing)
            isNew = false
        } else {
            _config = State(initialValue: ServerConfig(alias: "", hostname: "", sharePath: ""))
            isNew = true
        }
    }
    
    var body: some View {
        ZStack {
            LiquidGlassBackground()
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
            
            Form {
                Section(header: Text("Server Details").foregroundColor(.secondary)) {
                    TextField("Name", text: $config.alias)
                    Picker("Protocol", selection: $config.serverProtocol) {
                        ForEach(NetworkProtocol.allCases, id: \.self) { proto in
                            Text(proto.displayName).tag(proto)
                        }
                    }
                    TextField("Hostname / IP", text: $config.hostname)
                    TextField("Share Path", text: $config.sharePath)
                }
                
                Section(header: Text("Authentication").foregroundColor(.secondary)) {
                    if config.serverProtocol == .nfs {
                        Text("NFS uses host-based access control. No credentials needed.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        TextField("Username", text: Binding(
                            get: { config.username ?? "" },
                            set: { config.username = $0.isEmpty ? nil : $0 }
                        ))
                        SecureField("Password", text: $password)

                        Button("Test Connection") {
                            testConnection()
                        }
                        .disabled(config.hostname.isEmpty || isTestRunning)

                        if let result = testResult {
                            Text(result ? "Connection Successful" : "Connection Failed")
                                .foregroundColor(result ? .green : .red)
                                .font(.caption)
                        }
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
                    }
                }

                Section {
                    Toggle("Auto-Mount", isOn: Binding(
                        get: { !config.autoMountRules.isEmpty },
                        set: { enabled in
                            if enabled {
                                addCurrentNetwork()
                            } else {
                                config.autoMountRules.removeAll()
                            }
                        }
                    ))
                    .toggleStyle(.switch)
                    .disabled(NetworkMonitor.shared.currentFingerprint == nil && config.autoMountRules.isEmpty)
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
            }
            .scrollContentBackground(.hidden)
            .padding()
        }
        .frame(minWidth: 300, minHeight: 400)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    save()
                }
                .disabled(config.alias.isEmpty || config.hostname.isEmpty || (config.serverProtocol == .nfs && config.sharePath.trimmingCharacters(in: CharacterSet(charactersIn: "/\\ ")).isEmpty))
            }
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    presentationMode.wrappedValue.dismiss()
                }
            }
        }
        .onAppear {
            if !isNew, let keyId = config.keychainItemId {
                // Load password
                if let pass = KeychainManager.shared.retrievePassword(for: keyId) {
                    self.password = pass
                }
            }
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

    private func addCurrentNetwork() {
        guard let fingerprint = NetworkMonitor.shared.currentFingerprint else { return }
        let alreadyExists = config.autoMountRules.contains { $0.fingerprint.matches(fingerprint) }
        guard !alreadyExists else { return }
        config.autoMountRules.append(AutoMountRule(fingerprint: fingerprint))
    }

    private func testConnection() {
        isTestRunning = true
        testResult = nil
        ConnectionTester.shared.checkReachability(host: config.hostname, port: config.serverProtocol.defaultPort) { result in
            DispatchQueue.main.async {
                isTestRunning = false
                switch result {
                case .success(true):
                    testResult = true
                    if config.wolMACAddress == nil {
                        DispatchQueue.global(qos: .utility).async {
                            if let mac = WOLService.shared.resolveMAC(for: self.config.hostname) {
                                DispatchQueue.main.async {
                                    self.config.wolMACAddress = mac
                                }
                            }
                        }
                    }
                case .success(false), .failure:
                    testResult = false
                }
            }
        }
    }
    
    private func save() {
        // Save password if provided
        if !password.isEmpty {
            // Reuse existing keychain item ID or create a new one
            let accountName = config.keychainItemId ?? UUID().uuidString
            if let savedAccount = KeychainManager.shared.save(password: password, for: accountName) {
                config.keychainItemId = savedAccount
            }
        } else if password.isEmpty, let keyId = config.keychainItemId {
            // Password cleared — remove keychain entry
            KeychainManager.shared.delete(account: keyId)
            config.keychainItemId = nil
        }
        
        if isNew {
            appState.addServer(config)
        } else {
            appState.updateServer(config)
        }
        presentationMode.wrappedValue.dismiss()
    }
}
