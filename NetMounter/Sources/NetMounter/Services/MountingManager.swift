import Foundation
import NetFS
import os

private let logger = Logger(subsystem: "com.netmounter.app", category: "MountingManager")

enum MountError: LocalizedError {
    case mountFailed(Int32)
    case invalidURL
    case authenticationFailed

    var errorDescription: String? {
        switch self {
        case .mountFailed(let code):
            if code == 2 { return "Share not found (ENOENT). Check share name." }
            if code == 17 { return "Mount point exists (EEXIST)." }
            if code == 13 { return "Permission denied (EACCES)." }
            return "Mount failed with error code: \(code)"
        case .invalidURL:
            return "Invalid URL constructed."
        case .authenticationFailed:
            return "Authentication failed."
        }
    }
}

class MountingManager {
    static let shared = MountingManager()

    // Mount a server configuration
    func mount(config: ServerConfig, completion: @escaping (Result<String, Error>) -> Void) {
        // NetFS does not support NFS — use system URL handler instead
        if config.serverProtocol == .nfs {
            mountNFS(config: config, completion: completion)
            return
        }

        guard let url = URL(string: config.urlString) else {
            completion(.failure(MountError.invalidURL))
            return
        }

        // Retrieve credentials separately — never embed in URL
        let user: CFString? = config.username as CFString?
        let password: CFString? = {
            guard let keyId = config.keychainItemId else { return nil }
            return KeychainManager.shared.retrievePassword(for: keyId) as CFString?
        }()

        DispatchQueue.global(qos: .userInitiated).async {
            var mountpoints: Unmanaged<CFArray>? = nil

            let result = NetFSMountURLSync(url as CFURL,
                                           nil,      // Default mount path (/Volumes/ShareName)
                                           user,     // user passed separately
                                           password, // password passed separately
                                           nil,      // open_options
                                           nil,      // mount_options
                                           &mountpoints)

            if result == 0 {
                if let mounts = mountpoints?.takeRetainedValue() as? [String], let firstMount = mounts.first {
                    completion(.success(firstMount))
                } else {
                    completion(.success("Mounted (Unknown Path)"))
                }
            } else if result == 17 || result == EEXIST {
                // EEXIST: Mount point exists or already mounted.
                if let existingPath = self.findExistingMountPath(for: url) {
                    if self.isMountAlive(existingPath) {
                         completion(.success(existingPath))
                    } else {
                        logger.warning("Found zombie mount at \(existingPath, privacy: .public). Force unmounting...")
                        self.forceUnmount(path: existingPath)
                        logger.info("Retrying mount after cleanup...")
                        let retryResult = NetFSMountURLSync(url as CFURL, nil, user, password, nil, nil, &mountpoints)
                        if retryResult == 0 {
                            if let mounts = mountpoints?.takeRetainedValue() as? [String], let firstMount = mounts.first {
                                completion(.success(firstMount))
                            } else {
                                completion(.success("Mounted (Unknown Path)"))
                            }
                        } else {
                             completion(.failure(MountError.mountFailed(retryResult)))
                        }
                    }
                } else {
                    completion(.failure(MountError.mountFailed(result)))
                }
            } else {
                completion(.failure(MountError.mountFailed(result)))
            }
        }
    }

