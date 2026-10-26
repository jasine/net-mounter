import SwiftUI
import Logging

private let logger = Logger(label: "ServerListView")

private struct ScrollContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct ServerListView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var autoMountService: AutoMountService
    
    @State private var showingAddSheet = false
    @State private var showingSettings = false
    @State private var showingDiscovery = false
    @State private var configurationError: String?
    @State private var editingServer: ServerConfig?
    @State private var scrollContentHeight: CGFloat = 0
    private let maxScrollHeight: CGFloat = 600
    private let minScrollHeight: CGFloat = 100

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

                    Button(action: { showingDiscovery = true }) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
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
                    VStack(spacing: 16) {
                        ForEach(appState.servers) { server in
                            ServerRow(server: server, onEdit: {
                                editingServer = server
                            }, onDelete: {
                                deleteServer(server)
                            }, onUpdatePins: { pins in
                                guard var updated = appState.servers.first(where: { $0.id == server.id }) else { return }
                                updated.pinnedFolders = pins
                                if case .failure(let error) = appState.updateServer(updated) {
                                    configurationError = error.localizedDescription
                                }
                            })
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top, 4)
                    .padding(.bottom)
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(key: ScrollContentHeightKey.self, value: geo.size.height)
                        }
                    )
                }
                .frame(height: scrollContentHeight > 0
                    ? min(max(scrollContentHeight, minScrollHeight), maxScrollHeight)
                    : nil)
                .onPreferenceChange(ScrollContentHeightKey.self) { height in
                    scrollContentHeight = height
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .sheet(isPresented: $showingAddSheet) {
            ServerDetailView()
        }
        .sheet(isPresented: $showingDiscovery) {
            DiscoveryView()
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        .sheet(item: $editingServer) { server in
            ServerDetailView(config: server)
        }
        .alert(String(localized: "Configuration update", bundle: .module), isPresented: Binding(
            get: { configurationError != nil }, set: { if !$0 { configurationError = nil } }
        )) {
            Button("OK", role: .cancel) { configurationError = nil }
        } message: { Text(configurationError ?? "") }
        // Ensure the hosting window (if any) allows this vibrancy
        .background(Color.clear)
    }

    private func deleteServer(_ server: ServerConfig) {
        guard !appState.isSavingServer, !(appState.serverOperations[server.id]?.isBusy ?? false) else {
            configurationError = String(localized: "An operation is in progress. Wait for it to finish, then try again.", bundle: .module)
            return
        }
        switch appState.removeServer(id: server.id) {
        case .failure(let error):
            configurationError = error.localizedDescription
        case .success:
            guard let keyID = server.keychainItemId else { return }
            appState.isSavingServer = true
            Task { @MainActor in
                defer { appState.isSavingServer = false }
                let deleted = await Task.detached { KeychainManager.shared.delete(account: keyID) }.value
                if !deleted {
                    configurationError = String(localized: "The server was removed, but its password could not be removed from Keychain.", bundle: .module)
                }
            }
        }
    }

}

