import SwiftUI



struct ServerListView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var autoMountService: AutoMountService
    
    @State private var showingAddSheet = false
    @State private var showingSettings = false
    @State private var editingServer: ServerConfig?
    
    var body: some View {
        ZStack {
            // 1. Background Layer (Liquid)
            LiquidGlassBackground()
            
            // 2. Translucent Material Layer (Frosted Glass Effect)
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()
            
            // 3. Content Layer
            VStack(spacing: 0) {
                // Glassy Header
                HStack {
                    Text("Servers")
                        .font(.system(.title2, design: .rounded))
                        .fontWeight(.bold)
                        .foregroundColor(.primary)
                    Spacer()
                    
                    Button(action: { showingAddSheet = true }) {
                        Image(systemName: "plus")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.primary)
                            .padding(8)
                            .background(.thinMaterial)
                            .clipShape(Circle())
                            .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)
                    }
                    .buttonStyle(.plain)
                    
                    Button(action: { showingSettings = true }) {
                        Image(systemName: "gear")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.primary)
                            .padding(8)
                            .background(.thinMaterial)
                            .clipShape(Circle())
                            .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)
                    }
                    .buttonStyle(.plain)
                }
                .padding()
                // Header Background (Optional, keeping it transparent essentially)
                
                // Scrollable List of Glass Cards
                ScrollView {
                    LazyVStack(spacing: 16) {
                        ForEach(appState.servers) { server in
                            ServerRow(server: server) {
                                editingServer = server
                            }
                        }
                    }
                    .padding()
                }
            }
        }
        .sheet(isPresented: $showingAddSheet) {
            ServerDetailView()
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        .sheet(item: $editingServer) { server in
            ServerDetailView(config: server)
        }
        // Ensure the hosting window (if any) allows this vibrancy
        .background(Color.clear)
    }
}

struct ServerRow: View {
    let server: ServerConfig
    let onEdit: () -> Void
    @State private var mountStatus: String = "Idle"
    @State private var isMounted = false
    let networkPublisher = NetworkMonitor.shared.$currentFingerprint
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Status Icon Pill
            ZStack {
                Circle()
                    .fill(.regularMaterial)
                    .frame(width: 48, height: 48)
                    .shadow(color: statusColor.opacity(0.3), radius: 6, x: 0, y: 0)
                    .overlay(
                        Circle()
                            .stroke(statusColor.opacity(0.5), lineWidth: 2)
                    )
                
                Image(systemName: "server.rack")
                    .font(.system(size: 20))
                    .foregroundColor(statusColor)
                    .opacity(isConnecting ? 0.5 : 1.0)
                    .animation(isConnecting ? Animation.easeInOut(duration: 0.8).repeatForever(autoreverses: true) : .default, value: isConnecting)
            }
            .help(mountStatus) // Tooltip for detailed status
            
            // Content Column
            VStack(alignment: .leading, spacing: 6) {
                // Header Row: Name + Spacer + Buttons
                HStack(spacing: 8) {
                    Text(server.alias)
                        .font(.system(.body, design: .rounded))
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)
                    
                    Spacer()
                    
                    // Actions (Glassy Buttons) - Tight spacing
                    HStack(spacing: 4) {
                        Button(action: toggleMount) {
                            Image(systemName: isMounted ? "eject.fill" : "play.fill")
                                .font(.system(size: 14))
                                .padding(8)
                                .background(.thinMaterial)
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .help(isMounted ? "Unmount" : "Mount")
                        
                        Button(action: openFolder) {
                            Image(systemName: "folder.fill")
                                .font(.system(size: 14))
                                .padding(8)
                                .background(isMounted ? .thinMaterial : .ultraThinMaterial)
                                .clipShape(Circle())
                                .opacity(isMounted ? 1.0 : 0.3)
                        }
                        .buttonStyle(.plain)
                        .disabled(!isMounted)
                        .help("Open in Finder")
                        
                        Button(action: onEdit) {
                            Image(systemName: "pencil")
                                .font(.system(size: 14))
                                .padding(8)
                                .background(.thinMaterial)
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .help("Edit")
                    }
                }
                
                // Address Row (Full width relative to content column)
                Text(server.urlString)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(server.urlString)
            }
            .padding(.top, 4) // Align top text with icon visually
        }
        .padding()
        .background(.regularMaterial) // Glass Card Body
        .cornerRadius(20)
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(.white.opacity(0.2), lineWidth: 1) // Edge Shine
        )
        .shadow(color: .black.opacity(0.15), radius: 10, x: 0, y: 5)
        .contentShape(Rectangle())
        .onTapGesture {
            if isMounted {
                openFolder()
            }
        }
        .onAppear {
            checkMountStatus()
        }
        .onReceive(networkPublisher) { fingerprint in
            handleNetworkChange(fingerprint)
        }
    }
    
    // Helper for Status Color
    private var statusColor: Color {
        if isMounted {
            return .green
        } else if mountStatus.contains("Waiting") || mountStatus.contains("Checking") || mountStatus.contains("Reconnecting") || mountStatus.contains("Connecting") {
            return .orange
        } else if mountStatus != "Idle" {
            return .red
        } else {
            return .secondary
        }
    }
    
    private var isConnecting: Bool {
        return mountStatus.contains("Connecting") || mountStatus.contains("Checking") || mountStatus.contains("Reconnecting")
    }
    
    // Logic remains identical, just copy pasting methods for completeness
    
    private func handleNetworkChange(_ fingerprint: NetworkFingerprint?) {
        if fingerprint == nil {
            isMounted = false
            mountStatus = "Waiting for Network..."
        } else {
            mountStatus = "Network changed, checking..."
             DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                 checkMountStatus()
             }
        }
    }
    
    private func checkMountStatus() {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let url = URL(string: server.urlString) else { return }
            if let path = MountingManager.shared.findExistingMountPath(for: url) {
                DispatchQueue.main.async {
                    isMounted = true
                    mountStatus = "Mounted at: \(path)"
                }
            } else {
                DispatchQueue.main.async {
                    isMounted = false
                    mountStatus = "Idle"
                }
            }
        }
    }

    private func openFolder() {
        DispatchQueue.global(qos: .userInitiated).async {
            if let url = URL(string: server.urlString),
               let path = MountingManager.shared.findExistingMountPath(for: url) {
                DispatchQueue.main.async {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
                }
            }
        }
    }

    private func toggleMount() {
        if isMounted {
            mountStatus = "Unmounting..."
            guard let url = URL(string: server.urlString),
                  let path = MountingManager.shared.findExistingMountPath(for: url) else {
                isMounted = false
                mountStatus = "Idle"
                return
            }
            MountingManager.shared.unmount(mountPath: path) { error in
                DispatchQueue.main.async {
                    if let error = error {
                        mountStatus = "Unmount Failed: \(error.localizedDescription)"
                    } else {
                        isMounted = false
                        mountStatus = "Idle"
                    }
                }
            }
        } else {
            mountStatus = "Connecting..."
            MountingManager.shared.mount(config: server) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let path):
                        isMounted = true
                        mountStatus = "Mounted at: \(path)"
                        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
                    case .failure(let error):
                        isMounted = false
                        mountStatus = "Error: \(error.localizedDescription)"
                        print("Error: \(error)")
                    }
                }
            }
        }
    }
}