    func findExistingMountPath(for url: URL) -> String? {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeURLForRemountingKey]
        let mountedURLs = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [])

        guard let targetShare = url.pathComponents.last else { return nil }
        let targetHost = url.host?.lowercased()

        for mountURL in mountedURLs ?? [] {
            guard mountURL.lastPathComponent == targetShare else { continue }

            // Verify hostname via volumeURLForRemounting if available
            if let values = try? mountURL.resourceValues(forKeys: Set(keys)),
               let remountURL = values.volumeURLForRemounting {
                let remountHost = remountURL.host?.lowercased()
                if remountHost == targetHost || remountHost == nil || targetHost == nil {
                    return mountURL.path
                }
            } else {
                return mountURL.path
            }
        }
        return nil
    }

    func getAllNetworkMounts(matching servers: [ServerConfig]) -> [MountSnapshot] {
        let keys: [URLResourceKey] = [.volumeURLForRemountingKey, .volumeIsLocalKey]
        guard let mountedURLs = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys, options: []
        ) else { return [] }

        var snapshots: [MountSnapshot] = []

        for mountURL in mountedURLs {
            guard let values = try? mountURL.resourceValues(forKeys: Set(keys)) else { continue }

            // Skip local volumes
            if values.volumeIsLocal == true { continue }

            guard let remountURL = values.volumeURLForRemounting else { continue }

            let snapshot = MountSnapshot(
                serverID: nil,
                volumePath: mountURL.path,
                remountURL: remountURL
            )

            // Try to match against known server configs
            let matchedServer = servers.first { snapshot.matches($0) }
            let finalSnapshot = MountSnapshot(
                serverID: matchedServer?.id,
                volumePath: mountURL.path,
                remountURL: remountURL
            )
            snapshots.append(finalSnapshot)
        }

        return snapshots
    }

    func unmount(mountPath: String, completion: @escaping (Error?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
            process.arguments = ["unmount", mountPath]

            let errorPipe = Pipe()
            process.standardError = errorPipe

            do {
                try process.run()
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    DispatchQueue.main.async { completion(nil) }
                } else {
                    let stderr = String(data: errorData, encoding: .utf8) ?? ""
                    logger.error("diskutil unmount failed: \(stderr, privacy: .public)")
                    DispatchQueue.main.async { completion(MountError.mountFailed(process.terminationStatus)) }
                }
            } catch {
                DispatchQueue.main.async { completion(error) }
            }
        }
    }

    private func forceUnmount(path: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["unmount", "force", path]
        try? process.run()
        process.waitUntilExit()
    }

    // MARK: - NFS Mount

    /// Mount NFS via privileged shell command.
    /// macOS requires root for NFS mounts — the system auth dialog supports Touch ID
    /// on macOS Ventura+ with Touch ID hardware.
    private func mountNFS(config: ServerConfig, completion: @escaping (Result<String, Error>) -> Void) {
        let cleanShare = config.sharePath.trimmingCharacters(in: CharacterSet(charactersIn: "/\\ "))
        guard !cleanShare.isEmpty else {
            completion(.failure(MountError.invalidURL))
            return
        }

        guard let url = URL(string: config.urlString) else {
            completion(.failure(MountError.invalidURL))
            return
        }

        // Check if already mounted
        if let existingPath = findExistingMountPath(for: url) {
            if isMountAlive(existingPath) {
                completion(.success(existingPath))
                return
            } else {
                forceUnmount(path: existingPath)
            }
        }

        let sharePath = "/\(cleanShare)"
        let mountName = URL(fileURLWithPath: sharePath).lastPathComponent
        let mountPoint = "/Volumes/\(mountName)"
        let nfsSource = "\(config.hostname):\(sharePath)"

        // mkdir + mount both need root. Use osascript process so the system-level
        // auth dialog appears above all windows (not blocked by sheets).
        let shellCmd = "mkdir -p '\(mountPoint)' && /sbin/mount -t nfs -o resvport,noowners '\(nfsSource)' '\(mountPoint)'"
        let script = "do shell script \"\(shellCmd)\" with administrator privileges"

        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]

            let errorPipe = Pipe()
            process.standardError = errorPipe

            do {
                try process.run()
            } catch {
                completion(.failure(error))
                return
            }

            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            if process.terminationStatus == 0 {
                completion(.success(mountPoint))
            } else {
                let stderr = String(data: errorData, encoding: .utf8) ?? ""
                logger.error("NFS mount failed: \(stderr, privacy: .public)")
                completion(.failure(MountError.mountFailed(process.terminationStatus)))
            }
        }
    }

    private func isMountAlive(_ path: String) -> Bool {
        var isAlive = false
        let semaphore = DispatchSemaphore(value: 0)

        DispatchQueue.global(qos: .background).async {
            if FileManager.default.isReadableFile(atPath: path) {
                isAlive = true
            }
            semaphore.signal()
        }

        let result = semaphore.wait(timeout: .now() + 2.0)
        if result == .timedOut {
            return false
        }
        return isAlive
    }
}
