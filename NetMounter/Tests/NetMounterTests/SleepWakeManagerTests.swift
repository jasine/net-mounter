import XCTest
@testable import NetMounter

final class SleepWakeManagerTests: XCTestCase {
    @MainActor
    private func fixture() throws -> (AppState, NetworkMonitor, AutoMountService, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let state = AppState(configURL: folder.appendingPathComponent("config.json"))
        let network = NetworkMonitor(startMonitoring: false)
        network.currentFingerprint = NetworkFingerprint(ssid: "Fixture", interfaceType: .wifi)
        let service = AutoMountService(appState: state, networkMonitor: network,
            checkReachability: { _, _, _ in }, mountServer: { _, _, _ in XCTFail("Unexpected mount") })
        return (state, network, service, folder)
    }

    @MainActor
    func testSleepDoesNotBlockMainQueueOrForceAnAlreadyUnmountedVolume() async throws {
        let (state, network, service, folder) = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let unmounted = expectation(description: "Main-queue unmount callback")
        let timersDrained = expectation(description: "Fallback deadline passed")
        var forced = 0
        let manager = SleepWakeManager(appState: state, networkMonitor: network, autoMountService: service,
            observeWorkspace: false, unmountTimeout: 0.02,
            captureMounts: { _ in [MountSnapshot(serverID: nil, volumePath: "/Volumes/fixture",
                                                remountURL: URL(string: "smb://nas.invalid/share")!)] },
            unmount: { _, done in DispatchQueue.main.async { done(nil); unmounted.fulfill() } },
            forceUnmount: { _, done in forced += 1; done() })
        manager.prepareForSleep()
        XCTAssertTrue(service.isSuspendedForSleep)
        await fulfillment(of: [unmounted], timeout: 1)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { timersDrained.fulfill() }
        await fulfillment(of: [timersDrained], timeout: 1)
        XCTAssertEqual(forced, 0)
    }

    @MainActor
    func testEmptySnapshotStillWaitsForFreshNetworkAndResumesAutoMount() async throws {
        let (state, network, service, folder) = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let manager = SleepWakeManager(appState: state, networkMonitor: network, autoMountService: service,
            observeWorkspace: false, captureMounts: { _ in [] })
        manager.prepareForSleep()
        manager.reconnectAfterWake()
        XCTAssertNil(network.currentFingerprint, "A cached pre-sleep fingerprint must not reconnect")
        XCTAssertTrue(service.isSuspendedForSleep)
        network.currentFingerprint = NetworkFingerprint(ssid: "Fresh fixture", interfaceType: .wifi)
        let done = expectation(description: "Fresh network processed")
        DispatchQueue.main.async { done.fulfill() }
        await fulfillment(of: [done], timeout: 1)
        XCTAssertFalse(service.isSuspendedForSleep)
    }

    @MainActor
    func testWakeRestoresManagedManualMountUsingSavedCredentialReference() async throws {
        let (state, network, service, folder) = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let config = ServerConfig(alias: "Fixture", hostname: "nas.invalid", sharePath: "share",
                                  username: "fixture-user", keychainItemId: "fixture-key")
        try state.addServer(config).get()
        let restored = expectation(description: "Unified credential mount")
        let manager = SleepWakeManager(appState: state, networkMonitor: network, autoMountService: service,
            observeWorkspace: false,
            captureMounts: { _ in [MountSnapshot(serverID: config.id, volumePath: "/Volumes/fixture",
                                                remountURL: URL(string: config.mountURLString)!)] },
            unmount: { _, done in done(nil) }, forceUnmount: { _, done in XCTFail("Unexpected force"); done() },
            remount: { saved, done in
                XCTAssertEqual(saved.keychainItemId, "fixture-key")
                XCTAssertEqual(saved.username, "fixture-user")
                done(.success("/Volumes/fixture")); restored.fulfill()
            })
        manager.prepareForSleep()
        manager.reconnectAfterWake()
        network.currentFingerprint = NetworkFingerprint(ssid: "Fresh fixture", interfaceType: .wifi)
        await fulfillment(of: [restored], timeout: 1)
        XCTAssertEqual(state.serverOperations[config.id], .mounted("/Volumes/fixture"))
    }

