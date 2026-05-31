import Foundation
import NetFS
import Logging

private let logger = Logger(label: "MountingManager")

enum MountError: LocalizedError {
    case mountFailed(Int32)
    case invalidURL
    case authenticationRequired
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
        case .authenticationRequired:
            return "Authentication required. Please add credentials."
        case .authenticationFailed:
            return "Authentication failed."
        }
    }

    var isAuthError: Bool {
        switch self {
        case .authenticationRequired, .authenticationFailed:
            return true
        case .mountFailed(let code):
            return code == 80 || code == 1 || code == 13
        default:
            return false
        }
    }
}

class MountingManager {
    static let shared = MountingManager()

    private func shellEscape(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func appleScriptEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private let inflightLock = NSLock()
    private var inflightMounts: Set<UUID> = []

    func isMountInFlight(_ serverID: UUID) -> Bool {
        inflightLock.lock()
        defer { inflightLock.unlock() }
        return inflightMounts.contains(serverID)
    }

    private func markInflight(_ serverID: UUID) -> Bool {
        inflightLock.lock()
        defer { inflightLock.unlock() }
        return inflightMounts.insert(serverID).inserted
    }

    private func clearInflight(_ serverID: UUID) {
        inflightLock.lock()
        defer { inflightLock.unlock() }
        inflightMounts.remove(serverID)
    }

    func mount(config: ServerConfig, silent: Bool = false, completion: @escaping (Result<String, Error>) -> Void) {
        if config.serverProtocol == .nfs {
            mountNFS(config: config, silent: silent, completion: completion)
            return
        }

        mountNetFS(config: config, silent: silent, completion: completion)
    }

    func findExistingMountPath(for url: URL) -> String? {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeURLForRemountingKey]
        let mountedURLs = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [])

        guard let targetShare = url.pathComponents.last else { return nil }
        let targetHost = url.host?.lowercased()

        for mountURL in mountedURLs ?? [] {
            guard mountURL.lastPathComponent == targetShare else { continue }

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
            if values.volumeIsLocal == true { continue }
            guard let remountURL = values.volumeURLForRemounting else { continue }

            let matchedServer = servers.first { MountSnapshot(serverID: nil, volumePath: mountURL.path, remountURL: remountURL).matches($0) }
            snapshots.append(MountSnapshot(
                serverID: matchedServer?.id,
                volumePath: mountURL.path,
                remountURL: remountURL
            ))
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
                    logger.error("diskutil unmount failed: \(stderr)")
                    DispatchQueue.main.async { completion(MountError.mountFailed(process.terminationStatus)) }
                }
            } catch {
                DispatchQueue.main.async { completion(error) }
            }
        }
    }

    func forceUnmount(path: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["unmount", "force", path]
        try? process.run()
        process.waitUntilExit()
    }

    // MARK: - AFP/WebDAV Mount via NetFS

    private func mountNetFS(config: ServerConfig, silent: Bool = false, completion: @escaping (Result<String, Error>) -> Void) {
        guard markInflight(config.id) else {
            logger.debug("Mount already in-flight for \(config.alias), skipping")
            DispatchQueue.main.async { completion(.failure(MountError.mountFailed(EBUSY))) }
            return
        }

        let wrappedCompletion: (Result<String, Error>) -> Void = { [weak self] result in
            self?.clearInflight(config.id)
            DispatchQueue.main.async { completion(result) }
        }

        guard let url = URL(string: config.urlString) else {
            wrappedCompletion(.failure(MountError.invalidURL))
            return
        }

        if let existingPath = findExistingMountPath(for: url) {
            if isMountAlive(existingPath) {
                wrappedCompletion(.success(existingPath))
                return
            } else {
                forceUnmount(path: existingPath)
            }
        }

        let user: CFString? = config.username as CFString?
        let password: CFString? = {
            guard let keyId = config.keychainItemId else { return nil }
            return KeychainManager.shared.retrievePassword(for: keyId) as CFString?
        }()

        let openOptions: CFMutableDictionary? = silent ? Self.noUIOptions() : nil

        DispatchQueue.global(qos: .userInitiated).async {
            var mountpoints: Unmanaged<CFArray>? = nil

            let result = NetFSMountURLSync(url as CFURL, nil, user, password, openOptions, nil, &mountpoints)

            if result == 0 {
                if let mounts = mountpoints?.takeRetainedValue() as? [String], let firstMount = mounts.first {
                    wrappedCompletion(.success(firstMount))
                } else {
                    wrappedCompletion(.success("Mounted (Unknown Path)"))
                }
            } else if result == 17 || result == EEXIST {
                if let existingPath = self.findExistingMountPath(for: url), self.isMountAlive(existingPath) {
                    wrappedCompletion(.success(existingPath))
                } else {
                    wrappedCompletion(.failure(MountError.mountFailed(result)))
                }
            } else {
                wrappedCompletion(.failure(MountError.mountFailed(result)))
            }
        }
    }

    private static func noUIOptions() -> CFMutableDictionary {
        let dict = NSMutableDictionary()
        dict["UIOption"] = "NoUI"
        return dict as CFMutableDictionary
    }

    // MARK: - NFS Mount

    private func mountNFS(config: ServerConfig, silent: Bool = false, completion: @escaping (Result<String, Error>) -> Void) {
        let cleanShare = config.sharePath.trimmingCharacters(in: CharacterSet(charactersIn: "/\\ "))
        guard !cleanShare.isEmpty else {
            completion(.failure(MountError.invalidURL))
            return
        }

        guard let url = URL(string: config.urlString) else {
            completion(.failure(MountError.invalidURL))
            return
        }

        guard markInflight(config.id) else {
            logger.debug("Mount already in-flight for \(config.alias), skipping")
            DispatchQueue.main.async { completion(.failure(MountError.mountFailed(EBUSY))) }
            return
        }

        let wrappedCompletion: (Result<String, Error>) -> Void = { [weak self] result in
            self?.clearInflight(config.id)
            DispatchQueue.main.async { completion(result) }
        }

        if let existingPath = findExistingMountPath(for: url) {
            if isMountAlive(existingPath) {
                wrappedCompletion(.success(existingPath))
                return
            } else {
                forceUnmount(path: existingPath)
            }
        }

        let sharePath = "/\(cleanShare)"
        let mountName = URL(fileURLWithPath: sharePath).lastPathComponent
        let mountPoint = "/Volumes/\(mountName)"
        let nfsSource = "\(config.hostname):\(sharePath)"

        let shellCmd = "mkdir -p \(shellEscape(mountPoint)) && /sbin/mount -t nfs -o resvport,noowners \(shellEscape(nfsSource)) \(shellEscape(mountPoint))"
        let escapedShellCmd = appleScriptEscape(shellCmd)
        let script = silent
            ? "do shell script \"\(escapedShellCmd)\""
            : "do shell script \"\(escapedShellCmd)\" with administrator privileges"

        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]

            let errorPipe = Pipe()
            process.standardError = errorPipe

            do {
                try process.run()
            } catch {
                wrappedCompletion(.failure(error))
                return
            }

            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            if process.terminationStatus == 0 {
                wrappedCompletion(.success(mountPoint))
            } else {
                let stderr = String(data: errorData, encoding: .utf8) ?? ""
                logger.error("NFS mount failed: \(stderr)")
                wrappedCompletion(.failure(MountError.mountFailed(process.terminationStatus)))
            }
        }
    }

    func isMountAlive(_ path: String) -> Bool {
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
