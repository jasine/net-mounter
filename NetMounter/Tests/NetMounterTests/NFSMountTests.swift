import Darwin
import XCTest
@testable import NetMounter

final class NFSMountTests: XCTestCase {
    private func fixture() throws -> (MountingManager, ServerConfig, URL) {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("NFSMountTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: home) }
        let manager = MountingManager()
        manager.nfsHomeDirectory = home
        manager.networkMounts = { [] }
        manager.mountedPaths = { [] }
        manager.mountAlive = { _ in false }
        manager.isNFSHelperInstalled = { false }
        manager.readPassword = { _ in XCTFail("NFS must not read Keychain"); return .failure(.status(-50)) }
        let config = ServerConfig(alias: "Fixture NAS", serverProtocol: .nfs, hostname: "nas.invalid", sharePath: "/exports/media")
        return (manager, config, home)
    }

    func testLegacyConfigurationDefaultsToUnprivilegedNFSAndExplicitModeRoundTrips() throws {
        let (_, config, _) = try fixture()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any])
        object.removeValue(forKey: "nfsReservedPort")
        let legacy = try JSONDecoder().decode(ServerConfig.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertFalse(legacy.usesReservedNFSPort)
        var reserved = legacy
        reserved.usesReservedNFSPort = true
        let decoded = try JSONDecoder().decode(ServerConfig.self, from: JSONEncoder().encode(reserved))
        XCTAssertTrue(decoded.usesReservedNFSPort)
    }

