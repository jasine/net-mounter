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
        let config = ServerConfig(alias: "hang", serverProtocol: .smb, hostname: "10.0.0.10", sharePath: "share")
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
}
