import Foundation
import Network
import CoreWLAN
import Combine

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
        let newFingerprint: NetworkFingerprint?
        if path.status != .satisfied {
            newFingerprint = nil
        } else {
            newFingerprint = NetworkFingerprint(
                ssid: ssid,
                bssid: bssid,
                gatewayMac: nil,
                interfaceType: interfaceType
            )
        }
        
        // Dispatch to Main to update Published properties
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            // Update currentPath
            self.currentPath = path
            
            // Update fingerprint ONLY if changed
            if self.currentFingerprint != newFingerprint {
                self.currentFingerprint = newFingerprint
                print("Network Changed: \(String(describing: self.currentFingerprint))")
            }
        }
    }
}
