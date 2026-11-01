import Foundation
import NetFS
import Darwin
import Security
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
    case nfsMountFailed(Int32, reason: NFSMountFailureReason = .unknown, tool: NFSMountTool = .mountNFS)
    case nfsAuthorizationRequired

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
        case .keychainReadFailed(let status) where status == errSecCSBadObjectFormat || status == errSecCSReqFailed:
            return String(localized: "macOS could not validate this application while reading Keychain. Use a trusted, consistently signed build. Your saved password has not been changed.", bundle: .module)
        case .keychainReadFailed:
            return String(localized: "The saved password could not be read from Keychain. Allow access, unlock Keychain, or save the password again.", bundle: .module)
        case .cancellationFailed:
            return String(localized: "The previous mount request is still pending in macOS. Automatic retries are paused; the macOS network service may need to be restarted.", bundle: .module)
        case .authenticationRequired:
            return "Authentication required. Please add credentials."
        case .authenticationFailed:
            return "Authentication failed."
        case .nfsMountFailed(let status, let reason, _):
            return String(format: String(localized: "NFS mount failed (exit status %d). %@", bundle: .module), status, reason.message)
        case .nfsAuthorizationRequired:
            return String(localized: "Reserved-port NFS mounting needs administrator authorization. Open the server settings and authorize automatic NFS mounts, or disable reserved-port mode if the NAS allows it.", bundle: .module)
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
        case .invalidShare, .invalidURL, .timedOut, .keychainReadFailed, .cancellationFailed, .nfsAuthorizationRequired:
            return true
        case .mountFailed(let code) where code == EEXIST:
            return true
        case .nfsMountFailed(_, let reason, _):
            return reason.isNonRetryable
        default:
            return isAuthError
        }
    }
}

enum UnmountError: LocalizedError, Equatable {
    case toolFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .toolFailed(let status): return "diskutil could not unmount the volume (exit status \(status))."
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

    /// Read-only probes and tool execution are injectable for isolated regression tests.
    var networkMounts: (() -> [MountSnapshot])?
    var mountAlive: ((String) -> Bool)?
    var mountedPaths: (() -> Set<String>)?
    var runUnmountTool: (([String]) -> Error?)?
    var runNFSMountTool: ((String, [String]) throws -> NFSMountToolResult)?
    var nfsHomeDirectory = FileManager.default.homeDirectoryForCurrentUser
    var isNFSHelperInstalled: () -> Bool = { PrivilegedMountInstaller.isInstalled() }

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

    func mount(config: ServerConfig, silent: Bool = false, automatic: Bool = false, completion: @escaping (Result<String, Error>) -> Void) {
        let diagnostic = DiagnosticsService.shared.begin(.mount, protocolType: config.serverProtocol, automatic: automatic)
        let complete: (Result<String, Error>) -> Void = { result in
            if case .failure(let error) = result { diagnostic.finish(error: error) }
            else { diagnostic.finish() }
            completion(result)
        }
        switch config.serverProtocol {
        case .nfs:
            mountNFS(config: config, silent: silent || automatic, completion: complete)
        case .smb, .afp, .webdav:
            mountNetFS(config: config, silent: silent, completion: complete)
        }
    }

    /// Finder/other unmanaged mounts have no app-owned credential reference. Reuse
    /// session/guest authentication without importing URL passwords or showing NetFS login UI.
    func remountUnmanaged(url: URL, completion: @escaping (Result<String, Error>) -> Void) {
        guard let protocolType = NetworkProtocol.allCases.first(where: {
            $0.scheme == url.scheme || ($0 == .webdav && url.scheme == "http")
        }), let host = url.host,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            DispatchQueue.main.async { completion(.failure(MountError.invalidURL)) }
            return
        }
        let config = ServerConfig(alias: "", serverProtocol: protocolType,
            hostname: host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host,
            sharePath: url.path, username: components.user)
        components.user = nil
        components.password = nil
        guard let targetURL = components.url else {
            DispatchQueue.main.async { completion(.failure(MountError.invalidURL)) }
            return
        }
        let diagnostic = DiagnosticsService.shared.begin(.wakeReconnect, protocolType: protocolType, automatic: true)
        let complete: (Result<String, Error>) -> Void = { result in
            if case .failure(let error) = result { diagnostic.finish(error: error) } else { diagnostic.finish() }
            completion(result)
        }
        if protocolType == .nfs {
            // Unmanaged NFS has no configured reserved-port opt-in; never request elevation.
            guard url.port == nil else {
                DispatchQueue.main.async { complete(.failure(MountError.invalidURL)) }
                return
            }
            mountNFS(config: config, silent: true, completion: complete)
        } else {
            mountNetFS(config: config, targetURL: targetURL, completion: complete)
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
        if let networkMounts { return networkMounts() }
        let keys: [URLResourceKey] = [.volumeURLForRemountingKey, .volumeIsLocalKey]
        let mountedURLs = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys, options: []
        ) ?? []

        var snapshots: [MountSnapshot] = []

