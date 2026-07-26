import Foundation
import NetFS
import Logging

private let logger = Logger(label: "MountingManager")

enum MountError: LocalizedError, Equatable {
    case mountFailed(Int32)
    case invalidURL
    case invalidShare
    case timedOut
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
        case .invalidShare:
            return "Missing share name. Enter the share/export path for this server."
        case .timedOut:
            return "Mount timed out. The server did not respond."
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

    /// Errors that won't be fixed by retrying — the user must change the config.
    /// Retrying these just wastes attempts (and, for invalidShare, would loop on
    /// a target that can never mount).
    var isNonRetryable: Bool {
        switch self {
        case .invalidShare, .invalidURL:
            return true
        default:
            return isAuthError
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

    /// Result of a low-level NetFS mount attempt.
    enum NetFSMountResult {
        case success(String?)   // resolved mount path, if any
        case failure(Int32)     // NetFS/errno status code
    }

    /// The low-level mount call, injectable for testing. Production uses
    /// NetFSMountURLSync; tests substitute a stub (e.g. one that never calls
    /// back, to exercise the timeout path). Parameters: url, user, password,
    /// completion.
    var performNetFSMount: ((URL, String?, String?, @escaping (NetFSMountResult) -> Void) -> Void)?

    /// Timeout for a single NetFS mount attempt. If the mount does not report
    /// back within this window, the attempt is abandoned, the in-flight lock is
    /// released, and `.timedOut` is returned — preventing a hung mount from
    /// wedging the lock forever.
    var netFSMountTimeout: TimeInterval = 30.0

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
        // Reject un-mountable targets (e.g. smb://host with no share) before
        // touching NetFS — such input makes NetFSMountURLSync hang.
        guard config.isValidMountTarget else {
            DispatchQueue.main.async { completion(.failure(MountError.invalidShare)) }
            return
        }

        guard markInflight(config.id) else {
            logger.debug("Mount already in-flight for \(config.alias), skipping")
            DispatchQueue.main.async { completion(.failure(MountError.mountFailed(EBUSY))) }
            return
        }

        // Release the lock and report exactly once, even if both the mount and
        // the timeout fire.
        let didComplete = NSLock()
        var completed = false
        let wrappedCompletion: (Result<String, Error>) -> Void = { [weak self] result in
            didComplete.lock()
            if completed { didComplete.unlock(); return }
            completed = true
            didComplete.unlock()

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

        let user = config.username
        let password: String? = {
            guard let keyId = config.keychainItemId else { return nil }
            return KeychainManager.shared.retrievePassword(for: keyId)
        }()

        // Timeout guard: if the mount never reports back within the window,
        // abandon it, release the lock, and return .timedOut so a hung mount
        // cannot wedge the lock forever.
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + netFSMountTimeout) {
            wrappedCompletion(.failure(MountError.timedOut))
        }

        let mountFn = performNetFSMount ?? Self.defaultNetFSMount
        mountFn(url, user, password) { [weak self] mountResult in
            guard let self = self else { return }
            switch mountResult {
            case .success(let path):
                wrappedCompletion(.success(path ?? "Mounted (Unknown Path)"))
            case .failure(let code):
                if code == 17 || code == EEXIST,
                   let existingPath = self.findExistingMountPath(for: url),
                   self.isMountAlive(existingPath) {
                    wrappedCompletion(.success(existingPath))
                } else {
                    wrappedCompletion(.failure(MountError.mountFailed(code)))
                }
            }
        }
    }

    /// Production NetFS mount. Suppresses NetFS's own auth UI (NoUI): credentials
    /// come from the app's own fields, not a system dialog that cannot be shown
    /// from a background thread.
    private static let defaultNetFSMount: (URL, String?, String?, @escaping (NetFSMountResult) -> Void) -> Void = { url, user, password, completion in
        DispatchQueue.global(qos: .userInitiated).async {
            var mountpoints: Unmanaged<CFArray>? = nil
            let result = NetFSMountURLSync(
                url as CFURL, nil,
                user as CFString?, password as CFString?,
                noUIOptions(), nil, &mountpoints
            )
            if result == 0 {
                let path = (mountpoints?.takeRetainedValue() as? [String])?.first
                completion(.success(path))
            } else {
                completion(.failure(result))
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

        let mountProcess = Process()
        let errorPipe = Pipe()

        if PrivilegedMountInstaller.isInstalled() {
            // Passwordless path: root-owned wrapper via `sudo -n` (non-interactive).
            mountProcess.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            mountProcess.arguments = ["-n", PrivilegedMountInstaller.wrapperScriptPath, mountPoint, nfsSource]
        } else {
            // Fallback: prompt for admin password via osascript (pre-install behavior).
            let shellCmd = "mkdir -p \(shellEscape(mountPoint)) && /sbin/mount -t nfs -o resvport,noowners,nosuid,nodev \(shellEscape(nfsSource)) \(shellEscape(mountPoint))"
            let escapedShellCmd = appleScriptEscape(shellCmd)
            let script = silent
                ? "do shell script \"\(escapedShellCmd)\""
                : "do shell script \"\(escapedShellCmd)\" with administrator privileges"
            mountProcess.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            mountProcess.arguments = ["-e", script]
        }

        DispatchQueue.global(qos: .userInitiated).async {
            mountProcess.standardError = errorPipe
            do {
                try mountProcess.run()
            } catch {
                wrappedCompletion(.failure(error))
                return
            }

            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            mountProcess.waitUntilExit()

            if mountProcess.terminationStatus == 0 {
                wrappedCompletion(.success(mountPoint))
            } else {
                let stderr = String(data: errorData, encoding: .utf8) ?? ""
                logger.error("NFS mount failed: \(stderr)")
                wrappedCompletion(.failure(MountError.mountFailed(mountProcess.terminationStatus)))
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
