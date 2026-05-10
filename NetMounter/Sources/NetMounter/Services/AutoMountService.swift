import Foundation
import Combine
import os

private let logger = Logger(subsystem: "com.netmounter.app", category: "AutoMount")

class AutoMountService: ObservableObject {
    private var appState: AppState
    private var networkMonitor: NetworkMonitor
    private var cancellables = Set<AnyCancellable>()

    // Store pending retry work items so we can cancel them if network changes
    private var retryWorkItems: [UUID: DispatchWorkItem] = [:]
    
    // Timer for periodic health checks
    private var healthCheckTimer: AnyCancellable?
    
    init(appState: AppState, networkMonitor: NetworkMonitor = .shared) {
        self.appState = appState
        self.networkMonitor = networkMonitor
        
        setupBindings()
        setupHealthCheckTimer()
    }
    
    private func setupHealthCheckTimer() {
        // Run health check every 5 minutes
        healthCheckTimer = Timer.publish(every: 300, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.performPeriodicHealthCheck()
            }
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
        logger.info("Evaluating auto-mount for fingerprint: \(String(describing: fingerprint), privacy: .public)")
        
        // Cancel all pending retries as the network environment has changed
        cancelAllRetries()
        
        for server in appState.servers {
            // Check if this server has a matching rule
            if server.autoMountRules.contains(where: { $0.enabled && $0.fingerprint.matches(fingerprint) }) {
                // If already mounted, skip
                guard let url = URL(string: server.urlString) else { continue }
                if let path = MountingManager.shared.findExistingMountPath(for: url) {
                     logger.debug("Server \(server.alias, privacy: .public) already mounted at \(path, privacy: .public). Skipping.")
                     continue
                }
                
                // Trigger mount
                attemptMount(server)
            }
        }
    }
    
    private func performPeriodicHealthCheck() {
        guard let currentFingerprint = networkMonitor.currentFingerprint else { 
            logger.debug("No current network fingerprint available for periodic check.")
            return 
        }
        
        logger.info("Starting periodic health check for servers...")
        
        for server in appState.servers {
            // Check if this server has a matching rule for current network
            if server.autoMountRules.contains(where: { $0.enabled && $0.fingerprint.matches(currentFingerprint) }) {
                
                guard let serverURL = URL(string: server.urlString) else { continue }
                if let path = MountingManager.shared.findExistingMountPath(for: serverURL) {
                    if MountingManager.shared.isMountAlive(path) {
                        logger.debug("Periodic check: \(server.alias, privacy: .public) alive at \(path, privacy: .public).")
                    } else {
                        logger.warning("Periodic check: \(server.alias, privacy: .public) is zombie at \(path, privacy: .public). Recovering...")
                        MountingManager.shared.forceUnmount(path: path)
                        NotificationService.shared.notifyZombieHealed(server: server)
                        attemptMount(server, retryCount: 0)
                    }
                } else {
                    logger.warning("Periodic check: \(server.alias, privacy: .public) should be mounted but is NOT. Recovering...")
                    // Reset retry count for periodic check to give it a fresh chance
                    attemptMount(server, retryCount: 0)
                }
            }
        }
    }
    
    private func attemptMount(_ server: ServerConfig, retryCount: Int = 0) {
        // If this is a fresh attempt (retryCount == 0), cancel any existing retry for this server
        // to avoid double-mounting if evaluateAutoMount is called rapidly (though debounced).
        if retryCount == 0 {
            cancelRetry(for: server)
        }
        
        logger.info("Auto-mount \(server.alias, privacy: .public) attempt \(retryCount + 1)")
        
        // Verify connectivity first
        ConnectionTester.shared.checkReachability(host: server.hostname, port: server.serverProtocol.defaultPort) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(true):
                    logger.info("\(server.hostname, privacy: .public) reachable. Mounting...")
                    MountingManager.shared.mount(config: server) { mountResult in
                        switch mountResult {
                        case .success(let path):
                            logger.info("Mounted \(server.alias, privacy: .public) at \(path, privacy: .public)")
                            // Success, no need to retry
                        case .failure(let error):
                            logger.error("Failed to mount \(server.alias, privacy: .public): \(error.localizedDescription, privacy: .public)")
                            self?.scheduleRetry(for: server, currentRetryCount: retryCount)
                        }
                    }
                case .success(false), .failure:
                    logger.debug("\(server.hostname, privacy: .public) not reachable. Skipping.")
                    self?.scheduleRetry(for: server, currentRetryCount: retryCount)
                }
            }
        }
    }
    
    private func scheduleRetry(for server: ServerConfig, currentRetryCount: Int) {
        let maxRetries = 5
        guard currentRetryCount < maxRetries else {
            logger.warning("Max retries reached for \(server.alias, privacy: .public). Giving up.")
            NotificationService.shared.notifyMountFailed(server: server)
            return
        }
        
        let delay: TimeInterval = 5.0
        logger.debug("Scheduling retry for \(server.alias, privacy: .public) in \(delay)s...")
        
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
