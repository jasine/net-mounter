import Foundation
import Combine
import Logging

private let logger = Logger(label: "AutoMount")

class AutoMountService: ObservableObject {
    private var appState: AppState
    private var networkMonitor: NetworkMonitor
    private var cancellables = Set<AnyCancellable>()

    // Store pending retry work items so we can cancel them if network changes
    private var retryWorkItems: [UUID: DispatchWorkItem] = [:]

    // Track servers mounted via VPN route so we can unmount on VPN disconnect
    private var vpnMountedServerIDs: Set<UUID> = []

    // Dedup: avoid double-evaluation when SleepWakeManager and subscription both fire
    private var lastEvaluation: (fingerprint: NetworkFingerprint, uptime: TimeInterval)?

    // Track WOL polling per hostname to avoid duplicate magic packets
    private var wolPendingServers: [String: [ServerConfig]] = [:]
    private var wolPollTimers: [String: DispatchWorkItem] = [:]

    // Hostnames where MAC resolution already failed — avoid repeated arp spawns
    private var macResolutionFailed: Set<String> = []

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
        let now = ProcessInfo.processInfo.systemUptime
        if let last = lastEvaluation, last.fingerprint == fingerprint, now - last.uptime < 5.0 {
            logger.debug("Skipping duplicate evaluation for same fingerprint")
            return
        }
        lastEvaluation = (fingerprint, now)

        logger.info("Evaluating auto-mount for fingerprint: \(String(describing: fingerprint))")

        // Cancel all pending retries as the network environment has changed
        cancelAllRetries()

        let servers = appState.servers.filter { $0.hasEnabledAutoMountRules }
        guard !servers.isEmpty else { return }