    func testDefaultMountUsesDirectToolAndOwnedUserDirectoryEvenWithHelperInstalled() throws {
        let (manager, config, home) = try fixture()
        manager.isNFSHelperInstalled = { XCTFail("Default mounts must ignore the privileged helper"); return true }
        manager.runNFSMountTool = { executable, arguments in
            XCTAssertEqual(executable, "/sbin/mount_nfs")
            XCTAssertEqual(arguments, ["-o", "noresvport,noowners,nosuid,nodev", "--", "nas.invalid:/exports/media",
                                       home.appendingPathComponent("NetworkMounts/\(config.id.uuidString)/media").path])
            let attributes = try FileManager.default.attributesOfItem(atPath: arguments.last!)
            XCTAssertEqual((attributes[.ownerAccountID] as? NSNumber)?.uint32Value, getuid())
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
            return NFSMountToolResult(status: 0)
        }
        let done = expectation(description: "Ordinary-user NFS mount")
        manager.mount(config: config) { result in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(try? result.get(), home.appendingPathComponent("NetworkMounts/\(config.id.uuidString)/media").path)
            XCTAssertFalse(manager.isMountInFlight(config.id))
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
    }

    func testAutomaticDefaultMountNeverRequestsElevation() throws {
        let (manager, config, _) = try fixture()
        manager.isNFSHelperInstalled = { XCTFail("No privileged check needed"); return false }
        manager.runNFSMountTool = { executable, _ in XCTAssertEqual(executable, "/sbin/mount_nfs"); return NFSMountToolResult(status: 0) }
        let done = expectation(description: "Automatic ordinary-user mount")
        manager.mount(config: config, automatic: true) { result in
            XCTAssertNotNil(try? result.get())
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
    }

    func testNFSToolFailuresDoNotBecomePasswordErrorsOrTriggerPrivilegedFallback() throws {
        for status in [Int32(1), 13, 17, 32] {
            let (manager, config, _) = try fixture()
            var calls = 0
            manager.isNFSHelperInstalled = { XCTFail("Tool failure must not trigger privileged fallback"); return true }
            manager.runNFSMountTool = { executable, _ in
                XCTAssertEqual(executable, "/sbin/mount_nfs")
                calls += 1
                return NFSMountToolResult(status: status)
            }
            let done = expectation(description: "NFS tool exit \(status)")
            manager.mount(config: config) { result in
                guard case .failure(let error) = result else { XCTFail("Expected tool failure"); done.fulfill(); return }
                XCTAssertEqual(error as? MountError, .nfsMountFailed(status))
                XCTAssertFalse((error as? MountError)?.isAuthError ?? true)
                XCTAssertEqual(DiagnosticFailure(error).family, "nfs_mount")
                XCTAssertEqual(DiagnosticFailure(error).code, Int(status))
                XCTAssertEqual(calls, 1)
                XCTAssertFalse(manager.isMountInFlight(config.id))
                done.fulfill()
            }
            wait(for: [done], timeout: 2)
        }
    }

    func testClassifiedFailureReachesTheCallerWithoutRawOutputOrPrivilegedFallback() throws {
        let (manager, config, _) = try fixture()
        manager.isNFSHelperInstalled = { XCTFail("Do not elevate after a permission error"); return false }
        manager.runNFSMountTool = { executable, _ in
            XCTAssertEqual(executable, "/sbin/mount_nfs")
            return NFSMountToolResult(status: 1, stderr: "mount_nfs: can't mount /exports/private-test-value from nas.invalid: Permission denied")
        }
        let done = expectation(description: "Classified NFS failure")
        manager.mount(config: config, automatic: true) { result in
            guard case .failure(let error) = result else { XCTFail("Expected failure"); done.fulfill(); return }
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(error as? MountError, .nfsMountFailed(1, reason: .permissionDenied))
            XCTAssertEqual(DiagnosticFailure(error).nfsReason, .permissionDenied)
            XCTAssertFalse(error.localizedDescription.contains("private-test-value"))
            XCTAssertFalse(error.localizedDescription.contains("nas.invalid"))
            XCTAssertFalse(manager.isMountInFlight(config.id))
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
    }

    func testReservedPortAutomaticMountWithoutHelperDoesNotPromptOrCreateDirectories() throws {
        let (manager, initial, home) = try fixture()
        var config = initial
        config.usesReservedNFSPort = true
        manager.runNFSMountTool = { _, _ in XCTFail("Automatic mounting must not request administrator authorization"); return NFSMountToolResult(status: 0) }
        let done = expectation(description: "Missing explicit authorization")
        // automatic=true must suppress authorization even if a caller forgets silent=true.
        manager.mount(config: config, automatic: true) { result in
            guard case .failure(let error) = result else { XCTFail("Expected authorization requirement"); done.fulfill(); return }
            XCTAssertEqual(error as? MountError, .nfsAuthorizationRequired)
            XCTAssertTrue(DiagnosticFailure(error).expected)
            XCTAssertTrue(MountError.nfsAuthorizationRequired.isNonRetryable)
            XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("NetworkMounts").path))
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
    }

    func testReservedPortAutomaticMountUsesInstalledHelperNoninteractively() throws {
        let (manager, initial, _) = try fixture()
        var config = initial
        config.usesReservedNFSPort = true
        manager.isNFSHelperInstalled = { true }
        manager.runNFSMountTool = { executable, arguments in
            XCTAssertEqual(executable, "/usr/bin/sudo")
            XCTAssertEqual(arguments, ["-n", PrivilegedMountInstaller.wrapperScriptPath, "/Volumes/media", "nas.invalid:/exports/media"])
            return NFSMountToolResult(status: 0)
        }
        let done = expectation(description: "Explicit reserved-port helper")
        manager.mount(config: config, silent: true, automatic: true) { result in
            XCTAssertEqual(try? result.get(), "/Volumes/media")
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
    }

    func testOnlyExplicitReservedPortManualMountPermitsAdministratorPrompt() throws {
        let (manager, initial, _) = try fixture()
        var config = initial
        config.usesReservedNFSPort = true
        manager.runNFSMountTool = { executable, arguments in
            XCTAssertEqual(executable, "/usr/bin/osascript")
            XCTAssertEqual(arguments.count, 2)
            XCTAssertEqual(arguments.first, "-e")
            XCTAssertTrue(arguments[1].hasSuffix("with administrator privileges"))
            XCTAssertTrue(arguments[1].contains("resvport,noowners,nosuid,nodev"))
            return NFSMountToolResult(status: 0)
        }
        let done = expectation(description: "Explicit administrator opt-in")
        manager.mount(config: config) { result in
            XCTAssertEqual(try? result.get(), "/Volumes/media")
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
    }

    func testExistingConnectedMountIsReusedWithoutMovingOrAuthorizing() throws {
        let (manager, initial, home) = try fixture()
        var config = initial
        config.usesReservedNFSPort = true
        manager.networkMounts = { [MountSnapshot(serverID: config.id, volumePath: "/Volumes/existing-media",
                                                 remountURL: URL(string: config.mountURLString)!)] }
        manager.mountAlive = { _ in true }
        manager.isNFSHelperInstalled = { XCTFail("Existing mounts need no authorization"); return false }
        manager.runNFSMountTool = { _, _ in XCTFail("Do not move an existing connected mount"); return NFSMountToolResult(status: 0) }
        let done = expectation(description: "Existing NFS mount")
        manager.mount(config: config, automatic: true) { result in
            XCTAssertEqual(try? result.get(), "/Volumes/existing-media")
            XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("NetworkMounts").path))
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
    }

    func testExportsWithSameBasenameHaveDistinctUserMountPoints() throws {
        let (_, first, home) = try fixture()
        var second = first
        second.id = UUID()
        second.hostname = "another-nas.invalid"
        let a = try MountingManager.prepareNFSUserMountPoint(config: first, homeDirectory: home)
        let b = try MountingManager.prepareNFSUserMountPoint(config: second, homeDirectory: home)
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(URL(fileURLWithPath: a).lastPathComponent, "media")
        XCTAssertEqual(URL(fileURLWithPath: b).lastPathComponent, "media")
    }

    func testNonemptyUserMountPointIsNotCoveredOrDeleted() throws {
        let (manager, config, home) = try fixture()
        let mountPoint = try MountingManager.prepareNFSUserMountPoint(config: config, homeDirectory: home)
        let file = URL(fileURLWithPath: mountPoint).appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: file)
        manager.runNFSMountTool = { _, _ in XCTFail("Do not mount over user files"); return NFSMountToolResult(status: 0) }
        let done = expectation(description: "Occupied user mount point")
        manager.mount(config: config) { result in
            guard case .failure(let error) = result else { XCTFail("Expected occupied directory"); done.fulfill(); return }
            XCTAssertEqual(error as? MountError, .mountFailed(EEXIST))
            XCTAssertEqual(try? String(contentsOf: file), "keep")
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
    }

    func testOtherVolumesAtAnyUserDirectoryLevelAreNotCoveredOrUnmounted() throws {
        for depth in 0...2 {
            let (manager, config, home) = try fixture()
            let components = ["NetworkMounts", config.id.uuidString, "media"]
            let occupied = components.prefix(depth + 1).reduce(home) { $0.appendingPathComponent($1) }.path
            manager.mountedPaths = { [occupied] }
            manager.runNFSMountTool = { _, _ in XCTFail("Do not cover another volume"); return NFSMountToolResult(status: 0) }
            manager.runUnmountTool = { _ in XCTFail("Do not unmount another volume"); return nil }
            let done = expectation(description: "Existing volume at level \(depth)")
            manager.mount(config: config) { result in
                guard case .failure(let error) = result else { XCTFail("Expected occupied path"); done.fulfill(); return }
                XCTAssertEqual(error as? MountError, .mountFailed(EEXIST))
                XCTAssertFalse(manager.isMountInFlight(config.id))
                done.fulfill()
            }
            wait(for: [done], timeout: 2)
        }
    }

    func testReservedPortMountDoesNotCoverOrUnmountAnotherVolume() throws {
        let (manager, initial, _) = try fixture()
        var config = initial
        config.usesReservedNFSPort = true
        manager.mountedPaths = { ["/Volumes/media"] }
        manager.isNFSHelperInstalled = { XCTFail("Do not authorize an occupied mount point"); return false }
        manager.runNFSMountTool = { _, _ in XCTFail("Do not cover another volume"); return NFSMountToolResult(status: 0) }
        manager.runUnmountTool = { _ in XCTFail("Do not unmount another volume"); return nil }
        let done = expectation(description: "Occupied reserved-port mount point")
        manager.mount(config: config) { result in
            guard case .failure(let error) = result else { XCTFail("Expected occupied path"); done.fulfill(); return }
            XCTAssertEqual(error as? MountError, .mountFailed(EEXIST))
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
    }

    func testFailedStaleNFSUnmountStopsBeforeCreatingDirectoriesOrMounting() throws {
        let (manager, config, home) = try fixture()
        let stalePath = "/Volumes/stale-media"
        manager.networkMounts = { [MountSnapshot(serverID: config.id, volumePath: stalePath,
                                                 remountURL: URL(string: config.mountURLString)!)] }
        manager.mountedPaths = { [stalePath] }
        manager.runUnmountTool = { arguments in
            XCTAssertEqual(arguments, ["unmount", "force", stalePath])
            return UnmountError.toolFailed(32)
        }
        manager.runNFSMountTool = { _, _ in XCTFail("Do not mount after failed stale-volume cleanup"); return NFSMountToolResult(status: 0) }
        let done = expectation(description: "Failed stale NFS cleanup")
        manager.mount(config: config) { result in
            guard case .failure(let error) = result else { XCTFail("Expected cleanup failure"); done.fulfill(); return }
            XCTAssertEqual(error as? UnmountError, .toolFailed(32))
            XCTAssertEqual(try? FileManager.default.contentsOfDirectory(atPath: home.path), [])
            XCTAssertFalse(manager.isMountInFlight(config.id))
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
    }

    func testNonDirectoryAtAnyUserDirectoryLevelIsPreservedAndRejected() throws {
        for depth in 0...2 {
            let (_, config, home) = try fixture()
            let components = ["NetworkMounts", config.id.uuidString, "media"]
            var path = home
            for component in components.prefix(depth) {
                path.appendPathComponent(component)
                try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
            }
            let file = path.appendingPathComponent(components[depth])
            try Data("keep".utf8).write(to: file)
            XCTAssertThrowsError(try MountingManager.prepareNFSUserMountPoint(config: config, homeDirectory: home))
            XCTAssertEqual(try String(contentsOf: file), "keep")
        }
    }

    func testUserMountDirectoryRejectsSymlinksAtEveryManagedLevel() throws {
        for depth in 0...2 {
            let (_, config, home) = try fixture()
            let components = ["NetworkMounts", config.id.uuidString, "media"]
            var path = home
            for component in components.prefix(depth) {
                path.appendPathComponent(component)
                try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
            }
            let outside = home.appendingPathComponent("outside")
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
            try FileManager.default.createSymbolicLink(at: path.appendingPathComponent(components[depth]), withDestinationURL: outside)
            XCTAssertThrowsError(try MountingManager.prepareNFSUserMountPoint(config: config, homeDirectory: home))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
        }
    }

    func testUserDirectoryPreparationRejectsTraversalWithoutCreatingAnything() throws {
        let (_, initial, home) = try fixture()
        var config = initial
        config.sharePath = "/exports/../media"
        XCTAssertThrowsError(try MountingManager.prepareNFSUserMountPoint(config: config, homeDirectory: home))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: home.path), [])
    }
}
