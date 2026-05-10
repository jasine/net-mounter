import SwiftUI

struct DiscoveryView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var appState: AppState
    @StateObject private var discoveryService = NetworkDiscoveryService()
    @State private var expandedServers: Set<UUID> = []

    var body: some View {
        ZStack {
            LiquidGlassBackground()
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                HStack {
                    Text("Discover Servers")
                        .font(.system(.title2, design: .rounded))
                        .fontWeight(.bold)
                        .foregroundColor(.primary)
                    Spacer()

                    if discoveryService.isScanning {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.trailing, 4)
                    }

                    Button("Done") {
                        dismiss()
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.thinMaterial)
                    .cornerRadius(12)
                    .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)
                }
                .padding()

                // Content
                ScrollView {
                    LazyVStack(spacing: 12) {
                        if discoveryService.servers.isEmpty && discoveryService.isScanning {
                            VStack(spacing: 12) {
                                ProgressView()
                                Text("Scanning...")
                                    .font(.callout)
                                    .foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                        } else if discoveryService.servers.isEmpty && !discoveryService.isScanning {
                            Text("No servers found")
                                .font(.callout)
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 40)
                        } else {
                            ForEach(discoveryService.servers) { server in
                                ServerDiscoveryCard(
                                    server: server,
                                    shares: discoveryService.shares[server.id] ?? [],
                                    isEnumerating: discoveryService.isEnumeratingShares[server.id] ?? false,
                                    isExpanded: expandedServers.contains(server.id),
                                    isAlreadyAdded: { shareName in
                                        isShareAlreadyAdded(host: server.host, sharePath: shareName)
                                    },
                                    onToggleExpand: {
                                        toggleExpand(server)
                                    },
                                    onAddShare: { shareName in
                                        addServer(from: server, sharePath: shareName)
                                    },
                                    onAddServer: {
                                        addServer(from: server, sharePath: "")
                                    }
                                )
                            }
                        }
                    }
                    .padding()
                }
            }
        }
        .frame(width: 380, height: 480)
        .onAppear {
            discoveryService.startScan()
        }
        .onDisappear {
            discoveryService.stopScan()
        }
    }

    private func toggleExpand(_ server: DiscoveredServer) {
        if expandedServers.contains(server.id) {
            expandedServers.remove(server.id)
        } else {
            expandedServers.insert(server.id)
            // Trigger share enumeration if not yet loaded
            if discoveryService.shares[server.id] == nil {
                discoveryService.enumerateShares(for: server)
            }
        }
    }

    private func isShareAlreadyAdded(host: String, sharePath: String) -> Bool {
        appState.servers.contains { existing in
            existing.hostname.lowercased() == host.lowercased() &&
            existing.sharePath.lowercased() == sharePath.lowercased()
        }
    }

    private func addServer(from server: DiscoveredServer, sharePath: String) {
        let lastComponent = URL(fileURLWithPath: sharePath).lastPathComponent
        let alias = sharePath.isEmpty ? server.name : lastComponent
        var rules: [AutoMountRule] = []
        if let fingerprint = NetworkMonitor.shared.currentFingerprint {
            rules.append(AutoMountRule(fingerprint: fingerprint))
        }
        let config = ServerConfig(
            alias: alias,
            serverProtocol: server.protocolType,
            hostname: server.host,
            sharePath: sharePath,
            autoMountRules: rules
        )
        appState.addServer(config)

        // Auto-mount immediately (NFS excluded — requires auth dialog that
        // conflicts with the discovery sheet)
        if server.protocolType != .nfs {
            MountingManager.shared.mount(config: config) { _ in }
        }
    }
}

// MARK: - Server Discovery Card

private struct ServerDiscoveryCard: View {
    let server: DiscoveredServer
    let shares: [DiscoveredShare]
    let isEnumerating: Bool
    let isExpanded: Bool
    let isAlreadyAdded: (String) -> Bool
    let onToggleExpand: () -> Void
    let onAddShare: (String) -> Void
    let onAddServer: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Server header row
            Button(action: onToggleExpand) {
                HStack(spacing: 10) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 16)

                    Image(systemName: "server.rack")
                        .font(.system(size: 16))
                        .foregroundColor(.cyan)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(server.name)
                            .font(.system(.body, design: .rounded))
                            .fontWeight(.semibold)
                            .foregroundColor(.primary)
                            .lineLimit(1)
                        Text("\(server.protocolType.displayName) - \(server.host)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }

                    Spacer()

                    // Add server button (no share path)
                    if isAlreadyAdded("") {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundColor(.green)
                    } else {
                        Button(action: onAddServer) {
                            Image(systemName: "plus")
                                .font(.system(size: 14, weight: .medium))
                                .padding(6)
                                .background(.thinMaterial)
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .help("Add server")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .buttonStyle(.plain)

            // Expanded share list
            if isExpanded {
                Divider()
                    .padding(.horizontal, 12)

                if isEnumerating {
                    HStack {
                        Spacer()
                        ProgressView()
                            .controlSize(.small)
                        Text("Scanning...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .padding(.vertical, 10)
                } else if shares.isEmpty {
                    Text("No shares found")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                } else {
                    VStack(spacing: 0) {
                        ForEach(shares) { share in
                            ShareRow(
                                name: share.name,
                                isAdded: isAlreadyAdded(share.name),
                                onAdd: { onAddShare(share.name) }
                            )
                        }
                    }
                }
            }
        }
        .background(.regularMaterial)
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(.white.opacity(0.2), lineWidth: 1)
        )
    }
}

// MARK: - Share Row

private struct ShareRow: View {
    let name: String
    let isAdded: Bool
    let onAdd: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.fill")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .padding(.leading, 38) // Indent to align with server name

            Text(name)
                .font(.system(.callout, design: .rounded))
                .foregroundColor(.primary)
                .lineLimit(1)

            Spacer()

            if isAdded {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.green)
            } else {
                Button(action: onAdd) {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .medium))
                        .padding(5)
                        .background(.thinMaterial)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Add share")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
