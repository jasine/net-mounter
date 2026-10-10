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

    // Wake-on-LAN
    var wolEnabled: Bool = false
    var wolMACAddress: String?
    var wolBroadcastAddress: String?
    var wolPort: UInt16 = 9

    var normalizedSharePath: String {
        sharePath.trimmingCharacters(in: CharacterSet(charactersIn: "/\\"))
    }

    /// `hostname` with any trailing `:port` or surrounding `[...]` stripped.
    /// Users commonly enter `host:port` in the single hostname field — for
    /// WebDAV on non-standard ports especially — but `URLComponents.host`
    /// rejects strings containing `:`, which silently zeroes out the mount
    /// URL. Splitting here lets the whole pipeline (URL construction,
    /// reachability, WOL, VPN routing) use just the host portion while
    /// `parsedPort` carries the port separately.
    var parsedHost: String {
        parsedHostAndPort.host
    }

    /// Port extracted from the `hostname` field, if the user put one there.
    /// Returns nil for plain hostnames or malformed `:port` suffixes.
    var parsedPort: UInt16? {
        parsedHostAndPort.port
    }

    private var parsedHostAndPort: (host: String, port: UInt16?) {
        let raw = hostname.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return (raw, nil) }

        // Bracketed IPv6: "[::1]" or "[::1]:5702"
        if raw.hasPrefix("[") {
            guard let closing = raw.firstIndex(of: "]") else {
                return (raw, nil)
            }
            let inside = String(raw[raw.index(after: raw.startIndex)..<closing])
            let afterBracket = raw.index(after: closing)
            if afterBracket < raw.endIndex, raw[afterBracket] == ":" {
                let portStr = String(raw[raw.index(after: afterBracket)..<raw.endIndex])
                if let port = UInt16(portStr), port > 0 {
                    return (inside, port)
                }
                // Malformed port after `]` — treat whole thing as host so the
                // user sees exactly what they typed in the resulting error.
                return (raw, nil)
            }
            return (inside, nil)
        }

        // Multiple colons without brackets → unbracketed IPv6, no port.
        // (Standard URL syntax requires brackets to combine IPv6 + port.)
        let colonCount = raw.filter { $0 == ":" }.count
        if colonCount >= 2 {
            return (raw, nil)
        }

        // Single colon → "host:port".
        if colonCount == 1, let colon = raw.firstIndex(of: ":") {
            let host = String(raw[raw.startIndex..<colon])
            let portStr = String(raw[raw.index(after: colon)..<raw.endIndex])
            if !host.isEmpty, let port = UInt16(portStr), port > 0 {
                return (host, port)
            }
            return (raw, nil)
        }

        return (raw, nil)
    }

    /// A mount needs a concrete share/export path — `smb://host` with no share
    /// (or NFS with no export) is not a mountable target and must be rejected
    /// before calling into NetFS, which otherwise hangs on such input.
    var isValidMountTarget: Bool {
        !normalizedSharePath.trimmingCharacters(in: .whitespaces).isEmpty
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
        components.host = hostForURLComponents(parsedHost)
        if let port = parsedPort {
            components.port = Int(port)
        }

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

    /// URL for mounting — deliberately WITHOUT credentials in the URL.
    /// Credentials are passed as separate arguments to NetFSMountURLSync;
    /// embedding the username in the URL *and* passing it as an argument makes
    /// the mount hang. Used only for mounting, not for display (see urlString).
    var mountURLString: String {
        var components = URLComponents()
        components.scheme = serverProtocol.scheme
        components.host = hostForURLComponents(parsedHost)
        if let port = parsedPort {
            components.port = Int(port)
        }
        let cleanPath = normalizedSharePath
        if !cleanPath.isEmpty {
            components.path = "/\(cleanPath)"
        }
        return components.string ?? ""
    }

    /// `URLComponents.host` rejects IPv6 unless it's bracketed; `parsedHost`
    /// strips brackets so other call sites (ARP, VPN routing) get the raw
    /// address. Re-wrap here when writing back into URLComponents.
    private func hostForURLComponents(_ host: String) -> String {
        host.contains(":") ? "[\(host)]" : host
    }
}
