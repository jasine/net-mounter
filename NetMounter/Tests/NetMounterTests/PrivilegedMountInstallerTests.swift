import XCTest
@testable import NetMounter

final class PrivilegedMountInstallerTests: XCTestCase {

    func testIsInstalled_bothFilesPresent_returnsTrue() {
        let present: Set<String> = [
            PrivilegedMountInstaller.wrapperScriptPath,
            PrivilegedMountInstaller.sudoersPath,
        ]
        XCTAssertTrue(PrivilegedMountInstaller.isInstalled { present.contains($0) })
    }

    func testIsInstalled_onlyScriptPresent_returnsFalse() {
        let present: Set<String> = [PrivilegedMountInstaller.wrapperScriptPath]
        XCTAssertFalse(PrivilegedMountInstaller.isInstalled { present.contains($0) })
    }

    func testIsInstalled_onlySudoersPresent_returnsFalse() {
        let present: Set<String> = [PrivilegedMountInstaller.sudoersPath]
        XCTAssertFalse(PrivilegedMountInstaller.isInstalled { present.contains($0) })
    }

    func testIsInstalled_neitherPresent_returnsFalse() {
        XCTAssertFalse(PrivilegedMountInstaller.isInstalled { _ in false })
    }

    func testWrapperScript_restrictsMountpointToVolumes() {
        // Guard clause must reject mountpoints outside /Volumes and reject path traversal.
        XCTAssertTrue(PrivilegedMountInstaller.wrapperScriptBody.contains("/Volumes/*"))
        XCTAssertTrue(PrivilegedMountInstaller.wrapperScriptBody.contains("*..*"))
        XCTAssertTrue(PrivilegedMountInstaller.wrapperScriptBody.contains("/sbin/mount_nfs"))
        // nosuid,nodev must be present to prevent setuid-root escalation via NFS export
        XCTAssertTrue(PrivilegedMountInstaller.wrapperScriptBody.contains("nosuid,nodev"))
    }

    func testSudoersBody_escapesSpaceInPath() {
        let body = PrivilegedMountInstaller.sudoersBody(user: "someuser")
        XCTAssertTrue(body.contains(#"/Library/Application\ Support/NetMounter/nfs-mount.sh"#))
        XCTAssertTrue(body.contains("NOPASSWD:"))
        XCTAssertTrue(body.hasPrefix("someuser ALL=(root) NOPASSWD:"))
    }

    func testInstallScript_writesBothFilesWithCorrectPermissions() {
        let script = PrivilegedMountInstaller.installScript()
        // Creates parent dir
        XCTAssertTrue(script.contains(#"mkdir -p "/Library/Application Support/NetMounter""#))
        // Locks dir ownership and permissions
        XCTAssertTrue(script.contains(#"chown root:wheel "/Library/Application Support/NetMounter""#))
        XCTAssertTrue(script.contains(#"chmod 755 "/Library/Application Support/NetMounter""#))
        // Writes script then chown/chmod
        XCTAssertTrue(script.contains("chown root:wheel"))
        XCTAssertTrue(script.contains("chmod 755"))
        // sudoers fragment is 440 and syntax-checked, rolled back on failure
        XCTAssertTrue(script.contains("chmod 440"))
        XCTAssertTrue(script.contains("visudo -cf"))
    }

    func testInstall_exitZero_installed() {
        let exp = expectation(description: "done")
        PrivilegedMountInstaller.install(runOSAScript: { _ in 0 }) { result in
            if case .installed = result {} else { XCTFail("expected installed") }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
    }

    func testInstall_exitOne_cancelled() {
        let exp = expectation(description: "done")
        PrivilegedMountInstaller.install(runOSAScript: { _ in 1 }) { result in
            if case .cancelled = result {} else { XCTFail("expected cancelled") }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
    }

    func testInstall_exitOther_failed() {
        let exp = expectation(description: "done")
        PrivilegedMountInstaller.install(runOSAScript: { _ in 42 }) { result in
            if case .failed = result {} else { XCTFail("expected failed") }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
    }
}
