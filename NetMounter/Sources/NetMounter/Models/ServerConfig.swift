import Foundation

enum NetworkProtocol: String, Codable, CaseIterable {
    case smb
    case nfs
    case ftp
    
    var scheme: String { return self.rawValue }
    var rawValue: String {
        switch self {
        case .smb: return "smb"
        case .nfs: return "nfs"
        case .ftp: return "ftp"
        }
    }
}

struct AutoMountRule: Codable, Identifiable {
    var id: UUID = UUID()
    var fingerprint: NetworkFingerprint
    var enabled: Bool = true
}

struct ServerConfig: Codable, Identifiable {
    var id: UUID = UUID()
    var alias: String
    var serverProtocol: NetworkProtocol = .smb
    var hostname: String
    var sharePath: String // e.g., "shared" in smb://host/shared
    var username: String?
    // We store a reference to the password in the Keychain, not the password itself.
    var keychainItemId: String?
    
    // Auto-mount rules
    var autoMountRules: [AutoMountRule] = []
    
    // UI Helper to construct full URL string
    var urlString: String {
        var components = URLComponents()
        components.scheme = serverProtocol.scheme
        components.host = hostname
        
        // Sanitize share path: remove leading/trailing slashes and backslashes
        let dirtyPath = sharePath
        let cleanPath = dirtyPath.trimmingCharacters(in: CharacterSet(charactersIn: "/\\"))
        
        // Path must start with / for URLComponents
        let pathToAdd = "/\(cleanPath)"
        
        // If sharePath is empty (or became empty), we might just want to point to root if allowed, 
        // but typically for smb mounting we want a share.
        // If empty, URLComponents.path = "/" results in smb://host/
        if !cleanPath.isEmpty {
            components.path = pathToAdd
        }
        
        if let user = username, !user.isEmpty {
            components.user = user
        }
        
        return components.string ?? ""
    }
}
