import Foundation
import NetFS

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
        // Construct the URL with credentials if available
        var urlComponents = URLComponents(string: config.urlString)
        
        if let username = config.username, 
           let keyId = config.keychainItemId, 
           let password = KeychainManager.shared.retrievePassword(for: keyId) {
            urlComponents?.user = username
            urlComponents?.password = password
        }
        
        guard let url = urlComponents?.url else {
            completion(.failure(MountError.invalidURL))
            return
        }
        
        print("[Debug] Attempting to mount URL: \(url.absoluteString)")
        
        // NetFS requires a CFURL. Does not show UI by default if we provide info.
        // NetFSMountURLSync signature:
        // func NetFSMountURLSync(_ url: CFURL!, _ mountpath: CFURL!, _ user: CFString!, _ passwd: CFString!, _ open_options: CFMutableDictionary!, _ mount_options: CFMutableDictionary!, _ mountpoints: UnsafeMutablePointer<Unmanaged<CFArray>?>!) -> Int32
        
        // Running on background thread to strictly avoid blocking main thread, though Sync implies blocking.
        DispatchQueue.global(qos: .userInitiated).async {
            var mountpoints: Unmanaged<CFArray>? = nil
            
            // We can pass open_options to suppress UI if needed, but providing user/pass in URL usually suffices for "silent-ish" mount or prompts if fails.
            // To completely suppress UI we might need kNetFSAllowSubMountsKey or similar options, but let's start simple.
            
            let result = NetFSMountURLSync(url as CFURL, 
                                           nil, // Default mount path (/Volumes/ShareName)
                                           nil, // user provided in URL
                                           nil, // pass provided in URL
                                           nil, // open_options
                                           nil, // mount_options
                                           &mountpoints)
            
            if result == 0 {
                // Success
                if let mounts = mountpoints?.takeRetainedValue() as? [String], let firstMount = mounts.first {
                    completion(.success(firstMount))
                } else {
                    completion(.success("Mounted (Unknown Path)"))
                }
            } else if result == 17 || result == EEXIST {
                // EEXIST: Mount point exists or already mounted.
                if let existingPath = self.findExistingMountPath(for: url) {
                    // Check if the mount is actually responsive (zombie check)
                    if self.isMountAlive(existingPath) {
                         completion(.success(existingPath))
                    } else {
                        print("[MountingManager] Found zombie mount at \(existingPath). Force unmounting...")
                        // Force unmount
                        self.forceUnmount(path: existingPath)
                        // Retry mount once
                        print("[MountingManager] Retrying mount after cleanup...")
                        let retryResult = NetFSMountURLSync(url as CFURL, nil, nil, nil, nil, nil, &mountpoints)
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
        // Normalize the URL for comparison (remove user/pass scheme/host/path)
        // mountedVolumeURLs often look like file:///Volumes/Share
        // We need to check the volume resource values to see the source source URL (if available) or check Statfs
        
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeURLForRemountingKey]
        let mountedURLs = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [])
        
        // Trying to match hostname and path component
        // We only use targetShare for the heuristic check
        guard let targetShare = url.pathComponents.last else { return nil }
        
        for mountURL in mountedURLs ?? [] {
            if (try? mountURL.resourceValues(forKeys: Set(keys))) != nil {
                // strict match might be hard. 
                // Let's check if the mount path ends with the share name (heuristic)
                if mountURL.lastPathComponent == targetShare {
                     // We could also check statfs to be sure it's from the same host, but for now this is a reasonable fallback.
                     return mountURL.path
                }
            }
        }
        return nil
    }
    
    func unmount(mountPath: String, completion: @escaping (Error?) -> Void) {
        // ... (existing logic wrapper)
        // We reuse forceUnmount logic but async for the UI
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/umount")
        process.arguments = [mountPath]
        
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                completion(nil)
            } else {
                completion(MountError.mountFailed(process.terminationStatus))
            }
        } catch {
            completion(error)
        }
    }
    
    private func forceUnmount(path: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/umount")
        process.arguments = ["-f", path] // force
        try? process.run()
        process.waitUntilExit()
    }
    
    // Check if a mount path is responsive
    private func isMountAlive(_ path: String) -> Bool {
        var isAlive = false
        let semaphore = DispatchSemaphore(value: 0)
        
        // checking access or stat on a dead SMB mount can hang.
        // We run it on a separate background thread with a timeout.
        DispatchQueue.global(qos: .background).async {
            // "access" check usually fast, but if kernel hangs on SMB, this thread hangs.
            // We use FileManager attributesOfItem which calls stat.
            if FileManager.default.isReadableFile(atPath: path) {
                isAlive = true
            }
            semaphore.signal()
        }
        
        // Wait max 2 seconds for response
        let result = semaphore.wait(timeout: .now() + 2.0)
        if result == .timedOut {
            return false // Consider dead if timed out
        }
        return isAlive
    }
}