        // Resolve VPN routes on background thread to avoid blocking UI
        let hostnames = servers.map { $0.hostname }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            var vpnResults: [String: Bool] = [:]
            for host in hostnames {
                vpnResults[host] = self.networkMonitor.isVPNRouted(host: host)
            }
            DispatchQueue.main.async {
                self.processAutoMount(servers: servers, fingerprint: fingerprint, vpnResults: vpnResults)
            }
        }
    }

    private func processAutoMount(servers: [ServerConfig], fingerprint: NetworkFingerprint, vpnResults: [String: Bool]) {
        vpnMountedServerIDs.formIntersection(Set(servers.map(\.id)))

        for server in servers {
            guard let url = URL(string: server.urlString) else { continue }

            let isVPN = vpnResults[server.hostname] ?? false

            if server.shouldAutoMount(for: fingerprint, isVPN: isVPN) {
                if let path = MountingManager.shared.findExistingMountPath(for: url) {
                    logger.debug("Server \(server.alias) already mounted at \(path). Skipping.")
                    if isVPN { vpnMountedServerIDs.insert(server.id) }
                    continue
                }
                if isVPN { vpnMountedServerIDs.insert(server.id) }
                attemptMount(server)
            } else if !isVPN && vpnMountedServerIDs.contains(server.id) {
                vpnMountedServerIDs.remove(server.id)
                if let path = MountingManager.shared.findExistingMountPath(for: url) {
                    logger.info("VPN disconnected, unmounting \(server.alias)")
                    MountingManager.shared.unmount(mountPath: path) { _ in }
                }
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
            if server.shouldAutoMount(for: currentFingerprint, isVPN: networkMonitor.isVPNRouted(host: server.hostname)) {
                
                guard let serverURL = URL(string: server.urlString) else { continue }
                if let path = MountingManager.shared.findExistingMountPath(for: serverURL) {
                    if MountingManager.shared.isMountAlive(path) {
                        logger.debug("Periodic check: \(server.alias) alive at \(path).")
                    } else {
                        logger.warning("Periodic check: \(server.alias) is zombie at \(path). Recovering...")
                        MountingManager.shared.forceUnmount(path: path)
                        attemptMount(server, retryCount: 0, onSuccess: {
                            NotificationService.shared.notifyZombieHealed(server: server)
                        })
                    }
                } else {
                    logger.warning("Periodic check: \(server.alias) should be mounted but is NOT. Recovering...")
                    // Reset retry count for periodic check to give it a fresh chance
                    attemptMount(server, retryCount: 0)
                }
            }
        }
    }
    
    private func attemptMount(_ server: ServerConfig, retryCount: Int = 0, onSuccess: (() -> Void)? = nil) {
        // If this is a fresh attempt (retryCount == 0), cancel any existing retry for this server
        // to avoid double-mounting if evaluateAutoMount is called rapidly (though debounced).
        if retryCount == 0 {
            cancelRetry(for: server)
        }
        
        logger.info("Auto-mount \(server.alias) attempt \(retryCount + 1)")
        
        // Verify connectivity first
        ConnectionTester.shared.checkReachability(host: server.hostname, port: server.serverProtocol.defaultPort) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(true):
                    logger.info("\(server.hostname) reachable. Mounting...")
                    MountingManager.shared.mount(config: server, silent: retryCount > 0) { mountResult in
                        switch mountResult {
                        case .success(let path):
                            logger.info("Mounted \(server.alias) at \(path)")
                            NotificationService.shared.notifyMountSucceeded(server: server)
                            self?.learnMACIfNeeded(for: server)
                            onSuccess?()
                        case .failure(let error):
                            logger.error("Failed to mount \(server.alias): \(error.localizedDescription)")
                            self?.scheduleRetry(for: server, currentRetryCount: retryCount)
                        }
                    }
                case .success(false), .failure:
                    logger.debug("\(server.hostname) not reachable.")
                    if retryCount == 0 && server.wolEnabled && server.wolMACAddress != nil {
                        self?.attemptWOLAndPoll(server)
                    } else {
                        self?.scheduleRetry(for: server, currentRetryCount: retryCount)
                    }
                }
            }
        }
    }
    
    private func scheduleRetry(for server: ServerConfig, currentRetryCount: Int) {
        // NFS mounts require root — silent retries (without admin dialog) always fail
        if server.serverProtocol == .nfs {
            logger.info("NFS mount requires admin privileges, skipping silent retries for \(server.alias)")
            NotificationService.shared.notifyMountFailed(server: server)
            return
        }

        let maxRetries = 5
        guard currentRetryCount < maxRetries else {
            logger.warning("Max retries reached for \(server.alias). Giving up.")
            NotificationService.shared.notifyMountFailed(server: server)
            return
        }
        
        let delay: TimeInterval = 2.0 * pow(2.0, Double(currentRetryCount))
        logger.debug("Scheduling retry for \(server.alias) in \(delay)s...")
        
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

        for item in wolPollTimers.values {
            item.cancel()
        }
        wolPollTimers.removeAll()
        wolPendingServers.removeAll()
        macResolutionFailed.removeAll()
    }

    // MARK: - Wake-on-LAN

    private func learnMACIfNeeded(for server: ServerConfig) {
        guard server.wolMACAddress == nil,
              !macResolutionFailed.contains(server.hostname) else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let mac = WOLService.shared.resolveMAC(for: server.hostname) else {
                DispatchQueue.main.async { self?.macResolutionFailed.insert(server.hostname) }
                return
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                if var updated = self.appState.servers.first(where: { $0.id == server.id }),
                   updated.wolMACAddress == nil {
                    updated.wolMACAddress = mac
                    self.appState.updateServer(updated)
                    logger.info("Auto-learned MAC \(mac) for \(server.alias)")
                }
            }
        }
    }

    private func attemptWOLAndPoll(_ server: ServerConfig) {
        let hostname = server.hostname

        if wolPendingServers[hostname] != nil {
            wolPendingServers[hostname]?.append(server)
            logger.debug("WOL poll already active for \(hostname), queued \(server.alias)")
            return
        }

        wolPendingServers[hostname] = [server]

        guard let mac = server.wolMACAddress else {
            logger.warning("WOL enabled but no MAC for \(server.alias), skipping")
            drainWOLQueue(hostname: hostname, reachable: false)
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try WOLService.shared.wake(
                    macAddress: mac,
                    broadcastAddress: server.wolBroadcastAddress ?? "255.255.255.255",
                    port: server.wolPort
                )
                logger.info("WOL sent for \(server.alias) (\(mac))")
                DispatchQueue.main.async {
                    self?.pollReachability(hostname: hostname, port: server.serverProtocol.defaultPort,
                                           interval: 3.0, remaining: 60.0)
                }
            } catch {
                logger.error("WOL failed for \(server.alias): \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self?.drainWOLQueue(hostname: hostname, reachable: false)
                }
            }
        }
    }

    private func pollReachability(hostname: String, port: UInt16,
                                  interval: TimeInterval, remaining: TimeInterval) {
        guard remaining > 0 else {
            logger.warning("WOL poll timeout for \(hostname)")
            if let servers = wolPendingServers[hostname] {
                for s in servers {
                    NotificationService.shared.notifyWOLFailed(server: s)
                }
            }
            drainWOLQueue(hostname: hostname, reachable: false)
            return
        }

        let work = DispatchWorkItem { [weak self] in
            ConnectionTester.shared.checkReachability(host: hostname, port: port) { result in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    switch result {
                    case .success(true):
                        logger.info("\(hostname) became reachable after WOL")
                        self.drainWOLQueue(hostname: hostname, reachable: true)
                    case .success(false), .failure:
                        self.pollReachability(hostname: hostname, port: port,
                                              interval: interval, remaining: remaining - interval)
                    }
                }
            }
        }
        wolPollTimers[hostname] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: work)
    }

    private func drainWOLQueue(hostname: String, reachable: Bool) {
        let servers = wolPendingServers.removeValue(forKey: hostname) ?? []
        wolPollTimers.removeValue(forKey: hostname)

        if reachable {
            for server in servers {
                attemptMount(server, retryCount: 1)
            }
        } else {
            for server in servers {
                scheduleRetry(for: server, currentRetryCount: 1)
            }
        }
    }
}
