import Security
import XCTest
@testable import NetMounter

final class MountingManagerTests: XCTestCase {

    func testFindExistingMountPath_matchesMountSourceNotLocalDirectoryName() {
        let cases: [(String, String, String, String, String?)] = [
            ("suffixed mount", "smb://192.168.1.2/media", "/Volumes/media-1", "smb://jasine@192.168.1.2/media", "/Volumes/media-1"),
            ("renamed mount", "smb://192.168.1.2/media", "/Volumes/NAS Media", "smb://192.168.1.2/media", "/Volumes/NAS Media"),
            ("different host", "smb://192.168.1.2/media", "/Volumes/media", "smb://192.168.1.3/media", nil),
            ("different protocol", "smb://192.168.1.2/media", "/Volumes/media", "afp://192.168.1.2/media", nil),
            ("different share", "smb://192.168.1.2/media", "/Volumes/media", "smb://192.168.1.2/photos", nil),
            ("full NFS export", "nfs://192.168.1.2/volume1/docker", "/Volumes/docker-1", "nfs://192.168.1.2/volume1/docker", "/Volumes/docker-1"),
            ("different NFS export", "nfs://192.168.1.2/volume1/docker", "/Volumes/docker", "nfs://192.168.1.2/volume2/docker", nil),
            ("host case and trailing slash", "smb://mynas.local/media/", "/Volumes/media", "smb://MyNAS.local/media", "/Volumes/media"),
            ("empty share", "smb://192.168.1.2/", "/Volumes/media", "smb://192.168.1.2/media", nil),
        ]
        let manager = MountingManager()
        for (name, target, volumePath, source, expectedPath) in cases {
            let snapshot = MountSnapshot(serverID: nil, volumePath: volumePath, remountURL: URL(string: source)!)
            XCTAssertEqual(
                manager.findExistingMountPath(for: URL(string: target)!, in: [snapshot]),
                expectedPath,
                name
            )
        }
        XCTAssertNil(manager.findExistingMountPath(for: URL(string: "smb://192.168.1.2/media")!, in: []))
    }

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

    func testNFSRejectsTraversalAndOptionLikeHostsBeforeSystemAccess() {
        let manager = MountingManager()
        let cases = [("nas.invalid", "."), ("nas.invalid", ".."),
                     ("nas.invalid", "/exports/../.."), ("nas.invalid", " /\n "),
                     ("-nas", "/exports/media")]
        for (host, share) in cases {
            let config = ServerConfig(alias: "Fixture", serverProtocol: .nfs, hostname: host, sharePath: share)
            XCTAssertNotNil(config.validationMessage)
            let done = expectation(description: "invalid NFS target rejected")
            manager.mount(config: config) { result in
                XCTAssertTrue(Thread.isMainThread)
                guard case .failure(let error) = result else {
                    XCTFail("Invalid NFS target should not start a mount")
                    done.fulfill()
                    return
                }
                XCTAssertTrue((error as? MountError)?.isNonRetryable == true)
                done.fulfill()
            }
            wait(for: [done], timeout: 1)
            XCTAssertFalse(manager.isMountInFlight(config.id))
        }
    }

    // MARK: - A: timeout releases the in-flight lock

    func testMountError_invalidShareAndAuth_areNonRetryable() {
        XCTAssertTrue(MountError.invalidShare.isNonRetryable)
        XCTAssertTrue(MountError.authenticationRequired.isNonRetryable)
        XCTAssertTrue(MountError.invalidURL.isNonRetryable)
        // A transient failure (e.g. network) should still be retryable.
        XCTAssertFalse(MountError.mountFailed(60).isNonRetryable)
        XCTAssertTrue(MountError.timedOut.isNonRetryable)
    }

