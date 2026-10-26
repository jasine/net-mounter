import XCTest
@testable import NetMounter

final class ServerEditingTests: XCTestCase {
    func testPausingPreservesRulesAndCanResumeWithoutCurrentNetwork() {
        let network = NetworkFingerprint(ssid: "Home", interfaceType: .wifi)
        var config = ServerConfig(alias: "NAS", hostname: "nas.local", sharePath: "media",
                                  autoMountRules: [AutoMountRule(fingerprint: network)])
        let ruleID = config.autoMountRules[0].id
        config.setAutoMountEnabled(false, fingerprint: nil)
        XCTAssertEqual(config.autoMountRules.count, 1)
        XCTAssertEqual(config.autoMountRules[0].id, ruleID)
        XCTAssertEqual(config.autoMountRules[0].fingerprint, network)
        XCTAssertFalse(config.shouldAutoMount(for: network, isVPN: true))
        config.setAutoMountEnabled(true, fingerprint: nil)
        XCTAssertTrue(config.shouldAutoMount(for: network, isVPN: false))
    }

    func testEnablingAddsCurrentNetworkOnlyWhenNoRulesExist() {
        let network = NetworkFingerprint(ssid: "Home", interfaceType: .wifi)
        var config = ServerConfig(alias: "NAS", hostname: "nas.local", sharePath: "media")
        config.setAutoMountEnabled(true, fingerprint: nil)
        XCTAssertTrue(config.autoMountRules.isEmpty)
        config.setAutoMountEnabled(true, fingerprint: network)
        config.setAutoMountEnabled(true, fingerprint: network)
        XCTAssertEqual(config.autoMountRules.count, 1)
    }

    func testValidationRejectsBlankFieldsAndProtocolPrefixesForEveryProtocol() {
        for proto in NetworkProtocol.allCases {
            var config = ServerConfig(alias: "NAS", serverProtocol: proto, hostname: "nas.local", sharePath: "media")
            XCTAssertNil(config.validationMessage)
            config.sharePath = " / \\ "
            XCTAssertNotNil(config.validationMessage)
            config.sharePath = "media"
            config.hostname = "smb://nas.local"
            XCTAssertNotNil(config.validationMessage)
            config.hostname = " "
            XCTAssertNotNil(config.validationMessage)
            config.hostname = "nas.local"
            config.alias = " \n "
            XCTAssertNotNil(config.validationMessage)
        }
    }

    func testValidationAcceptsBracketedIPv6AndRejectsPortsOrURLSuffixes() {
        for proto in NetworkProtocol.allCases {
            var config = ServerConfig(alias: "NAS", serverProtocol: proto, hostname: "[2001:db8::1]", sharePath: "media")
            XCTAssertNil(config.validationMessage)
            XCTAssertEqual(URL(string: config.mountURLString)?.host, "2001:db8::1")
            for invalidHost in ["nas.local:445", "nas.local?query", "nas.local#fragment"] {
                config.hostname = invalidHost
                XCTAssertNotNil(config.validationMessage, invalidHost)
            }
        }
    }

    func testChangingInputsInvalidatesOutstandingReachabilityResult() {
        var check = ReachabilityCheckState()
        let oldRequest = check.start()
        check.reset()
        let newRequest = check.start()
        check.complete(request: oldRequest, reachable: true)
        XCTAssertTrue(check.isRunning)
        XCTAssertNil(check.result)
        check.complete(request: newRequest, reachable: false)
        XCTAssertFalse(check.isRunning)
        XCTAssertEqual(check.result, false)
        check.reset()
        XCTAssertNil(check.result)
    }

    func testOperationRefreshPreservesBusyAndFailureFeedback() {
        XCTAssertEqual(ServerOperation.connecting.refreshed(mountPath: nil, hasNetwork: true, mountInFlight: false), .connecting)
        let failure = ServerOperation.failed("Busy volume", mountPath: "/Volumes/media")
        XCTAssertEqual(failure.refreshed(mountPath: "/Volumes/media", hasNetwork: true, mountInFlight: false), failure)
        XCTAssertEqual(failure.refreshed(mountPath: nil, hasNetwork: true, mountInFlight: false), .idle)
        XCTAssertTrue(failure.isMounted)
        XCTAssertNotNil(failure.errorMessage)
        XCTAssertTrue(ServerOperation.disconnecting("/Volumes/media").isBusy)
    }

    func testPendingNativeMountKeepsCancellationFailureVisible() {
        let failure = ServerOperation.failed("Close and reopen NetMounter", mountPath: nil)
        XCTAssertEqual(failure.refreshed(mountPath: nil, hasNetwork: true, mountInFlight: true), failure)
    }

    func testMountFailureClearsWhenTheVolumeIsActuallyFound() {
        let failure = ServerOperation.failed("Timed out", mountPath: nil)
        XCTAssertEqual(failure.refreshed(mountPath: nil, hasNetwork: true, mountInFlight: false), failure)
        XCTAssertEqual(failure.refreshed(mountPath: "/Volumes/media-1", hasNetwork: false, mountInFlight: false), .mounted("/Volumes/media-1"))
    }

    func testNetworkLossDoesNotPretendAnExistingVolumeWasUnmounted() {
        XCTAssertEqual(ServerOperation.idle.refreshed(mountPath: "/Volumes/media", hasNetwork: false, mountInFlight: false), .mounted("/Volumes/media"))
        XCTAssertEqual(ServerOperation.idle.refreshed(mountPath: nil, hasNetwork: false, mountInFlight: false), .waitingForNetwork)
        XCTAssertEqual(ServerOperation.idle.refreshed(mountPath: nil, hasNetwork: true, mountInFlight: true), .connecting)
    }
}
