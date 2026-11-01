import Foundation

enum NFSMountTool: String {
    case mountNFS = "mount_nfs"
    case sudo
    case appleScript = "osascript"
}

enum NFSMountFailureReason: String {
    case unknown
    case permissionDenied = "permission_denied"
    case notFound = "not_found"
    case timeout
    case networkUnavailable = "network_unavailable"
    case invalidOptions = "invalid_options"
    case authorizationRequired = "authorization_required"
    case cancelled

    var isNonRetryable: Bool {
        switch self {
        case .unknown, .timeout, .networkUnavailable: return false
        default: return true
        }
    }

    var message: String {
        switch self {
        case .unknown:
            return String(localized: "The NFS tool did not provide a recognized failure reason. Check the NAS export permissions and connection; do not enable reserved-port mode based on the exit status alone.", bundle: .module)
        case .permissionDenied:
            return String(localized: "macOS or the NFS server denied permission. Check mount-directory ownership and NAS export/client permissions. Reserved-port mode requires administrator authorization and should only be enabled if the NAS requires it.", bundle: .module)
        case .notFound:
            return String(localized: "The NFS export or local mount directory was not found. Check the export path and mount directory.", bundle: .module)
        case .timeout:
            return String(localized: "The NFS request timed out. Check the network, firewall and NAS NFS service.", bundle: .module)
        case .networkUnavailable:
            return String(localized: "The NFS service could not be reached. Check the server address, network, firewall and NAS NFS service.", bundle: .module)
        case .invalidOptions:
            return String(localized: "The NFS tool rejected its arguments. This may be an application or helper compatibility problem, not a server-password error.", bundle: .module)
        case .authorizationRequired:
            return String(localized: "macOS did not authorize the reserved-port NFS tool. Review NFS administrator authorization in the server settings, or disable reserved-port mode if the NAS allows it.", bundle: .module)
        case .cancelled:
            return String(localized: "NFS administrator authorization was cancelled. No server password was changed.", bundle: .module)
        }
    }
}

/// Retain only a closed classification, never server addresses, paths or raw tool output.
struct NFSMountToolResult {
    let status: Int32
    let reason: NFSMountFailureReason

    init(status: Int32, stderr: String = "", tool: NFSMountTool = .mountNFS) {
        self.status = status
        guard status != 0 else { reason = .unknown; return }
        let lines = stderr.lowercased().split(whereSeparator: \.isNewline).map {
            // osascript appends the child exit code to shell-tool errors.
            String($0).trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: #" \(-?\d+\)$"#, with: "", options: .regularExpression)
        }
        func endsWith(_ messages: [String]) -> Bool {
            lines.contains { line in messages.contains { line.hasSuffix($0) } }
        }
        if tool == .appleScript && stderr.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("(-128)") {
            reason = .cancelled
        } else if (tool == .sudo && endsWith(["a password is required", "a terminal is required to read the password", "no tty present and no askpass program specified", "is not in the sudoers file.", "is not allowed to run sudo on this host."]))
                    || (tool == .appleScript && stderr.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("(-60005)")) {
            reason = .authorizationRequired
        } else if endsWith(["permission denied", "operation not permitted", "access denied"]) {
            reason = .permissionDenied
        } else if endsWith(["no such file or directory"]) {
            reason = .notFound
        } else if endsWith(["timed out", "operation timed out"]) {
            reason = .timeout
        } else if endsWith(["connection refused", "no route to host", "network is unreachable", "program not registered", "broken pipe"])
                    || lines.contains(where: { $0.hasPrefix("mount_nfs: no usable addresses for host:") }) {
            reason = .networkUnavailable
        } else if lines.contains(where: { line in
            ["mount_nfs: illegal option", "mount_nfs: invalid option", "mount_nfs: unknown option", "usage: mount_nfs"].contains(where: line.hasPrefix)
        }) {
            reason = .invalidOptions
        } else {
            reason = .unknown
        }
    }

    static func run(executable: String, arguments: [String], tool: NFSMountTool) throws -> Self {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        process.environment = environment
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = FileHandle.nullDevice
        defer {
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
        }
        try process.run()
        try? pipe.fileHandleForWriting.close()
        // Drain while the tool runs, before waiting for exit, so a full pipe cannot deadlock.
        // Cap retained bytes even when the tool emits much more output; nothing is written to disk.
        var output = Data()
        var truncated = false
        while let chunk = try pipe.fileHandleForReading.read(upToCount: 4096), !chunk.isEmpty {
            let remaining = max(0, 16_384 - output.count)
            if chunk.count > remaining { truncated = true }
            output.append(chunk.prefix(remaining))
        }
        process.waitUntilExit()
        // A cut-off path may end with an error-like name; classify only complete lines.
        if truncated {
            if let newline = output.lastIndex(of: 0x0A) {
                output.removeSubrange(output.index(after: newline)..<output.endIndex)
            } else {
                output.removeAll()
            }
        }
        return Self(status: process.terminationStatus, stderr: String(decoding: output, as: UTF8.self), tool: tool)
    }
}
