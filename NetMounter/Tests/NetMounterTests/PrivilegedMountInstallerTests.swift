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
    }

    func testSudoersBody_escapesSpaceInPath() {
        XCTAssertTrue(PrivilegedMountInstaller.sudoersBody.contains(#"/Library/Application\ Support/NetMounter/nfs-mount.sh"#))
        XCTAssertTrue(PrivilegedMountInstaller.sudoersBody.contains("NOPASSWD:"))
    }
}
