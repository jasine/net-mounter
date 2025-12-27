import Foundation
import Combine

class AutoMountService: ObservableObject {
    private var appState: AppState
    private var networkMonitor: NetworkMonitor
    private var cancellables = Set<AnyCancellable>()
    
    // Track mounting status to avoid repetitive mount attempts
    @Published var pendingMounts: Set<UUID> = []
    
    init(appState: AppState, networkMonitor: NetworkMonitor = .shared) {
        self.appState = appState
        self.networkMonitor = networkMonitor
        
        setupBindings()
    }
    
    private func setupBindings() {
        // Watch for network changes
        networkMonitor.$currentFingerprint
            .compactMap { $0 }
            .debounce(for: .seconds(2), scheduler: DispatchQueue.main) // Wait for network to settle
            .sink { [weak self] fingerprint in
                self?.evaluateAutoMount(for: fingerprint)
            }
            .store(in: &cancellables)
    }
    
    func evaluateAutoMount(for fingerprint: NetworkFingerprint) {
        print("Evaluating auto-mount for fingerprint: \(fingerprint)")
        
        for server in appState.servers {
            // Check if this server has a matching rule
            if server.autoMountRules.contains(where: { $0.enabled && $0.fingerprint.matches(fingerprint) }) {
                // Trigger mount
                attemptMount(server)
            }
        }
    }
    
    private func attemptMount(_ server: ServerConfig) {
        print("Attempting auto-mount for: \(server.alias)")
        
        // Verify connectivity first
        ConnectionTester.shared.checkReachability(host: server.hostname) { result in
            switch result {
            case .success(true):
                print("Server \(server.hostname) is reachable. Mounting...")
                MountingManager.shared.mount(config: server) { mountResult in
                    switch mountResult {
                    case .success(let path):
                        print("Successfully mounted \(server.alias) at \(path)")
                    case .failure(let error):
                        print("Failed to mount \(server.alias): \(error)")
                    }
                }
            case .success(false), .failure:
                 print("Server \(server.hostname) not reachable. Skipping.")
            }
        }
    }
}
