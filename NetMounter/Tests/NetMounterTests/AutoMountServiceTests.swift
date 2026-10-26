import XCTest
@testable import NetMounter

final class AutoMountServiceTests: XCTestCase {
    @MainActor
    private func drainCallbacks() async {
        let drained = expectation(description: "Main-queue callbacks drained")
        DispatchQueue.main.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 1)
    }

    @MainActor
    func testPausedRuleRejectsAnOutstandingReachabilityCallback() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let state = AppState(configURL: folder.appendingPathComponent("config.json"))
        let network = NetworkMonitor(startMonitoring: false)
        let fingerprint = NetworkFingerprint(ssid: "Test network", interfaceType: .wifi)
        network.currentFingerprint = fingerprint
        var config = ServerConfig(alias: "Test NAS", hostname: "nas.invalid", sharePath: "media",
                                  autoMountRules: [AutoMountRule(fingerprint: fingerprint)])
        try state.addServer(config).get()
        var callback: ((Result<Bool, Error>) -> Void)?
        var checks = 0
        let service = AutoMountService(appState: state, networkMonitor: network,
            checkReachability: { _, _, completion in checks += 1; callback = completion },
            mountServer: { _, _, _ in XCTFail("A paused rule must not initiate a mount") })
        service.attemptMount(config)
        XCTAssertEqual(state.serverOperations[config.id], .connecting)
        config.setAutoMountEnabled(false, fingerprint: nil)
        try state.updateServer(config).get()
        callback?(.success(true))
        await drainCallbacks()
        XCTAssertEqual(state.serverOperations[config.id], .idle)
        service.attemptMount(config, retryCount: 1)
        XCTAssertEqual(checks, 1)
    }

    @MainActor
    func testQueuedSnapshotsRejectChangedTargetsCredentialsAndDeletion() {
        let fingerprint = NetworkFingerprint(ssid: "Test network", interfaceType: .wifi)
        let original = ServerConfig(alias: "NAS", hostname: "nas.invalid", sharePath: "media",
                                    keychainItemId: "old", autoMountRules: [AutoMountRule(fingerprint: fingerprint)])
        var renamed = original
        renamed.alias = "New label"
        XCTAssertEqual(AutoMountService.currentEnabledServer(original, in: [renamed])?.alias, "New label")
        var changed = original
        changed.sharePath = "other"
        XCTAssertNil(AutoMountService.currentEnabledServer(original, in: [changed]))
        changed = original
        changed.keychainItemId = "replacement"
        XCTAssertNil(AutoMountService.currentEnabledServer(original, in: [changed]))
        XCTAssertNil(AutoMountService.currentEnabledServer(original, in: []))
    }

    @MainActor
    func testPausingDoesNotPretendAnAlreadySubmittedMountWasCancelled() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let state = AppState(configURL: folder.appendingPathComponent("config.json"))
        let network = NetworkMonitor(startMonitoring: false)
        let fingerprint = NetworkFingerprint(ssid: "Test network", interfaceType: .wifi)
        network.currentFingerprint = fingerprint
        var config = ServerConfig(alias: "NAS", hostname: "nas.invalid", sharePath: "media",
                                  autoMountRules: [AutoMountRule(fingerprint: fingerprint)], wolMACAddress: "00:11:22:33:44:55")
        try state.addServer(config).get()
        var completion: ((Result<String, Error>) -> Void)?
        var mounts = 0
        let service = AutoMountService(appState: state, networkMonitor: network,
            checkReachability: { _, _, callback in callback(.success(true)) },
            mountServer: { _, _, callback in mounts += 1; completion = callback })
        service.attemptMount(config)
        await drainCallbacks()
        XCTAssertEqual(mounts, 1)
        config.setAutoMountEnabled(false, fingerprint: nil)
        try state.updateServer(config).get()
        completion?(.success("/Volumes/test-fixture"))
        await drainCallbacks()
        XCTAssertEqual(state.serverOperations[config.id], .mounted("/Volumes/test-fixture"))
        service.attemptMount(config, retryCount: 1)
        XCTAssertEqual(mounts, 1)
    }

    @MainActor
    func testTerminalFailuresDoNotRestartFromHealthChecks() async throws {
        for error in [MountError.timedOut, .cancellationFailed(5), .keychainReadFailed(-25308)] {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let state = AppState(configURL: folder.appendingPathComponent("config.json"))
            let network = NetworkMonitor(startMonitoring: false)
            let fingerprint = NetworkFingerprint(ssid: "Test network", interfaceType: .wifi)
            network.currentFingerprint = fingerprint
            let config = ServerConfig(alias: "NAS", hostname: "nas.invalid", sharePath: "media",
                                      autoMountRules: [AutoMountRule(fingerprint: fingerprint)])
            try state.addServer(config).get()
            var mounts = 0
            let service = AutoMountService(appState: state, networkMonitor: network,
                checkReachability: { _, _, callback in callback(.success(true)) },
                mountServer: { _, _, callback in mounts += 1; callback(.failure(error)) })
            service.attemptMount(config)
            await drainCallbacks()
            await drainCallbacks()
            XCTAssertEqual(mounts, 1)
            XCTAssertEqual(state.serverOperations[config.id], .failed(error.localizedDescription, mountPath: nil))
            // The periodic health check uses the same retryCount=0 entry point.
            service.attemptMount(config)
            await drainCallbacks()
            await drainCallbacks()
            XCTAssertEqual(mounts, 1, "A terminal failure must stay failed, not loop back to connecting")
            XCTAssertFalse(state.serverOperations[config.id]?.isBusy ?? true)
            service.retryMount(config.id)
            await drainCallbacks()
            await drainCallbacks()
            XCTAssertEqual(mounts, 2, "The explicit notification retry must still work")
            service.attemptMount(config)
            await drainCallbacks()
            await drainCallbacks()
            XCTAssertEqual(mounts, 2, "A second failure must pause automatic attempts again")
        }
    }

    @MainActor
    func testExhaustedRetryBudgetCannotRestartOnTheSameNetwork() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let state = AppState(configURL: folder.appendingPathComponent("config.json"))
        let network = NetworkMonitor(startMonitoring: false)
        let fingerprint = NetworkFingerprint(ssid: "Test network", interfaceType: .wifi)
        network.currentFingerprint = fingerprint
        let config = ServerConfig(alias: "NAS", hostname: "nas.invalid", sharePath: "media",
                                  autoMountRules: [AutoMountRule(fingerprint: fingerprint)])
        try state.addServer(config).get()
        var checks = 0
        let service = AutoMountService(appState: state, networkMonitor: network,
            checkReachability: { _, _, callback in checks += 1; callback(.success(false)) },
            mountServer: { _, _, _ in XCTFail("An unreachable host must not mount") })
        service.attemptMount(config, retryCount: 5)
        await drainCallbacks()
        XCTAssertEqual(checks, 1)
        service.attemptMount(config)
        await drainCallbacks()
        XCTAssertEqual(checks, 1)
        XCTAssertFalse(state.serverOperations[config.id]?.isBusy ?? true)
    }


    @MainActor
    func testNetworkAndConfigurationChangesAllowANewAttempt() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let state = AppState(configURL: folder.appendingPathComponent("config.json"))
        let network = NetworkMonitor(startMonitoring: false)
        let first = NetworkFingerprint(ssid: "First network", interfaceType: .wifi)
        let second = NetworkFingerprint(ssid: "Second network", interfaceType: .wifi)
        network.currentFingerprint = first
        var config = ServerConfig(alias: "NAS", hostname: "nas.invalid", sharePath: "media",
                                  autoMountRules: [AutoMountRule(fingerprint: first), AutoMountRule(fingerprint: second)])
        try state.addServer(config).get()
        var mounts = 0
        let service = AutoMountService(appState: state, networkMonitor: network,
            checkReachability: { _, _, callback in callback(.success(true)) },
            mountServer: { _, _, callback in mounts += 1; callback(.failure(MountError.timedOut)) })
        service.attemptMount(config)
        await drainCallbacks()
        await drainCallbacks()
        XCTAssertEqual(mounts, 1)
        network.currentFingerprint = second
        service.attemptMount(config)
        await drainCallbacks()
        await drainCallbacks()
        XCTAssertEqual(mounts, 2)
        config.username = "test-user"
        try state.updateServer(config).get()
        await drainCallbacks()
        service.attemptMount(config)
        await drainCallbacks()
        await drainCallbacks()
        XCTAssertEqual(mounts, 3)
    }

    @MainActor
    func testInitialNetworkEvaluationDoesNotClearATerminalFailure() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let state = AppState(configURL: folder.appendingPathComponent("config.json"))
        let network = NetworkMonitor(startMonitoring: false)
        let fingerprint = NetworkFingerprint(ssid: "Test network", interfaceType: .wifi)
        network.currentFingerprint = fingerprint
        let config = ServerConfig(alias: "NAS", hostname: "nas.invalid", sharePath: "media",
                                  autoMountRules: [AutoMountRule(fingerprint: fingerprint)])
        try state.addServer(config).get()
        let unwantedRetry = expectation(description: "No retry after the initial debounced network evaluation")
        unwantedRetry.isInverted = true
        var mounts = 0
        let service = AutoMountService(appState: state, networkMonitor: network,
            checkReachability: { _, _, callback in callback(.success(true)) },
            mountServer: { _, _, callback in
                mounts += 1
                if mounts > 1 { unwantedRetry.fulfill() }
                callback(.failure(MountError.keychainReadFailed(-25308)))
            })
        service.attemptMount(config)
        await fulfillment(of: [unwantedRetry], timeout: 3)
        XCTAssertEqual(mounts, 1)
        XCTAssertFalse(state.serverOperations[config.id]?.isBusy ?? true)
        withExtendedLifetime(service) {}
    }

}