struct ServerRow: View {
    let server: ServerConfig
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onUpdatePins: ([PinnedFolder]) -> Void
    @EnvironmentObject private var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var operation: ServerOperation { appState.serverOperations[server.id] ?? .idle }
    private var isMounted: Bool { operation.isMounted }
    private var currentMountPath: String? { operation.mountPath }
    @State private var animating = false
    @State private var showDeleteConfirm = false
    @State private var showCopied = false
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
                    .opacity(operation.isBusy ? 0.5 : 1.0)
                    .scaleEffect(animating && operation.isBusy && !reduceMotion ? 1.1 : 1.0)
                    .animation(animating && operation.isBusy && !reduceMotion ? Animation.easeInOut(duration: 0.8).repeatForever(autoreverses: true) : nil, value: operation.isBusy)
                    .onAppear { animating = true }
                    .onDisappear { animating = false }
            }
            .help(operation.summary) // Tooltip for detailed status
            
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
                        .disabled(operation.isBusy || appState.isSavingServer)
                        .accessibilityLabel(Text(isMounted ? "Unmount" : "Mount", bundle: .module))
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
                        .disabled(!isMounted || operation.isBusy)
                        .accessibilityLabel(Text("Open in Finder", bundle: .module))
                        .help("Open in Finder")
                        
                        Button {
                            if let url = server.shareURL {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(url.absoluteString, forType: .string)
                                showCopied = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                    showCopied = false
                                }
                            }
                        } label: {
                            Image(systemName: showCopied ? "checkmark" : "link")
                                .font(.system(size: 14))
                                .padding(8)
                                .background(.thinMaterial)
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .help("Copy Share Link")

                        Button(action: onEdit) {
                            Image(systemName: "pencil")
                                .font(.system(size: 14))
                                .padding(8)
                                .background(.thinMaterial)
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .disabled(operation.isBusy || appState.isSavingServer)
                        .accessibilityLabel(Text("Edit", bundle: .module))
                        .help("Edit")

                        Button(action: { showDeleteConfirm = true }) {
                            Image(systemName: "trash")
                                .font(.system(size: 14))
                                .padding(8)
                                .background(.thinMaterial)
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .disabled(operation.isBusy || appState.isSavingServer)
                        .accessibilityLabel(Text("Delete", bundle: .module))
                        .help("Delete")
                    }
                }
                
                // Address Row (Full width relative to content column)
                Text(server.urlString)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(server.urlString)

                HStack(spacing: 6) {
                    if operation.isBusy { ProgressView().controlSize(.mini) }
                    Text(operation.summary).font(.caption).foregroundColor(statusColor)
                }
                if let message = operation.errorMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundColor(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    HStack {
                        Button(action: toggleMount) { Text("Retry", bundle: .module) }
                        Button(action: onEdit) { Text("Edit", bundle: .module) }
                    }
                    .font(.caption)
                    .disabled(operation.isBusy || appState.isSavingServer)
                }

                if !server.pinnedFolders.isEmpty || isMounted {
                    Divider()
                    FlowLayout(spacing: 6) {
                        ForEach(server.pinnedFolders) { pin in
                            Button(action: { openPinnedFolder(pin) }) {
                                Label(pin.name, systemImage: "pin.fill")
                                    .font(.caption)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(.thinMaterial)
                                    .cornerRadius(8)
                            }
                            .buttonStyle(.plain)
                           .disabled(operation.isBusy)
                            .help(pin.subpath)
                            .contextMenu {
                                Button(role: .destructive) {
                                    var pins = server.pinnedFolders
                                    pins.removeAll { $0.id == pin.id }
                                    onUpdatePins(pins)
                                } label: {
                                    Label("Remove Pin", systemImage: "pin.slash")
                                }
                            }
                        }

                        if isMounted {
                            Button(action: addPinnedFolder) {
                                Image(systemName: "plus")
                                    .font(.caption)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(.ultraThinMaterial)
                                    .cornerRadius(8)
                            }
                            .buttonStyle(.plain)
                           .disabled(operation.isBusy || appState.isSavingServer)
                            .help("Pin a subfolder")
                        }
                    }
                }
            }
            .padding(.top, 4) // Align top text with icon visually
        }
        .padding()
        .background(.regularMaterial) // Glass Card Body
        .cornerRadius(20)
        .overlay(
            ZStack {
                RoundedRectangle(cornerRadius: 20)
                    .stroke(.white.opacity(0.2), lineWidth: 1) // Edge Shine
                if showCopied {
                    Text(String(localized: "Share link copied"))
                        .font(.caption)
                        .fontWeight(.medium)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.thickMaterial)
                        .cornerRadius(8)
                        .shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: showCopied)
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
        .onReceive(NotificationCenter.default.publisher(for: .mountStateDidChange)) { _ in
            checkMountStatus()
        }
        .alert("Delete Server", isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) { onDelete() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Are you sure you want to delete \"\(server.alias)\"?")
        }
    }
    
    private var statusColor: Color {
        if operation.errorMessage != nil { return .red }
        if operation.isBusy { return .orange }
        if isMounted { return .green }
        return .secondary
    }

    private func handleNetworkChange(_ fingerprint: NetworkFingerprint?) {
        checkMountStatus()
    }

    private func checkMountStatus() {
        guard let url = URL(string: server.urlString) else { return }
        let expected = operation
        let state = appState
        DispatchQueue.global(qos: .utility).async {
            let path = MountingManager.shared.findExistingMountPath(for: url)
            let inFlight = MountingManager.shared.isMountInFlight(server.id)
            DispatchQueue.main.async {
                guard state.servers.contains(where: { $0.id == server.id && $0.mountURLString == server.mountURLString }),
                      (state.serverOperations[server.id] ?? .idle) == expected else { return }
                state.serverOperations[server.id] = expected.refreshed(
                    mountPath: path,
                    hasNetwork: NetworkMonitor.shared.currentFingerprint != nil,
                    mountInFlight: inFlight
                )
            }
        }
    }

    private func openFolder() {
        guard !operation.isBusy, let path = currentMountPath else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }

    private func addPinnedFolder() {
        guard let root = currentMountPath,
              let pin = PinnedFolderPicker.pick(root: root) else { return }
        var pins = server.pinnedFolders
        pins.append(pin)
        onUpdatePins(pins)
    }

    private func openPinnedFolder(_ pin: PinnedFolder) {
        guard !operation.isBusy else { return }
        let subpath = pin.subpath.trimmingCharacters(in: CharacterSet(charactersIn: "/\\"))
        if let path = currentMountPath {
            let fullPath = (path as NSString).appendingPathComponent(subpath)
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: fullPath)
        } else {
            ensureMounted { path in
                let fullPath = (path as NSString).appendingPathComponent(subpath)
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: fullPath)
            }
        }
    }

    private func ensureMounted(then action: @escaping (String) -> Void) {
        guard !operation.isBusy, !appState.isSavingServer else { return }
        let state = appState
        state.serverOperations[server.id] = .connecting
        MountingManager.shared.mount(config: server) { result in
            DispatchQueue.main.async {
                guard let current = state.servers.first(where: { $0.id == server.id }) else { return }
                guard current.mountURLString == server.mountURLString else {
                    state.serverOperations[server.id] = .idle
                    return
                }
                switch result {
                case .success(let path):
                    state.serverOperations[server.id] = .mounted(path)
                    NotificationCenter.default.post(name: .mountStateDidChange, object: nil)
                    action(path)
                case .failure(let error):
                    state.serverOperations[server.id] = .failed(error.localizedDescription, mountPath: nil)
                    logger.error("Mount error: \(error.localizedDescription)")
                }
            }
        }
    }

    private func toggleMount() {
        guard !operation.isBusy, !appState.isSavingServer else { return }
        if let path = currentMountPath {
            let state = appState
            state.serverOperations[server.id] = .disconnecting(path)
            MountingManager.shared.unmount(mountPath: path) { error in
                DispatchQueue.main.async {
                    guard let current = state.servers.first(where: { $0.id == server.id }) else { return }
                    guard current.mountURLString == server.mountURLString else {
                        state.serverOperations[server.id] = .idle
                        return
                    }
                    if let error {
                        state.serverOperations[server.id] = .failed(error.localizedDescription, mountPath: path)
                    } else {
                        state.serverOperations[server.id] = .idle
                        NotificationCenter.default.post(name: .mountStateDidChange, object: nil)
                    }
                }
            }
        } else {
            ensureMounted { path in
                NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
            }
        }
    }

}

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        var height: CGFloat = 0
        for (i, row) in rows.enumerated() {
            let rowHeight = row.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
            height += rowHeight + (i > 0 ? spacing : 0)
        }
        return CGSize(width: proposal.width ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        var y = bounds.minY
        for (i, row) in rows.enumerated() {
            if i > 0 { y += spacing }
            var x = bounds.minX
            let rowHeight = row.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
            for subview in row {
                let size = subview.sizeThatFits(.unspecified)
                subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += rowHeight
        }
    }

    private func computeRows(proposal: ProposedViewSize, subviews: Subviews) -> [[LayoutSubviews.Element]] {
        guard !subviews.isEmpty else { return [] }
        let maxWidth = proposal.width ?? .infinity
        var rows: [[LayoutSubviews.Element]] = [[]]
        var currentWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentWidth + size.width > maxWidth && !rows[rows.count - 1].isEmpty {
                rows.append([])
                currentWidth = 0
            }
            rows[rows.count - 1].append(subview)
            currentWidth += size.width + spacing
        }
        return rows
    }
}

enum PinnedFolderPicker {
    static func pick(root: String) -> PinnedFolder? {
        let appDelegate = NSApp.delegate as? AppDelegate
        appDelegate?.preventPopoverClose = true
        defer { appDelegate?.preventPopoverClose = false }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: root)
        panel.message = "Choose a subfolder to pin"

        guard panel.runModal() == .OK, let selected = panel.url else { return nil }
        let rootPath = root.hasSuffix("/") ? root : root + "/"
        let subpath = selected.path.hasPrefix(rootPath)
            ? String(selected.path.dropFirst(rootPath.count))
            : selected.lastPathComponent
        return PinnedFolder(name: selected.lastPathComponent, subpath: subpath)
    }
}
