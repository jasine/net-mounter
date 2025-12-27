import Foundation
import Network
import CoreWLAN

class NetworkMonitor: ObservableObject {
    static let shared = NetworkMonitor()
    
    @Published var currentPath: NWPath?
    @Published var currentFingerprint: NetworkFingerprint?
    
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "NetworkMonitor")
    
    init() {
        startMonitoring()
    }
    
    func startMonitoring() {
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.currentPath = path
                self?.updateFingerprint(path: path)
            }
        }
        monitor.start(queue: queue)
    }
    
    private func updateFingerprint(path: NWPath) {
        var ssid: String? = nil
        var bssid: String? = nil
        var interfaceType: InterfaceType = .other
        
        if path.usesInterfaceType(.wifi) {
            interfaceType = .wifi
            // Try to get SSID
            let client = CWWiFiClient.shared()
            if let interface = client.interface() {
                ssid = interface.ssid()
                bssid = interface.bssid()
            }
            // Fallback for SSID if CoreWLAN fails or returns nil (e.g. permission issues), 
            // though typically requires Location permission.
        } else if path.usesInterfaceType(.wiredEthernet) {
            interfaceType = .wired
        }
        
        // Gateway MAC is harder to get via Swift APIs directly without calling `arp` or sysctl.
        // For MVP, we stick to SSID and Interface Type.
        
        // If we are disconnected
        if path.status != .satisfied {
            self.currentFingerprint = nil
            return
        }
        
        self.currentFingerprint = NetworkFingerprint(
            ssid: ssid,
            bssid: bssid,
            gatewayMac: nil, // TODO: Implement if needed via 'arp -a'
            interfaceType: interfaceType
        )
        
        print("Network Changed: \(String(describing: self.currentFingerprint))")
    }
}
