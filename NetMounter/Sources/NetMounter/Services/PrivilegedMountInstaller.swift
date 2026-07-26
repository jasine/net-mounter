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
    exec /sbin/mount_nfs -o resvport,noowners "$SOURCE" "$MOUNTPOINT"
    """

    static let sudoersBody = #"ALL ALL=(root) NOPASSWD: /Library/Application\ Support/NetMounter/nfs-mount.sh"# + "\n"

    static func isInstalled(fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Bool {
        fileExists(wrapperScriptPath) && fileExists(sudoersPath)
    }
}
