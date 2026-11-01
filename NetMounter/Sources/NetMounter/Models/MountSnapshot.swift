import Foundation

struct MountSnapshot {
    let serverID: UUID?
    let volumePath: String
    let remountURL: URL

    func matches(_ config: ServerConfig) -> Bool {
        guard let url = URL(string: config.mountURLString) else { return false }
        return matches(url)
    }

    func matches(_ url: URL) -> Bool {
        guard let sourceScheme = remountURL.scheme?.lowercased(),
              let sourceHost = remountURL.host?.lowercased(),
              let targetScheme = url.scheme?.lowercased(),
              let targetHost = url.host?.lowercased() else {
            return false
        }
        let sourcePath = remountURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let targetPath = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let defaultPort: Int?
        switch sourceScheme {
        case "smb": defaultPort = 445
        case "afp": defaultPort = 548
        case "nfs": defaultPort = 2049
        case "http": defaultPort = 80
        case "https": defaultPort = 443
        default: defaultPort = nil
        }
        return !targetPath.isEmpty && sourceScheme == targetScheme
            && sourceHost == targetHost && sourcePath == targetPath
            && (remountURL.port ?? defaultPort) == (url.port ?? defaultPort)
    }
}
