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

    // MARK: - D: SMB routes through NetFS

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

    // MARK: - Host:Port Parsing (Issue #13)
    // Users commonly enter "host:port" in the single hostname field, especially
    // for WebDAV on non-standard ports. Without parsing, the colon lands inside
    // URLComponents.host, which rejects it and makes mountURLString empty.

    func testParsedHost_plainHostname_hasNoPort() {
        let c = ServerConfig(alias: "a", serverProtocol: .webdav, hostname: "nas.local", sharePath: "d")
        XCTAssertEqual(c.parsedHost, "nas.local")
        XCTAssertNil(c.parsedPort)
    }

    func testParsedHost_ipv4WithPort_splitsCorrectly() {
        let c = ServerConfig(alias: "a", serverProtocol: .webdav, hostname: "192.168.31.249:5702", sharePath: "dav")
        XCTAssertEqual(c.parsedHost, "192.168.31.249")
        XCTAssertEqual(c.parsedPort, 5702)
    }

    func testParsedHost_bracketedIPv6WithPort_splitsCorrectly() {
        let c = ServerConfig(alias: "a", serverProtocol: .webdav, hostname: "[::1]:8080", sharePath: "dav")
        XCTAssertEqual(c.parsedHost, "::1")
        XCTAssertEqual(c.parsedPort, 8080)
    }

    func testParsedHost_bracketedIPv6WithoutPort_stripsBrackets() {
        let c = ServerConfig(alias: "a", serverProtocol: .webdav, hostname: "[fe80::1]", sharePath: "d")
        XCTAssertEqual(c.parsedHost, "fe80::1")
        XCTAssertNil(c.parsedPort)
    }

    func testParsedHost_bareIPv6WithoutPort_passesThrough() {
        // No brackets, multiple colons → clearly IPv6, no port.
        let c = ServerConfig(alias: "a", serverProtocol: .webdav, hostname: "fe80::1", sharePath: "d")
        XCTAssertEqual(c.parsedHost, "fe80::1")
        XCTAssertNil(c.parsedPort)
    }

    func testParsedHost_invalidPortSuffix_treatsWholeAsHost() {
        // Non-numeric suffix is not a port; leave the field untouched so the
        // user sees the same string in error messages.
        let c = ServerConfig(alias: "a", serverProtocol: .webdav, hostname: "host:notaport", sharePath: "d")
        XCTAssertEqual(c.parsedHost, "host:notaport")
        XCTAssertNil(c.parsedPort)
    }

    func testParsedHost_portOutOfRange_treatsWholeAsHost() {
        let c = ServerConfig(alias: "a", serverProtocol: .webdav, hostname: "host:70000", sharePath: "d")
        XCTAssertEqual(c.parsedHost, "host:70000")
        XCTAssertNil(c.parsedPort)
    }

    func testMountURLString_webdavWithCustomPort_includesPort() {
        // Regression for Issue #13: without port parsing, this URL was "".
        let c = ServerConfig(alias: "nas", serverProtocol: .webdav, hostname: "192.168.31.249:5702", sharePath: "dav")
        XCTAssertEqual(c.mountURLString, "https://192.168.31.249:5702/dav")
    }

    func testMountURLString_smbWithCustomPort_includesPort() {
        let c = ServerConfig(alias: "nas", serverProtocol: .smb, hostname: "10.0.0.1:4445", sharePath: "media")
        XCTAssertEqual(c.mountURLString, "smb://10.0.0.1:4445/media")
    }

    func testUrlString_webdavWithPortAndUsername_rendersBoth() {
        var c = ServerConfig(alias: "nas", serverProtocol: .webdav, hostname: "192.168.31.249:5702", sharePath: "dav")
        c.username = "jasine"
        // Display URL has credentials; mount URL does not — same port handling in both.
        XCTAssertEqual(c.urlString, "https://jasine@192.168.31.249:5702/dav")
        XCTAssertEqual(c.mountURLString, "https://192.168.31.249:5702/dav")
    }

    func testMountURLString_bracketedIPv6WithPort_includesBothCorrectly() {
        let c = ServerConfig(alias: "nas", serverProtocol: .smb, hostname: "[fe80::1]:4445", sharePath: "share")
        // URLComponents emits the host in brackets when it contains colons.
        XCTAssertEqual(c.mountURLString, "smb://[fe80::1]:4445/share")
    }

    func testIsValidMountTarget_unaffectedByHostnamePort() {
        // Port syntax in hostname must not change share-path validation —
        // the mount is still blocked if there's no share.
        let empty = ServerConfig(alias: "a", serverProtocol: .webdav, hostname: "nas.local:5702", sharePath: "")
        let full = ServerConfig(alias: "a", serverProtocol: .webdav, hostname: "nas.local:5702", sharePath: "dav")
        XCTAssertFalse(empty.isValidMountTarget)
        XCTAssertTrue(full.isValidMountTarget)
    }

}
