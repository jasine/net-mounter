import Foundation

enum NetworkProtocol: String, Codable, CaseIterable {
    case smb
    case afp
    case nfs
    case webdav

    var scheme: String {
        switch self {
        case .smb: return "smb"
        case .afp: return "afp"
        case .nfs: return "nfs"
        case .webdav: return "https" // WebDAV over HTTPS
        }
    }

    /// Default port used for connectivity checks
    var defaultPort: UInt16 {
        switch self {
        case .smb: return 445
        case .afp: return 548
        case .nfs: return 2049
        case .webdav: return 443
        }
    }

    /// 用于 UI 显示的协议名称
    var displayName: String {
        switch self {
        case .smb: return "SMB"
        case .afp: return "AFP"
        case .nfs: return "NFS"
        case .webdav: return "WebDAV"
        }
    }
}

struct PinnedFolder: Codable, Identifiable {
    let id: UUID
    var name: String
    var subpath: String

    init(id: UUID = UUID(), name: String, subpath: String) {
        self.id = id
        self.name = name
        self.subpath = subpath
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
    var pinnedFolders: [PinnedFolder] = []

    var normalizedSharePath: String {
        sharePath.trimmingCharacters(in: CharacterSet(charactersIn: "/\\"))
    }

    var hasEnabledAutoMountRules: Bool {
        autoMountRules.contains { $0.enabled }
    }

    func shouldAutoMount(for fingerprint: NetworkFingerprint?, isVPN: Bool) -> Bool {
        guard hasEnabledAutoMountRules else { return false }
        let fingerprintMatch = fingerprint.map { fp in
            autoMountRules.contains { $0.enabled && $0.fingerprint.matches(fp) }
        } ?? false
        return fingerprintMatch || isVPN
    }
    
    var shareURL: URL? {
        var components = URLComponents()
        components.scheme = "netmounter"
        components.host = "add"
        components.queryItems = [
            URLQueryItem(name: "host", value: hostname),
            URLQueryItem(name: "proto", value: serverProtocol.rawValue),
            URLQueryItem(name: "share", value: sharePath),
            URLQueryItem(name: "alias", value: alias),
        ]
        return components.url
    }

    var urlString: String {
        var components = URLComponents()
        components.scheme = serverProtocol.scheme
        components.host = hostname
        
        let cleanPath = normalizedSharePath
        
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
