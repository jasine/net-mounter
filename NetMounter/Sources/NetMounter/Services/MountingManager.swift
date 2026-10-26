import Foundation
import NetFS
import Logging

private let logger = Logger(label: "MountingManager")

enum MountError: LocalizedError, Equatable {
    case mountFailed(Int32)
    case invalidURL
    case invalidShare
    case timedOut
    case keychainReadFailed(Int32)
    case cancellationFailed(Int32)
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
            return String(localized: "Mount timed out while waiting for macOS or the server. Automatic retries are paused; try mounting again manually.", bundle: .module)
        case .keychainReadFailed:
            return String(localized: "The saved password could not be read from Keychain. Allow access, unlock Keychain, or save the password again.", bundle: .module)
        case .cancellationFailed:
            return String(localized: "The previous mount request is still pending in macOS. Automatic retries are paused; the macOS network service may need to be restarted.", bundle: .module)
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
        case .invalidShare, .invalidURL, .timedOut, .keychainReadFailed, .cancellationFailed:
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

    /// Starts a cancellable NetFS request and returns its cancellation function.
    /// A nonzero cancellation status keeps the in-flight guard until the actual callback.
    var performNetFSMount: ((URL, String?, String?, @escaping (NetFSMountResult) -> Void) -> (() -> Int32))?

    var readPassword: (String) -> Result<String, KeychainManager.ReadError> = {
        KeychainManager.shared.readPassword(for: $0)
    }

