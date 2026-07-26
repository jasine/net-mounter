import Foundation

enum PrivilegedMountInstaller {

    static let wrapperScriptPath = "/Library/Application Support/NetMounter/nfs-mount.sh"
    static let sudoersPath = "/etc/sudoers.d/netmounter"

    /// Root-owned NFS mount helper. Installed root:wheel 755 so the sudoers
    /// NOPASSWD rule targets a fixed, tamper-proof script rather than a
    /// general-purpose mount binary. Guards restrict it to NFS mounts under /Volumes.
    static let wrapperScriptBody = """
    #!/bin/sh
    # NetMounter NFS mount helper. Installed root-owned; invoked via passwordless sudo.
    set -e
    MOUNTPOINT="$1"
    SOURCE="$2"
    case "$MOUNTPOINT" in
      /Volumes/*) ;;
      *) echo "refusing mountpoint outside /Volumes: $MOUNTPOINT" >&2; exit 1 ;;
    esac
    case "$MOUNTPOINT" in
      *..*) echo "refusing path traversal: $MOUNTPOINT" >&2; exit 1 ;;
    esac
    mkdir -p "$MOUNTPOINT"
    exec /sbin/mount_nfs -o resvport,noowners,nosuid,nodev -- "$SOURCE" "$MOUNTPOINT"
    """

    static func sudoersBody(user: String = NSUserName()) -> String {
        return #"\#(user) ALL=(root) NOPASSWD: /Library/Application\ Support/NetMounter/nfs-mount.sh"# + "\n"
    }

    static func isInstalled(fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Bool {
        fileExists(wrapperScriptPath) && fileExists(sudoersPath)
    }

    enum InstallResult {
        case installed
        case cancelled
        case failed(String)
    }

    /// Full shell script executed with administrator privileges. Hardcoded —
    /// no user input is interpolated. Writes the wrapper root-owned + the
    /// sudoers fragment, then syntax-checks sudoers and rolls back on failure.
    static func installScript() -> String {
        let dir = "/Library/Application Support/NetMounter"
        // Heredoc bodies are static constants; safe to embed.
        return """
        set -e
        mkdir -p "\(dir)"
        chown root:wheel "\(dir)"
        chmod 755 "\(dir)"
        cat > "\(wrapperScriptPath)" <<'NETMOUNTER_WRAPPER_EOF'
        \(wrapperScriptBody)
        NETMOUNTER_WRAPPER_EOF
        chown root:wheel "\(wrapperScriptPath)"
        chmod 755 "\(wrapperScriptPath)"
        cat > "\(sudoersPath)" <<'NETMOUNTER_SUDOERS_EOF'
        \(sudoersBody())NETMOUNTER_SUDOERS_EOF
        chmod 440 "\(sudoersPath)"
        if ! visudo -cf "\(sudoersPath)"; then
          rm -f "\(sudoersPath)"
          exit 2
        fi
        """
    }

    static func install(
        runOSAScript: @escaping (String) -> Int32 = defaultRunner,
        completion: @escaping (InstallResult) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let code = runOSAScript(installScript())
            let result: InstallResult
            switch code {
            case 0: result = .installed
            case 1: result = .cancelled   // osascript: user canceled auth dialog
            default: result = .failed("install exited with code \(code)")
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Default runner: escapes the script for AppleScript and runs it with
    /// administrator privileges (one system password prompt).
    static let defaultRunner: (String) -> Int32 = { shellScript in
        let escaped = shellScript
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let appleScript = "do shell script \"\(escaped)\" with administrator privileges"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", appleScript]
        do {
            try process.run()
        } catch {
            return -1
        }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
