import XCTest
@testable import NetMounter

final class MountingManagerTests: XCTestCase {

    // MARK: - B: SMB share path validation

    func testMountURLString_excludesCredentials_evenWhenUsernameSet() {
        var config = ServerConfig(alias: "nas", serverProtocol: .smb, hostname: "192.168.1.2", sharePath: "media")
        config.username = "jasine"
        // Display URL includes the username; mount URL must NOT (embedding it
        // AND passing it as a NetFS arg makes the mount hang).
        XCTAssertTrue(config.urlString.contains("jasine@"))
        XCTAssertEqual(config.mountURLString, "smb://192.168.1.2/media")
        XCTAssertFalse(config.mountURLString.contains("jasine"))
    }

    func testSMBConfig_emptySharePath_isNotValidMountTarget() {
        let config = ServerConfig(alias: "nas", serverProtocol: .smb, hostname: "192.168.1.2", sharePath: "")
        XCTAssertFalse(config.isValidMountTarget)
    }

    func testSMBConfig_slashOnlySharePath_isNotValidMountTarget() {
        let config = ServerConfig(alias: "nas", serverProtocol: .smb, hostname: "192.168.1.2", sharePath: "//")
        XCTAssertFalse(config.isValidMountTarget)
    }

    func testSMBConfig_realSharePath_isValidMountTarget() {
        let config = ServerConfig(alias: "nas", serverProtocol: .smb, hostname: "192.168.1.2", sharePath: "media")
        XCTAssertTrue(config.isValidMountTarget)
    }

    func testNFSConfig_emptySharePath_isNotValidMountTarget() {
        let config = ServerConfig(alias: "d", serverProtocol: .nfs, hostname: "192.168.1.2", sharePath: "")
        XCTAssertFalse(config.isValidMountTarget)
    }

