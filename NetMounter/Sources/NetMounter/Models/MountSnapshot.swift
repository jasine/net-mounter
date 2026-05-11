import Foundation

struct MountSnapshot {
    let serverID: UUID?
    let volumePath: String
    let remountURL: URL

    func matches(_ config: ServerConfig) -> Bool {
        guard let snapshotHost = remountURL.host?.lowercased(),
              let snapshotShare = remountURL.pathComponents.last else {
            return false
        }
        let configHost = config.hostname.lowercased()
        let configShare = config.normalizedSharePath
        return snapshotHost == configHost && snapshotShare == configShare
    }
}
