import Foundation
import Combine

class AppState: ObservableObject {
    @Published var servers: [ServerConfig] = []
    
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
            print("Failed to save config: \(error)")
        }
    }
    
    private func loadConfig() {
        do {
            let data = try Data(contentsOf: configURL)
            servers = try JSONDecoder().decode([ServerConfig].self, from: data)
        } catch {
            print("No existing config or failed to load: \(error)")
        }
    }
}
