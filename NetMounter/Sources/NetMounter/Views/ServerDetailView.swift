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
                
                Section(header: Text("Auto-Mount").foregroundColor(.secondary)) {
                    Text("Auto-mount rules can be configured in settings.")
                        .font(.caption)
                        .foregroundColor(.secondary)
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
                .disabled(config.alias.isEmpty || config.hostname.isEmpty)
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
    
    private func testConnection() {
        isTestRunning = true
        testResult = nil
        ConnectionTester.shared.checkReachability(host: config.hostname) { result in
            DispatchQueue.main.async {
                isTestRunning = false
                switch result {
                case .success(true):
                    testResult = true
                case .success(false), .failure:
                    testResult = false
                }
            }
        }
    }
    
    private func save() {
        // Save password if provided
        if !password.isEmpty {
            let accountName = UUID().uuidString // Unique ID for keychain item
            if let savedAccount = KeychainManager.shared.save(password: password, for: accountName) {
                config.keychainItemId = savedAccount
            }
        }
        
        if isNew {
            appState.addServer(config)
        } else {
            appState.updateServer(config)
        }
        presentationMode.wrappedValue.dismiss()
    }
}
