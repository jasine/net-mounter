import Foundation
import Network
import CoreWLAN
import Combine
import os

private let logger = Logger(subsystem: "com.netmounter.app", category: "NetworkMonitor")

class NetworkMonitor: ObservableObject {
    static let shared = NetworkMonitor()
    
    @Published var currentPath: NWPath?
    @Published var currentFingerprint: NetworkFingerprint?
    
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "NetworkMonitor")
    private var cancellables = Set<AnyCancellable>()
    private let pathSubject = PassthroughSubject<NWPath, Never>()
    
    init() {
        startMonitoring()
    }
    
    func startMonitoring() {
        // Setup the pipeline:
        // 1. Receive path update
        // 2. Debounce to avoid rapid fluctuations (e.g. signal changes)
        // 3. Process on background queue (get SSID, etc.)
        // 4. Update Main properties only if changed
        
        pathSubject
            .debounce(for: .milliseconds(500), scheduler: queue)
            .sink { [weak self] path in
                self?.processPathUpdate(path)
            }
            .store(in: &cancellables)
            
        monitor.pathUpdateHandler = { [weak self] path in
            self?.pathSubject.send(path)
        }
        monitor.start(queue: queue)
    }
    
    private func processPathUpdate(_ path: NWPath) {
        var ssid: String? = nil
        let bssid: String? = nil
        var interfaceType: InterfaceType = .other

        // This runs on 'queue' (background), so XPC calls here won't block Main
        if path.usesInterfaceType(.wifi) {
            interfaceType = .wifi
            // Try to get SSID
            let client = CWWiFiClient.shared()
            if let interface = client.interface() {
                ssid = interface.ssid()
                // bssid = interface.bssid() // Ignore BSSID to avoid flapping when roaming
            }
        } else if path.usesInterfaceType(.wiredEthernet) {
            interfaceType = .wired
        }

        // If we are disconnected
        if path.status != .satisfied {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.currentPath = path
                if self.currentFingerprint != nil {
                    self.currentFingerprint = nil
                    logger.info("Network disconnected")
                }
            }
            return
        }

        // Always resolve gateway MAC as fallback when SSID is unavailable.
        if ssid == nil {
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let gatewayMac = Self.getDefaultGatewayMAC()
                let fingerprint = NetworkFingerprint(
                    ssid: ssid, bssid: bssid,
                    gatewayMac: gatewayMac, interfaceType: interfaceType
                )
                self?.publishFingerprint(fingerprint, path: path)
            }
        } else {
            let fingerprint = NetworkFingerprint(
                ssid: ssid, bssid: bssid,
                gatewayMac: nil, interfaceType: interfaceType
            )
            publishFingerprint(fingerprint, path: path)
        }
    }

    private func publishFingerprint(_ fingerprint: NetworkFingerprint, path: NWPath) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.currentPath = path
            if self.currentFingerprint != fingerprint {
                self.currentFingerprint = fingerprint
                logger.info("Network changed: \(String(describing: self.currentFingerprint), privacy: .public)")
            }
        }
    }

    private static func resolveCommand(_ candidates: [String]) -> String? {
        candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    /// Resolve the default gateway's MAC address via `arp` for network fingerprinting.
    private static func getDefaultGatewayMAC() -> String? {
        guard let routePath = resolveCommand(["/sbin/route", "/usr/sbin/route"]) else { return nil }
        guard let arpPath = resolveCommand(["/usr/sbin/arp", "/sbin/arp"]) else { return nil }

        guard let gatewayIP = runCommand(routePath, arguments: ["-n", "get", "default"])
            .components(separatedBy: "\n")
            .first(where: { $0.contains("gateway:") })?
            .components(separatedBy: ":")
            .last?
            .trimmingCharacters(in: .whitespaces),
              !gatewayIP.isEmpty else { return nil }

        // 2. Resolve MAC via `arp`
        guard let arpLine = runCommand(arpPath, arguments: ["-n", gatewayIP])
            .components(separatedBy: "\n")
            .first(where: { $0.contains(gatewayIP) }) else { return nil }

        // arp output format: "? (192.168.1.1) at aa:bb:cc:dd:ee:ff on en0 ..."
        let parts = arpLine.components(separatedBy: " ")
        if let atIndex = parts.firstIndex(of: "at"), atIndex + 1 < parts.count {
            let mac = parts[atIndex + 1]
            if mac.contains(":") { return mac }
        }
        return nil
    }

    private static func runCommand(_ path: String, arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }
}