        for mountURL in mountedURLs {
            guard let values = try? mountURL.resourceValues(forKeys: Set(keys)) else { continue }
            if values.volumeIsLocal == true { continue }
            guard let sourceURL = values.volumeURLForRemounting,
                  var components = URLComponents(url: sourceURL, resolvingAgainstBaseURL: false) else { continue }
            components.password = nil
            guard let remountURL = components.url else { continue }

            let matchedServer = servers.first { MountSnapshot(serverID: nil, volumePath: mountURL.path, remountURL: remountURL).matches($0) }
            snapshots.append(MountSnapshot(
                serverID: matchedServer?.id,
                volumePath: mountURL.path,
                remountURL: remountURL
            ))
        }

        // Resource values can be unavailable on a stale or renamed volume. The kernel
        // mount source is a read-only fallback, never a guess based on /Volumes names.
        for mount in Self.systemMounts() where !snapshots.contains(where: { $0.volumePath == mount.path }) {
            guard let snapshot = Self.snapshot(path: mount.path, source: mount.source, fileSystem: mount.fileSystem) else { continue }
            snapshots.append(MountSnapshot(serverID: servers.first(where: { snapshot.matches($0) })?.id,
                                           volumePath: snapshot.volumePath, remountURL: snapshot.remountURL))
        }
        return snapshots
    }

    private static func systemMounts() -> [(path: String, source: String, fileSystem: String)] {
        var buffer: UnsafeMutablePointer<statfs>?
        // Unlike getmntinfo's shared static buffer, this variant owns its result per call.
        let count = getmntinfo_r_np(&buffer, MNT_NOWAIT)
        guard let buffer else { return [] }
        defer { free(buffer) }
        guard count > 0 else { return [] }
        return (0..<Int(count)).map { index in
            let mount = buffer[index]
            let path = withUnsafeBytes(of: mount.f_mntonname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            let source = withUnsafeBytes(of: mount.f_mntfromname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            let fileSystem = withUnsafeBytes(of: mount.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            return (path, source, fileSystem)
        }
    }

    static func snapshot(path: String, source: String, fileSystem: String) -> MountSnapshot? {
        let url: URL?
        switch fileSystem {
        case "smbfs": url = URL(string: source.hasPrefix("//") ? "smb:" + source : source)
        case "nfs":
            guard let separator = source.range(of: ":/") else { return nil }
            var host = String(source[..<separator.lowerBound])
            if host.contains(":") && !host.hasPrefix("[") { host = "[\(host)]" }
            url = URL(string: "nfs://\(host)" + String(source[separator.lowerBound...].dropFirst()))
        default: return nil
        }
        guard let url, url.host != nil, !url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty else { return nil }
        // A kernel source can include credentials. Keep only the non-secret remount URL.
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.password = nil
        guard let remountURL = components.url else { return nil }
        return MountSnapshot(serverID: nil, volumePath: path, remountURL: remountURL)
    }

    func unmount(mountPath: String, completion: @escaping (Error?) -> Void) {
        let diagnostic = DiagnosticsService.shared.begin(.unmount)
        DispatchQueue.global(qos: .utility).async {
            let error = self.unmountVolume(path: mountPath, force: false)
            diagnostic.finish(error: error)
            DispatchQueue.main.async { completion(error) }
        }
    }

    @discardableResult
    func forceUnmount(path: String) -> Error? {
        let diagnostic = DiagnosticsService.shared.begin(.forceUnmount)
        let error = unmountVolume(path: path, force: true)
        diagnostic.finish(error: error)
        return error
    }

    private func isVolumeMounted(at path: String) -> Bool {
        if let mountedPaths { return mountedPaths().contains(path) }
        return Self.systemMounts().contains { $0.path == path }
    }

    private func unmountVolume(path: String, force: Bool) -> Error? {
        // Another unmount may already have succeeded. Never force a plain directory.
        guard isVolumeMounted(at: path) else { return nil }
        let arguments = force ? ["unmount", "force", path] : ["unmount", path]
        let error: Error?
        if let runUnmountTool {
            error = runUnmountTool(arguments)
        } else {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
                error = process.terminationStatus == 0 ? nil : UnmountError.toolFailed(process.terminationStatus)
            } catch let launchError { error = launchError }
        }
        // A racing successful unmount makes a tool's nonzero exit harmless.
        return isVolumeMounted(at: path) ? error : nil
    }

    // MARK: - SMB/AFP/WebDAV Mount via NetFS

    private func mountNetFS(config: ServerConfig, silent: Bool = false, targetURL: URL? = nil, completion: @escaping (Result<String, Error>) -> Void) {
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

        guard let url = targetURL ?? URL(string: config.mountURLString) else {
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
                if let error = self.forceUnmount(path: existingPath) {
                    wrappedCompletion(.failure(error), true)
                    return
                }
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

    static func noUIOptions() -> CFMutableDictionary {
        let dict = NSMutableDictionary()
        dict[kNAUIOptionKey] = kNAUIOptionNoUI
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

        let nfsSource = "\(config.hostname):/\(cleanShare)"

        DispatchQueue.global(qos: .userInitiated).async {
            if let existingPath = self.findExistingMountPath(for: url) {
                if self.isMountAlive(existingPath) {
                    wrappedCompletion(.success(existingPath))
                    return
                }
                if let error = self.forceUnmount(path: existingPath) {
                    wrappedCompletion(.failure(error))
                    return
                }
            }

            do {
                let mountPoint: String
                let executable: String
                let arguments: [String]
                let tool: NFSMountTool
                if config.usesReservedNFSPort {
                    mountPoint = "/Volumes/\(URL(fileURLWithPath: cleanShare).lastPathComponent)"
                    guard !self.isVolumeMounted(at: mountPoint) else { throw MountError.mountFailed(EEXIST) }
                    if self.isNFSHelperInstalled() {
                        executable = "/usr/bin/sudo"
                        tool = .sudo
                        arguments = ["-n", PrivilegedMountInstaller.wrapperScriptPath, mountPoint, nfsSource]
                    } else {
                        guard !silent else {
                            wrappedCompletion(.failure(MountError.nfsAuthorizationRequired))
                            return
                        }
                        // Only the explicit reserved-port opt-in permits an administrator prompt.
                        let command = "mkdir -p \(self.shellEscape(mountPoint)) && /sbin/mount_nfs -o resvport,noowners,nosuid,nodev -- \(self.shellEscape(nfsSource)) \(self.shellEscape(mountPoint))"
                        executable = "/usr/bin/osascript"
                        tool = .appleScript
                        arguments = ["-e", "do shell script \"\(self.appleScriptEscape(command))\" with administrator privileges"]
                    }
                } else {
                    mountPoint = try Self.prepareNFSUserMountPoint(config: config, homeDirectory: self.nfsHomeDirectory,
                                                                 isMounted: self.isVolumeMounted(at:))
                    executable = "/sbin/mount_nfs"
                    tool = .mountNFS
                    arguments = ["-o", "noresvport,noowners,nosuid,nodev", "--", nfsSource, mountPoint]
                }
                let result: NFSMountToolResult
                if let run = self.runNFSMountTool {
                    result = try run(executable, arguments)
                } else {
                    result = try NFSMountToolResult.run(executable: executable, arguments: arguments, tool: tool)
                }
                if result.status == 0 {
                    wrappedCompletion(.success(mountPoint))
                } else {
                    logger.error("NFS mount failed: tool=\(tool.rawValue), status=\(result.status), reason=\(result.reason.rawValue)")
                    wrappedCompletion(.failure(MountError.nfsMountFailed(result.status, reason: result.reason, tool: tool)))
                }
            } catch {
                wrappedCompletion(.failure(error))
            }
        }
    }

    /// Each server gets its own directory so exports with the same basename do not collide.
    /// Refuse symlinks, other owners and nonempty mount points instead of covering user files.
    static func prepareNFSUserMountPoint(config: ServerConfig, homeDirectory: URL,
                                        isMounted: (String) -> Bool = { path in systemMounts().contains { $0.path == path } }) throws -> String {
        guard config.isValidMountTarget else { throw MountError.invalidShare }
        let base = homeDirectory.appendingPathComponent("NetworkMounts", isDirectory: true)
        let server = base.appendingPathComponent(config.id.uuidString, isDirectory: true)
        let mountPoint = server.appendingPathComponent(URL(fileURLWithPath: config.normalizedSharePath).lastPathComponent, isDirectory: true)
        let manager = FileManager.default
        for directory in [base, server, mountPoint] {
            // Check the kernel mount table before touching a possibly disconnected volume.
            guard !isMounted(directory.path) else { throw MountError.mountFailed(EEXIST) }
            var info = stat()
            if lstat(directory.path, &info) != 0 {
                guard errno == ENOENT else { throw CocoaError(.fileWriteNoPermission) }
                try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                guard lstat(directory.path, &info) == 0 else { throw CocoaError(.fileWriteNoPermission) }
            }
            guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), info.st_uid == getuid() else {
                throw CocoaError(.fileWriteNoPermission)
            }
        }
        guard try manager.contentsOfDirectory(atPath: mountPoint.path).isEmpty else {
            throw MountError.mountFailed(EEXIST)
        }
        return mountPoint.path
    }

    func isMountAlive(_ path: String) -> Bool {
        if let mountAlive { return mountAlive(path) }
        var isAlive = false
        let lock = NSLock()
        let semaphore = DispatchSemaphore(value: 0)

        DispatchQueue.global(qos: .background).async {
            let readable = FileManager.default.isReadableFile(atPath: path)
            lock.lock()
            isAlive = readable
            lock.unlock()
            semaphore.signal()
        }

        let result = semaphore.wait(timeout: .now() + 2.0)
        if result == .timedOut {
            return false
        }
        lock.lock()
        defer { lock.unlock() }
        return isAlive
    }
}