    func testNetFSMount_whenMountHangs_timesOutAndReleasesLock() {
        let mgr = MountingManager.shared
        let config = ServerConfig(alias: "hang", serverProtocol: .afp, hostname: "10.0.0.10", sharePath: "share")
        let exp = expectation(description: "timeout completion")
        var received: Result<String, Error>?

        // Inject a cancellable request that never calls back.
        mgr.performNetFSMount = { _, _, _, _ in
            return { 0 } // never call completion
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
    func testTimeoutCancelsNativeRequestBeforeAllowingRetry() {
        let manager = MountingManager()
        let config = ServerConfig(alias: "fixture", serverProtocol: .smb, hostname: "timeout.invalid", sharePath: "share")
        let done = expectation(description: "cancelled timeout")
        manager.netFSMountTimeout = 0.05
        var cancellations = 0
        manager.performNetFSMount = { _, _, _, _ in
            return {
                XCTAssertTrue(manager.isMountInFlight(config.id))
                cancellations += 1
                return 0
            }
        }
        manager.mount(config: config) { result in
            XCTAssertEqual(result.failure as? MountError, .timedOut)
            XCTAssertEqual(cancellations, 1)
            XCTAssertFalse(manager.isMountInFlight(config.id))
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
    }

    func testFailedCancellationKeepsPendingRequestFromBeingDuplicated() {
        let manager = MountingManager()
        let config = ServerConfig(alias: "fixture", serverProtocol: .smb, hostname: "pending.invalid", sharePath: "share")
        manager.netFSMountTimeout = 0.05
        let timedOut = expectation(description: "cancel failed")
        let rejected = expectation(description: "duplicate rejected")
        var calls = 0
        manager.performNetFSMount = { _, _, _, _ in
            calls += 1
            return { EIO }
        }
        manager.mount(config: config) { result in
            XCTAssertEqual(result.failure as? MountError, .cancellationFailed(EIO))
            XCTAssertTrue(manager.isMountInFlight(config.id))
            manager.mount(config: config) { retry in
                XCTAssertEqual(retry.failure as? MountError, .mountFailed(EBUSY))
                XCTAssertEqual(calls, 1)
                rejected.fulfill()
            }
            timedOut.fulfill()
        }
        wait(for: [timedOut, rejected], timeout: 2)
    }

    func testKeychainFailureStopsMountInsteadOfUsingAnEmptyPassword() {
        let manager = MountingManager()
        var config = ServerConfig(alias: "fixture", serverProtocol: .smb, hostname: "credential.invalid", sharePath: "share")
        config.keychainItemId = "fixture-key"
        let done = expectation(description: "credential failure")
        manager.readPassword = { key in
            XCTAssertFalse(Thread.isMainThread)
            XCTAssertEqual(key, "fixture-key")
            return .failure(.status(errSecUserCanceled))
        }
        manager.performNetFSMount = { _, _, _, _ in
            XCTFail("NetFS must not start after Keychain failure")
            return { 0 }
        }
        manager.mount(config: config) { result in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(result.failure as? MountError, .keychainReadFailed(errSecUserCanceled))
            XCTAssertFalse(manager.isMountInFlight(config.id))
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
    }

    func testAuthorizationWaitDoesNotConsumeMountTimeout() {
        let manager = MountingManager()
        var config = ServerConfig(alias: "fixture", serverProtocol: .smb, hostname: "authorized.invalid", sharePath: "share")
        config.username = "fixture-user"
        config.keychainItemId = "fixture-key"
        manager.netFSMountTimeout = 0.05
        let reading = expectation(description: "reading credentials")
        let done = expectation(description: "mount succeeded")
        let allowRead = DispatchSemaphore(value: 0)
        manager.readPassword = { _ in
            reading.fulfill()
            _ = allowRead.wait(timeout: .now() + 2)
            return .success("fixture-password")
        }
        manager.performNetFSMount = { url, user, password, completion in
            XCTAssertEqual(url.absoluteString, "smb://authorized.invalid/share")
            XCTAssertEqual(user, "fixture-user")
            XCTAssertEqual(password, "fixture-password")
            completion(.success("/Volumes/fixture"))
            return { XCTFail("successful mount must not be cancelled"); return 0 }
        }
        manager.mount(config: config) { result in
            XCTAssertEqual(try? result.get(), "/Volumes/fixture")
            done.fulfill()
        }
        wait(for: [reading], timeout: 2)
        let uiResponsive = expectation(description: "main queue responsive during authorization")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertTrue(manager.isMountInFlight(config.id))
            uiResponsive.fulfill()
            allowRead.signal()
        }
        wait(for: [uiResponsive, done], timeout: 2)
    }

    func testLateResultAfterTimeoutDoesNotCompleteOrReleaseANewerMount() {
        let manager = MountingManager()
        let config = ServerConfig(alias: "fixture", serverProtocol: .smb, hostname: "late.invalid", sharePath: "share")
        manager.netFSMountTimeout = 0.05
        let done = expectation(description: "timeout")
        let retried = expectation(description: "retry started")
        var originalCallback: ((MountingManager.NetFSMountResult) -> Void)?
        manager.performNetFSMount = { _, _, _, callback in
            originalCallback = callback
            return { 0 }
        }
        manager.mount(config: config) { result in
            XCTAssertEqual(result.failure as? MountError, .timedOut)
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
        manager.netFSMountTimeout = 5
        manager.performNetFSMount = { _, _, _, callback in
            originalCallback?(.success("/Volumes/late-fixture"))
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
                XCTAssertTrue(manager.isMountInFlight(config.id))
                callback(.success("/Volumes/retry-fixture"))
            }
            retried.fulfill()
            return { 0 }
        }
        let secondDone = expectation(description: "retry completion")
        manager.mount(config: config) { result in
            XCTAssertEqual(try? result.get(), "/Volumes/retry-fixture")
            secondDone.fulfill()
        }
        wait(for: [retried, secondDone], timeout: 2)
    }

    func testNativeErrorIsReportedWithoutWaitingForTimeout() {
        let manager = MountingManager()
        let config = ServerConfig(alias: "fixture", serverProtocol: .smb, hostname: "failure.invalid", sharePath: "share")
        let done = expectation(description: "native error")
        manager.performNetFSMount = { _, _, _, callback in
            callback(.failure(EACCES))
            return { XCTFail("completed request must not be cancelled"); return 0 }
        }
        manager.mount(config: config) { result in
            XCTAssertEqual(result.failure as? MountError, .mountFailed(EACCES))
            XCTAssertFalse(manager.isMountInFlight(config.id))
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
    }

    func testLateCallbackAfterFailedCancellationReleasesPendingGuard() {
        let manager = MountingManager()
        let config = ServerConfig(alias: "fixture", serverProtocol: .smb, hostname: "cancel-failed.invalid", sharePath: "share")
        manager.netFSMountTimeout = 0.05
        let timeout = expectation(description: "reported cancellation failure")
        var finishNativeRequest: ((MountingManager.NetFSMountResult) -> Void)?
        manager.performNetFSMount = { _, _, _, callback in
            finishNativeRequest = callback
            return { EIO }
        }
        manager.mount(config: config) { result in
            XCTAssertEqual(result.failure as? MountError, .cancellationFailed(EIO))
            timeout.fulfill()
        }
        wait(for: [timeout], timeout: 2)
        let refreshed = expectation(description: "late completion refreshes state")
        let observer = NotificationCenter.default.addObserver(forName: .mountStateDidChange, object: nil, queue: .main) { _ in
            XCTAssertFalse(manager.isMountInFlight(config.id))
            refreshed.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        finishNativeRequest?(.failure(EIO))
        wait(for: [refreshed], timeout: 2)
    }

    func testKeychainAndCancellationFailuresAreNotRetriedAutomatically() {
        XCTAssertTrue(MountError.keychainReadFailed(errSecInteractionNotAllowed).isNonRetryable)
        XCTAssertTrue(MountError.cancellationFailed(EIO).isNonRetryable)
    }

}

private extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
