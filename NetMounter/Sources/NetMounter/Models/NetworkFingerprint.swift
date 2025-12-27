import Foundation

enum InterfaceType: String, Codable {
    case wifi
    case wired
    case other
}

struct NetworkFingerprint: Codable, Equatable, Hashable {
    var ssid: String?
    var bssid: String? // Optional, for more specific matching
    var gatewayMac: String? // Fallback if SSID not available
    var interfaceType: InterfaceType
    
    // Helper to check if it matches another fingerprint (current network state)
    func matches(_ other: NetworkFingerprint) -> Bool {
        // Simple matching logic for now: SSID match takes priority
        if let selfSSID = ssid, let otherSSID = other.ssid {
            return selfSSID == otherSSID
        }
        // Fallback to gateway MAC matching for wired connections or when SSID hidden/unavailable
        if let selfGateway = gatewayMac, let otherGateway = other.gatewayMac {
            return selfGateway == otherGateway
        }
        return false
    }
}
