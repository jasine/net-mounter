import Foundation
import Combine
import os

private let logger = Logger(subsystem: "com.netmounter.app", category: "AppState")

enum MountStatus {
    case idle
    case allConnected
    case hasFailed

    var iconName: String {
        switch self {
        case .idle: return "externaldrive.badge.wifi"
        case .allConnected: return "externaldrive.fill.badge.checkmark"
        case .hasFailed: return "externaldrive.badge.exclamationmark"
        }
    }
}

class AppState: ObservableObject {
    @Published var servers: [ServerConfig] = []
    @Published var isUIVisible: Bool = false
    
    private let configURL: URL
    
    init() {
        // Setup config persistence path
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("NetMounter")
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        configURL = appDir.appendingPathComponent("config.json")
        
        loadConfig()
    }
    
    func addServer(_ config: ServerConfig) {
        servers.append(config)
        saveConfig()
    }
    
    func removeServer(id: UUID) {
        servers.removeAll { $0.id == id }
        saveConfig()
    }
    
    func updateServer(_ config: ServerConfig) {
        if let index = servers.firstIndex(where: { $0.id == config.id }) {
            servers[index] = config
            saveConfig()
        }
    }
    
    private func saveConfig() {
        do {
            let data = try JSONEncoder().encode(servers)
            try data.write(to: configURL)
        } catch {
            logger.error("Failed to save config: \(error.localizedDescription, privacy: .public)")
        }
    }
    
    static func computeMountStatus(servers: [ServerConfig], fingerprint: NetworkFingerprint?) -> MountStatus {
        let matchingServers = servers.filter { server in
            guard server.autoMountRules.contains(where: { $0.enabled }) else { return false }
            let fingerprintMatch = fingerprint.map { fp in
                server.autoMountRules.contains { $0.enabled && $0.fingerprint.matches(fp) }
            } ?? false
            let vpnMatch = NetworkMonitor.shared.isVPNRouted(host: server.hostname)
            return fingerprintMatch || vpnMatch
        }

        guard !matchingServers.isEmpty else { return .idle }

        let allMounted = matchingServers.allSatisfy { server in
            guard let url = URL(string: server.urlString) else { return false }
            return MountingManager.shared.findExistingMountPath(for: url) != nil
        }

        return allMounted ? .allConnected : .hasFailed
    }

    private func loadConfig() {
        do {
            let data = try Data(contentsOf: configURL)
            servers = try JSONDecoder().decode([ServerConfig].self, from: data)
        } catch {
            logger.info("No existing config or failed to load: \(error.localizedDescription, privacy: .public)")
        }
    }
}