    /// Starts after Keychain authorization, not while waiting for the user's response.
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
        let diagnostic = DiagnosticsService.shared.begin(.mount, protocolType: config.serverProtocol, automatic: silent)
        let complete: (Result<String, Error>) -> Void = { result in
            if case .failure(let error) = result { diagnostic.finish(error: error) }
            else { diagnostic.finish() }
            completion(result)
        }
        switch config.serverProtocol {
        case .nfs:
            mountNFS(config: config, silent: silent, completion: complete)
        case .smb, .afp, .webdav:
            mountNetFS(config: config, silent: silent, completion: complete)
        }
    }

    func findExistingMountPath(for url: URL) -> String? {
        findExistingMountPath(for: url, in: getAllNetworkMounts(matching: []))
    }

    func findExistingMountPath(for url: URL, in mounts: [MountSnapshot]) -> String? {
        // macOS may rename the local mount directory (e.g. media-1).
        mounts.first { $0.matches(url) }?.volumePath
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
        let diagnostic = DiagnosticsService.shared.begin(.unmount)
        let complete: (Error?) -> Void = { error in
            diagnostic.finish(error: error)
            completion(error)
        }
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
                    DispatchQueue.main.async { complete(nil) }
                } else {
                    let stderr = String(data: errorData, encoding: .utf8) ?? ""
                    logger.error("diskutil unmount failed: \(stderr)")
                    DispatchQueue.main.async { complete(MountError.mountFailed(process.terminationStatus)) }
                }
            } catch {
                DispatchQueue.main.async { complete(error) }
            }
        }
    }

    func forceUnmount(path: String) {
        let diagnostic = DiagnosticsService.shared.begin(.forceUnmount)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["unmount", "force", path]
        do {
            try process.run()
            process.waitUntilExit()
            diagnostic.finish(error: process.terminationStatus == 0 ? nil : MountError.mountFailed(process.terminationStatus))
        } catch {
            diagnostic.finish(error: error)
        }
    }

    // MARK: - SMB/AFP/WebDAV Mount via NetFS

    private func mountNetFS(config: ServerConfig, silent: Bool = false, completion: @escaping (Result<String, Error>) -> Void) {
        // Reject un-mountable targets (e.g. smb://host with no share) before
        // touching NetFS — a server URL without a share cannot be mounted.
        guard config.isValidMountTarget else {
            DispatchQueue.main.async { completion(.failure(MountError.invalidShare)) }
            return
        }

        guard markInflight(config.id) else {
            logger.debug("Mount already in-flight for \(config.alias), skipping")
            DispatchQueue.main.async { completion(.failure(MountError.mountFailed(EBUSY))) }
            return
        }

        // Report exactly once; keep the in-flight guard if native cancellation fails.
        let didComplete = NSLock()
        var completed = false
        let wrappedCompletion: (Result<String, Error>, Bool) -> Void = { [weak self] result, releaseInflight in
            didComplete.lock()
            if completed { didComplete.unlock(); return }
            completed = true
            didComplete.unlock()

            if releaseInflight { self?.clearInflight(config.id) }
            DispatchQueue.main.async { completion(result) }
        }

        guard let url = URL(string: config.mountURLString) else {
            wrappedCompletion(.failure(MountError.invalidURL), true)
            return
        }

        let mountFn = performNetFSMount ?? Self.defaultNetFSMount
        let passwordReader = readPassword
        let timeoutInterval = netFSMountTimeout
        DispatchQueue.global(qos: .userInitiated).async {
            // Volume probes and Keychain authorization can block; never run them on the UI thread.
            if let existingPath = self.findExistingMountPath(for: url) {
                if self.isMountAlive(existingPath) {
                    wrappedCompletion(.success(existingPath), true)
                    return
                }
                self.forceUnmount(path: existingPath)
            }

            var password: String?
            if let keyID = config.keychainItemId {
                logger.debug("Reading saved mount credentials for server \(config.id)")
                switch passwordReader(keyID) {
                case .success(let value): password = value
                case .failure(.status(let status)):
                    logger.error("Keychain read failed for server \(config.id); OSStatus=\(status). NetFS not started.")
                    wrappedCompletion(.failure(MountError.keychainReadFailed(status)), true)
                    return
                }
            }

            // Serialize start, timeout/cancel and callback. A retry can only begin once
            // cancellation succeeds, or the original native request actually finishes.
            let requestQueue = DispatchQueue(label: "com.netmounter.netfs.\(config.id)")
            requestQueue.async {
                var completed = false
                var pendingAfterTimeout = false
                var cancel: () -> Int32 = { 0 }
                let startedAt = Date()
                let timeout = DispatchWorkItem {
                    guard !completed else { return }
                    completed = true
                    let status = cancel()
                    pendingAfterTimeout = status != 0
                    logger.warning("NetFS timeout for server \(config.id); cancellation status=\(status)")
                    let error: MountError = status == 0 ? .timedOut : .cancellationFailed(status)
                    wrappedCompletion(.failure(error), !pendingAfterTimeout)
                }

                logger.info("Starting NetFS mount for server \(config.id); protocol=\(config.serverProtocol.rawValue)")
                cancel = mountFn(url, config.username, password) { mountResult in
                    requestQueue.async {
                        guard !completed else {
                            if pendingAfterTimeout {
                                pendingAfterTimeout = false
                                self.clearInflight(config.id)
                                DispatchQueue.main.async {
                                    NotificationCenter.default.post(name: .mountStateDidChange, object: nil)
                                }
                            }
                            return
                        }
                        completed = true
                        timeout.cancel()
                        let elapsed = Date().timeIntervalSince(startedAt)
                        switch mountResult {
                        case .success(let path):
                            logger.info("NetFS mount completed for server \(config.id) after \(elapsed)s")
                            wrappedCompletion(.success(path ?? "Mounted (Unknown Path)"), true)
                        case .failure(let code):
                            logger.error("NetFS mount failed for server \(config.id); status=\(code), elapsed=\(elapsed)s")
                            if code == EEXIST,
                               let existingPath = self.findExistingMountPath(for: url),
                               self.isMountAlive(existingPath) {
                                wrappedCompletion(.success(existingPath), true)
                            } else {
                                wrappedCompletion(.failure(MountError.mountFailed(code)), true)
                            }
                        }
                    }
                }
                requestQueue.asyncAfter(deadline: .now() + timeoutInterval, execute: timeout)
            }
        }
    }

    /// Use NetFS's asynchronous API so timeouts cancel the real system request.
    /// Credentials remain separate from the URL; NetFS's own authentication UI is suppressed.
    private static let defaultNetFSMount: (URL, String?, String?, @escaping (NetFSMountResult) -> Void) -> (() -> Int32) = { url, user, password, completion in
        var requestID: AsyncRequestID?
        let status = NetFSMountURLAsync(
            url as CFURL, nil,
            user as CFString?, password as CFString?,
            noUIOptions(), nil, &requestID, DispatchQueue.global(qos: .userInitiated)
        ) { status, _, mountpoints in
            if status == 0 {
                completion(.success((mountpoints as? [String])?.first))
            } else {
                completion(.failure(status))
            }
        }
        guard status == 0, let requestID else {
            completion(.failure(status == 0 ? EIO : status))
            return { 0 }
        }
        return { NetFSMountURLCancel(requestID) }
    }

    private static func noUIOptions() -> CFMutableDictionary {
        let dict = NSMutableDictionary()
        dict["UIOption"] = "NoUI"
        return dict as CFMutableDictionary
    }

    // MARK: - NFS Mount

    private func mountNFS(config: ServerConfig, silent: Bool = false, completion: @escaping (Result<String, Error>) -> Void) {
        let cleanShare = config.normalizedSharePath
        guard config.isValidMountTarget else {
            DispatchQueue.main.async { completion(.failure(MountError.invalidShare)) }
            return
        }

        guard config.isValidHostname, let url = URL(string: config.urlString) else {
            DispatchQueue.main.async { completion(.failure(MountError.invalidURL)) }
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
            let shellCmd = "mkdir -p \(shellEscape(mountPoint)) && /sbin/mount_nfs -o resvport,noowners,nosuid,nodev -- \(shellEscape(nfsSource)) \(shellEscape(mountPoint))"
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