    @MainActor
    func testDisconnectDuringWakeDoesNotConsumeTheOnlyReadySignal() async throws {
        let (state, network, service, folder) = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        var finishUnmount: ((Error?) -> Void)?
        var mounts = 0
        let restored = expectation(description: "Restored on the second ready signal")
        let manager = SleepWakeManager(appState: state, networkMonitor: network, autoMountService: service,
            observeWorkspace: false,
            captureMounts: { _ in [MountSnapshot(serverID: nil, volumePath: "/Volumes/fixture",
                                                remountURL: URL(string: "smb://nas.invalid/share")!)] },
            unmount: { _, done in finishUnmount = done },
            remountUnmanaged: { _, done in mounts += 1; done(.success("/Volumes/fixture")); restored.fulfill() })
        manager.prepareForSleep()
        manager.reconnectAfterWake()
        network.currentFingerprint = NetworkFingerprint(ssid: "First signal", interfaceType: .wifi)
        network.currentFingerprint = nil
        finishUnmount?(nil)
        let drained = expectation(description: "Stale signal rejected")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 1)
        XCTAssertEqual(mounts, 0)
        XCTAssertTrue(service.isSuspendedForSleep)
        network.currentFingerprint = NetworkFingerprint(ssid: "Second signal", interfaceType: .wifi)
        await fulfillment(of: [restored], timeout: 1)
        XCTAssertEqual(mounts, 1)
    }

    @MainActor
    func testWakeTimeoutEventuallyResumesAutomaticMounting() async throws {
        let (state, network, service, folder) = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let manager = SleepWakeManager(appState: state, networkMonitor: network, autoMountService: service,
            observeWorkspace: false, wakeTimeout: 0.01, captureMounts: { _ in [] })
        manager.prepareForSleep()
        manager.reconnectAfterWake()
        let drained = expectation(description: "Wake timeout completed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 1)
        XCTAssertFalse(service.isSuspendedForSleep)
    }

    @MainActor
    func testWakeWaitsForOriginalUnmountAfterForceCompletes() async throws {
        let (state, network, service, folder) = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let forced = expectation(description: "Force finished before original unmount")
        let restored = expectation(description: "Restore after both unmounts finish")
        var graceful: ((Error?) -> Void)?
        var mountCount = 0
        let manager = SleepWakeManager(appState: state, networkMonitor: network, autoMountService: service,
            observeWorkspace: false, unmountTimeout: 0.01,
            captureMounts: { _ in [MountSnapshot(serverID: nil, volumePath: "/Volumes/fixture",
                                                remountURL: URL(string: "smb://nas.invalid/share")!)] },
            unmount: { _, done in graceful = done },
            forceUnmount: { _, done in done(); forced.fulfill() },
            remountUnmanaged: { _, done in mountCount += 1; done(.success("/Volumes/fixture")); restored.fulfill() })
        manager.prepareForSleep()
        manager.reconnectAfterWake()
        network.currentFingerprint = NetworkFingerprint(ssid: "Fresh fixture", interfaceType: .wifi)
        await fulfillment(of: [forced], timeout: 1)
        let drained = expectation(description: "Force completion processed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 1)
        XCTAssertEqual(mountCount, 0, "A pending original unmount must not race a new mount")
        XCTAssertTrue(service.isSuspendedForSleep)
        graceful?(nil)
        await fulfillment(of: [restored], timeout: 1)
        XCTAssertEqual(mountCount, 1)
        XCTAssertFalse(service.isSuspendedForSleep)
        graceful?(nil)
        XCTAssertEqual(mountCount, 1, "Duplicate graceful completions must be ignored")
    }

    @MainActor
    func testWakeWaitsForForceFallbackAfterGracefulCompletion() async throws {
        let (state, network, service, folder) = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let forced = expectation(description: "Fallback started")
        let restored = expectation(description: "Restore after fallback")
        var graceful: ((Error?) -> Void)?
        var finishForce: (() -> Void)?
        var forceCount = 0
        var mountCount = 0
        let manager = SleepWakeManager(appState: state, networkMonitor: network, autoMountService: service,
            observeWorkspace: false, unmountTimeout: 0.01,
            captureMounts: { _ in [MountSnapshot(serverID: nil, volumePath: "/Volumes/fixture",
                                                remountURL: URL(string: "smb://nas.invalid/share")!)] },
            unmount: { _, done in graceful = done },
            forceUnmount: { _, done in forceCount += 1; finishForce = done; forced.fulfill() },
            remountUnmanaged: { _, done in mountCount += 1; done(.success("/Volumes/fixture")); restored.fulfill() })
        manager.prepareForSleep()
        manager.reconnectAfterWake()
        network.currentFingerprint = NetworkFingerprint(ssid: "Fresh fixture", interfaceType: .wifi)
        await fulfillment(of: [forced], timeout: 1)
        XCTAssertEqual(mountCount, 0)
        graceful?(nil)
        finishForce?()
        await fulfillment(of: [restored], timeout: 1)
        XCTAssertEqual(forceCount, 1)
        XCTAssertEqual(mountCount, 1)
    }
}