    func testMount_emptySMBSharePath_failsFastWithoutHoldingLock() {
        let mgr = MountingManager.shared
        let config = ServerConfig(alias: "nas-empty", serverProtocol: .smb, hostname: "10.0.0.9", sharePath: "")
        let exp = expectation(description: "completion")
        var received: Result<String, Error>?
        mgr.mount(config: config) { result in
            received = result
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
        // Must fail (invalid target) and must NOT leave an in-flight lock behind.
        if case .failure = received {} else { XCTFail("expected failure for empty SMB share") }
        XCTAssertFalse(mgr.isMountInFlight(config.id), "lock must be released after invalid-target rejection")
    }

    // MARK: - C: SMB credential URL builder (percent-encoded)

    func testSMBMountURL_noCredentials() {
        let c = ServerConfig(alias: "n", serverProtocol: .smb, hostname: "192.168.1.2", sharePath: "media")
        XCTAssertEqual(c.smbMountURLString(password: nil), "smb://192.168.1.2/media")
    }

    func testSMBMountURL_userAndPassword_plain() {
        var c = ServerConfig(alias: "n", serverProtocol: .smb, hostname: "192.168.1.2", sharePath: "media")
        c.username = "jasine"
        XCTAssertEqual(c.smbMountURLString(password: "secret"), "smb://jasine:secret@192.168.1.2/media")
    }

    func testSMBMountURL_specialCharsPercentEncoded() {
        var c = ServerConfig(alias: "n", serverProtocol: .smb, hostname: "192.168.1.2", sharePath: "media")
        c.username = "user@dom"
        // "@", ":", "/", " " must be percent-encoded so the URL parses correctly.
        XCTAssertEqual(c.smbMountURLString(password: "p@ss:w/ d"),
                       "smb://user%40dom:p%40ss%3Aw%2F%20d@192.168.1.2/media")
    }

    func testSMBMountURL_usernameSetButPasswordEmpty_omitsColon() {
        var c = ServerConfig(alias: "n", serverProtocol: .smb, hostname: "192.168.1.2", sharePath: "media")
        c.username = "jasine"
        XCTAssertEqual(c.smbMountURLString(password: nil), "smb://jasine@192.168.1.2/media")
        XCTAssertEqual(c.smbMountURLString(password: ""), "smb://jasine@192.168.1.2/media")
    }

    // MARK: - A: timeout releases the in-flight lock

    func testMountError_invalidShareAndAuth_areNonRetryable() {
        XCTAssertTrue(MountError.invalidShare.isNonRetryable)
        XCTAssertTrue(MountError.authenticationRequired.isNonRetryable)
        XCTAssertTrue(MountError.invalidURL.isNonRetryable)
        // A transient failure (e.g. network) should still be retryable.
        XCTAssertFalse(MountError.mountFailed(60).isNonRetryable)
        XCTAssertFalse(MountError.timedOut.isNonRetryable)
    }

    func testNetFSMount_whenMountHangs_timesOutAndReleasesLock() {
        let mgr = MountingManager.shared
        let config = ServerConfig(alias: "hang", serverProtocol: .afp, hostname: "10.0.0.10", sharePath: "share")
        let exp = expectation(description: "timeout completion")
        var received: Result<String, Error>?

        // Inject a mount function that never calls back — simulates NetFSMountURLSync hang.
        mgr.performNetFSMount = { _, _, _, _ in
            // never call completion
        }
        mgr.netFSMountTimeout = 1.0

        mgr.mount(config: config) { result in
            received = result
            exp.fulfill()
        }
        wait(for: [exp], timeout: 3)

        guard case .failure(let err) = received else {
            XCTFail("expected timeout failure"); return
        }
        XCTAssertEqual(err as? MountError, MountError.timedOut)
        XCTAssertFalse(mgr.isMountInFlight(config.id), "lock must be released after timeout")

        // reset injected state so other tests are unaffected
        mgr.performNetFSMount = nil
        mgr.netFSMountTimeout = 30.0
    }

    // MARK: - D: SMB via mount_smbfs subprocess

    func testMountSMB_success_releasesLockAndReturnsPath() {
        let mgr = MountingManager.shared
        let config = ServerConfig(alias: "smb-ok", serverProtocol: .smb, hostname: "10.0.0.20", sharePath: "media")
        mgr.performSMBMount = { _, mountPoint, completion in completion(0, ""); return {} }
        let exp = expectation(description: "done")
        var received: Result<String, Error>?
        mgr.mount(config: config) { received = $0; exp.fulfill() }
        wait(for: [exp], timeout: 2)
        if case .success = received {} else { XCTFail("expected success") }
        XCTAssertFalse(mgr.isMountInFlight(config.id))
        mgr.performSMBMount = nil
    }

    func testMountSMB_authFailure_mapsToNonRetryable() {
        let mgr = MountingManager.shared
        let config = ServerConfig(alias: "smb-auth", serverProtocol: .smb, hostname: "10.0.0.21", sharePath: "media")
        // mount_smbfs exit 77 (EAUTH) with an "Authentication error" stderr.
        mgr.performSMBMount = { _, _, completion in completion(77, "mount_smbfs: server rejected the authentication: Authentication error"); return {} }
        let exp = expectation(description: "done")
        var received: Result<String, Error>?
        mgr.mount(config: config) { received = $0; exp.fulfill() }
        wait(for: [exp], timeout: 2)
        guard case .failure(let err) = received, let me = err as? MountError else {
            XCTFail("expected MountError failure"); return
        }
        XCTAssertTrue(me.isNonRetryable, "auth failure must not be retried")
        XCTAssertFalse(mgr.isMountInFlight(config.id))
        mgr.performSMBMount = nil
    }

    func testMountSMB_emptyShare_failsFastWithoutLock() {
        let mgr = MountingManager.shared
        let config = ServerConfig(alias: "smb-empty", serverProtocol: .smb, hostname: "10.0.0.22", sharePath: "")
        let exp = expectation(description: "done")
        var received: Result<String, Error>?
        mgr.mount(config: config) { received = $0; exp.fulfill() }
        wait(for: [exp], timeout: 2)
        if case .failure = received {} else { XCTFail("expected failure") }
        XCTAssertFalse(mgr.isMountInFlight(config.id))
    }

    func testMountSMB_timeout_killsCancelHandle() {
        let mgr = MountingManager.shared
        let config = ServerConfig(alias: "smb-hang", serverProtocol: .smb, hostname: "10.0.0.23", sharePath: "media")
        let exp = expectation(description: "timeout completion")
        var received: Result<String, Error>?
        var cancelInvoked = false

        // Runner never calls completion — simulates a hung mount_smbfs process.
        // Returns a cancel handle so we can verify it was called on timeout.
        mgr.performSMBMount = { _, _, _ in
            return { cancelInvoked = true }
        }
        mgr.netFSMountTimeout = 1.0

        mgr.mount(config: config) { result in
            received = result
            exp.fulfill()
        }
        wait(for: [exp], timeout: 3)

        guard case .failure(let err) = received else {
            XCTFail("expected timeout failure"); return
        }
        XCTAssertEqual(err as? MountError, MountError.timedOut)
        XCTAssertFalse(mgr.isMountInFlight(config.id), "lock must be released after timeout")
        XCTAssertTrue(cancelInvoked, "cancel handle must be invoked to kill the subprocess")

        mgr.performSMBMount = nil
        mgr.netFSMountTimeout = 30.0
    }

    func testMountSMB_authExitCode77_noStderr_isNonRetryable() {
        let mgr = MountingManager.shared
        let config = ServerConfig(alias: "smb-eauth", serverProtocol: .smb, hostname: "10.0.0.24", sharePath: "media")
        // Exit code 77 (EAUTH) with empty stderr — no "authentication" word.
        mgr.performSMBMount = { _, _, completion in
            completion(77, "")
            return {}
        }
        let exp = expectation(description: "done")
        var received: Result<String, Error>?
        mgr.mount(config: config) { received = $0; exp.fulfill() }
        wait(for: [exp], timeout: 2)
        guard case .failure(let err) = received, let me = err as? MountError else {
            XCTFail("expected MountError failure"); return
        }
        XCTAssertTrue(me.isNonRetryable, "EAUTH exit code must map to non-retryable auth failure")
        XCTAssertFalse(mgr.isMountInFlight(config.id))
        mgr.performSMBMount = nil
    }
}
