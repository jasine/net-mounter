import Foundation
import Combine
import Logging

private let logger = Logger(label: "AppState")

extension Notification.Name {
    /// Posted when a mount/unmount completes so the UI and menu-bar icon can
    /// refresh immediately instead of waiting for their poll timers.
    static let mountStateDidChange = Notification.Name("NetMounter.mountStateDidChange")
}

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
    @Published var isSavingServer = false
    @Published var serverOperations: [UUID: ServerOperation] = [:]
    
    private let configURL: URL
    
    init(configURL: URL? = nil) {
        if let configURL {
            self.configURL = configURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let appDir = appSupport.appendingPathComponent("NetMounter")
            try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
            self.configURL = appDir.appendingPathComponent("config.json")
        }
        loadConfig()
    }

    @discardableResult
    func addServer(_ config: ServerConfig) -> Result<Void, Error> {
        saveConfig(servers + [config])
    }

    @discardableResult
    func removeServer(id: UUID) -> Result<Void, Error> {
        let result = saveConfig(servers.filter { $0.id != id })
        if case .success = result { serverOperations.removeValue(forKey: id) }
        return result
    }

    @discardableResult
    func updateServer(_ config: ServerConfig) -> Result<Void, Error> {
        guard let index = servers.firstIndex(where: { $0.id == config.id }) else {
            return .failure(CocoaError(.fileNoSuchFile))
        }
        let targetChanged = servers[index].mountURLString != config.mountURLString
        var updated = servers
        updated[index] = config
        let result = saveConfig(updated)
        if case .success = result, targetChanged { serverOperations[config.id] = .idle }
        return result
    }

    private func saveConfig(_ candidate: [ServerConfig]) -> Result<Void, Error> {
        let diagnostic = DiagnosticsService.shared.begin(.configSave)
        do {
            let data = try JSONEncoder().encode(candidate)
            try data.write(to: configURL, options: .atomic)
            servers = candidate
            diagnostic.finish()
            return .success(())
        } catch {
            diagnostic.finish(error: error)
            logger.error("Failed to save config: \(error.localizedDescription)")
            return .failure(error)
        }
    }

    static func computeMountStatus(servers: [ServerConfig], fingerprint: NetworkFingerprint?) -> MountStatus {
        let matchingServers = servers.filter { server in
            server.shouldAutoMount(for: fingerprint, isVPN: NetworkMonitor.shared.isVPNRouted(host: server.hostname))
        }

        guard !matchingServers.isEmpty else { return .idle }

        let allMounted = matchingServers.allSatisfy { server in
            guard let url = URL(string: server.urlString) else { return false }
            return MountingManager.shared.findExistingMountPath(for: url) != nil
        }

        return allMounted ? .allConnected : .hasFailed
    }

    private func loadConfig() {
        let diagnostic = DiagnosticsService.shared.begin(.configLoad)
        do {
            let data = try Data(contentsOf: configURL)
            servers = try JSONDecoder().decode([ServerConfig].self, from: data)
            diagnostic.finish()
        } catch {
            let nsError = error as NSError
            // Missing config is normal on the first launch. Corruption/permission errors are not.
            let missing = (nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoSuchFileError)
                || (nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ENOENT))
            diagnostic.finish(error: missing ? nil : error)
            logger.info("No existing config or failed to load: \(error.localizedDescription)")
        }
    }
}
