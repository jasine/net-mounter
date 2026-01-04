import Foundation
import Combine

class AutoMountService: ObservableObject {
    private var appState: AppState
    private var networkMonitor: NetworkMonitor
    private var cancellables = Set<AnyCancellable>()
    
    // Track mounting status to avoid repetitive mount attempts
    @Published var pendingMounts: Set<UUID> = []
    
    // Store pending retry work items so we can cancel them if network changes
    private var retryWorkItems: [UUID: DispatchWorkItem] = [:]
    
    init(appState: AppState, networkMonitor: NetworkMonitor = .shared) {
        self.appState = appState
        self.networkMonitor = networkMonitor
        
        setupBindings()
    }
    
    private func setupBindings() {
        // Watch for network changes
        networkMonitor.$currentFingerprint
            .compactMap { $0 }
            .removeDuplicates()
            .debounce(for: .seconds(2), scheduler: DispatchQueue.main) // Wait for network to settle
            .sink { [weak self] fingerprint in
                self?.evaluateAutoMount(for: fingerprint)
            }
            .store(in: &cancellables)
    }
    
    func evaluateAutoMount(for fingerprint: NetworkFingerprint) {
        print("Evaluating auto-mount for fingerprint: \(fingerprint)")
        
        // Cancel all pending retries as the network environment has changed
        cancelAllRetries()
        
        for server in appState.servers {
            // Check if this server has a matching rule
            if server.autoMountRules.contains(where: { $0.enabled && $0.fingerprint.matches(fingerprint) }) {
                // Trigger mount
                attemptMount(server)
            }
        }
    }
    
    private func attemptMount(_ server: ServerConfig, retryCount: Int = 0) {
        // If this is a fresh attempt (retryCount == 0), cancel any existing retry for this server
        // to avoid double-mounting if evaluateAutoMount is called rapidly (though debounced).
        if retryCount == 0 {
            cancelRetry(for: server)
        }
        
        print("Attempting auto-mount for: \(server.alias) (Attempt \(retryCount + 1))")
        
        // Verify connectivity first
        ConnectionTester.shared.checkReachability(host: server.hostname) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(true):
                    print("Server \(server.hostname) is reachable. Mounting...")
                    MountingManager.shared.mount(config: server) { mountResult in
                        switch mountResult {
                        case .success(let path):
                            print("Successfully mounted \(server.alias) at \(path)")
                            // Success, no need to retry
                        case .failure(let error):
                            print("Failed to mount \(server.alias): \(error)")
                            self?.scheduleRetry(for: server, currentRetryCount: retryCount)
                        }
                    }
                case .success(false), .failure:
                    print("Server \(server.hostname) not reachable. Skipping.")
                    self?.scheduleRetry(for: server, currentRetryCount: retryCount)
                }
            }
        }
    }
    
    private func scheduleRetry(for server: ServerConfig, currentRetryCount: Int) {
        let maxRetries = 5
        guard currentRetryCount < maxRetries else {
            print("Max retries reached for \(server.alias). Giving up.")
            return
        }
        
        let delay: TimeInterval = 5.0
        print("Scheduling retry for \(server.alias) in \(delay) seconds...")
        
        let workItem = DispatchWorkItem { [weak self] in
            self?.attemptMount(server, retryCount: currentRetryCount + 1)
        }
        
        retryWorkItems[server.id] = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }
    
    private func cancelRetry(for server: ServerConfig) {
        if let item = retryWorkItems[server.id] {
            item.cancel()
            retryWorkItems.removeValue(forKey: server.id)
        }
    }
    
    private func cancelAllRetries() {
        for item in retryWorkItems.values {
            item.cancel()
        }
        retryWorkItems.removeAll()
    }
}
