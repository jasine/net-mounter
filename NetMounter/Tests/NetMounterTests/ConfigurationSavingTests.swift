import XCTest
@testable import NetMounter

final class ConfigurationSavingTests: XCTestCase {
    @MainActor
    func testUnchangedPasswordNeverReadsWritesOrDeletesCredentials() async throws {
        let config = ServerConfig(alias: "Renamed NAS", hostname: "nas.local", sharePath: "media", keychainItemId: "old")
        let result = await ServerConfigurationSaver.save(config: config, passwordChange: .unchanged,
            savePassword: { _, _ in XCTFail("Unexpected credential write"); return nil },
            deletePassword: { _ in XCTFail("Unexpected credential deletion"); return false },
            persist: { saved in XCTAssertEqual(saved.keychainItemId, "old"); return .success(()) })
        XCTAssertEqual(try result.get().config.keychainItemId, "old")
    }

    @MainActor
    func testCredentialWriteFailureDoesNotSaveConfigurationOrDeleteOldPassword() async {
        let config = ServerConfig(alias: "NAS", hostname: "nas.local", sharePath: "media", keychainItemId: "old")
        let result = await ServerConfigurationSaver.save(config: config, passwordChange: .replace("new"),
            savePassword: { _, account in XCTAssertNotEqual(account, "old"); return nil },
            deletePassword: { _ in XCTFail("Must keep old password"); return false },
            persist: { _ in XCTFail("Must not save configuration"); return .success(()) })
        XCTAssertThrowsError(try result.get())
    }

    @MainActor
    func testConfigurationFailureRemovesOnlyStagedCredential() async {
        let config = ServerConfig(alias: "NAS", hostname: "nas.local", sharePath: "media", keychainItemId: "old")
        var deleted: [String] = []
        let result = await ServerConfigurationSaver.save(config: config, passwordChange: .replace("new"),
            savePassword: { _, _ in "staged" },
            deletePassword: { account in deleted.append(account); return true },
            persist: { saved in XCTAssertEqual(saved.keychainItemId, "staged"); return .failure(CocoaError(.fileWriteNoPermission)) })
        XCTAssertThrowsError(try result.get())
        XCTAssertEqual(deleted, ["staged"])
    }

    @MainActor
    func testReplacementDeletesOldCredentialOnlyAfterConfigurationIsSaved() async throws {
        let config = ServerConfig(alias: "NAS", hostname: "nas.local", sharePath: "media", keychainItemId: "old")
        var events: [String] = []
        let result = await ServerConfigurationSaver.save(config: config, passwordChange: .replace("new"),
            savePassword: { _, _ in events.append("stage"); return "new-id" },
            deletePassword: { account in events.append("delete-\(account)"); return true },
            persist: { _ in events.append("persist"); return .success(()) })
        XCTAssertEqual(try result.get().config.keychainItemId, "new-id")
        XCTAssertEqual(events, ["stage", "persist", "delete-old"])
    }

    @MainActor
    func testExplicitRemovalKeepsCredentialIfConfigurationWriteFails() async {
        let config = ServerConfig(alias: "NAS", hostname: "nas.local", sharePath: "media", keychainItemId: "old")
        let result = await ServerConfigurationSaver.save(config: config, passwordChange: .remove,
            savePassword: { _, _ in XCTFail("Unexpected write"); return nil },
            deletePassword: { _ in XCTFail("Must keep credential until configuration is saved"); return false },
            persist: { saved in XCTAssertNil(saved.keychainItemId); return .failure(CocoaError(.fileWriteNoPermission)) })
        XCTAssertThrowsError(try result.get())
    }

    @MainActor
    func testCleanupFailureIsReportedAfterSuccessfulSave() async throws {
        let config = ServerConfig(alias: "NAS", hostname: "nas.local", sharePath: "media", keychainItemId: "old")
        let result = await ServerConfigurationSaver.save(config: config, passwordChange: .remove,
            savePassword: { _, _ in XCTFail("Unexpected write"); return nil },
            deletePassword: { _ in false }, persist: { _ in .success(()) })
        let outcome = try result.get()
        XCTAssertNil(outcome.config.keychainItemId)
        XCTAssertTrue(outcome.credentialCleanupFailed)
    }

    @MainActor
    func testNFSSaveInstallsHelperByDefaultBeforePersisting() async throws {
        let config = ServerConfig(alias: "NAS", serverProtocol: .nfs, hostname: "nas.invalid", sharePath: "/volume1/media")
        var events: [String] = []
        let result = await ServerConfigurationSaver.save(config: config, passwordChange: .unchanged,
            isNFSHelperInstalled: { events.append("check"); return false },
            installNFSHelper: { events.append("install"); return .installed },
            savePassword: { _, _ in XCTFail("NFS must not write credentials"); return nil },
            deletePassword: { _ in XCTFail("NFS must not delete credentials"); return false },
            persist: { _ in events.append("persist"); return .success(()) })
        XCTAssertEqual(try result.get().config.id, config.id)
        XCTAssertEqual(events, ["check", "install", "persist"])
    }

    @MainActor
    func testNFSSaveSkipsAuthorizationWhenHelperIsAlreadyInstalled() async throws {
        let config = ServerConfig(alias: "NAS", serverProtocol: .nfs, hostname: "nas.invalid", sharePath: "/volume1/media")
        let result = await ServerConfigurationSaver.save(config: config, passwordChange: .unchanged,
            isNFSHelperInstalled: { true },
            installNFSHelper: { XCTFail("Must not authorize again"); return .cancelled },
            savePassword: { _, _ in XCTFail("Unexpected credential write"); return nil },
            deletePassword: { _ in XCTFail("Unexpected credential deletion"); return false },
            persist: { _ in .success(()) })
        XCTAssertEqual(try result.get().config.id, config.id)
    }

    @MainActor
    func testOtherProtocolsNeverCheckOrInstallNFSHelper() async throws {
        for proto in NetworkProtocol.allCases where proto != .nfs {
            let config = ServerConfig(alias: "NAS", serverProtocol: proto, hostname: "nas.invalid", sharePath: "media")
            let result = await ServerConfigurationSaver.save(config: config, passwordChange: .unchanged,
                isNFSHelperInstalled: { XCTFail("Unexpected NFS setup check for \(proto)"); return false },
                installNFSHelper: { XCTFail("Unexpected NFS installation for \(proto)"); return .cancelled },
                savePassword: { _, _ in XCTFail("Unexpected credential write"); return nil },
                deletePassword: { _ in XCTFail("Unexpected credential deletion"); return false },
                persist: { _ in .success(()) })
            XCTAssertEqual(try result.get().config.serverProtocol, proto)
        }
    }

    @MainActor
    func testNFSSetupCancellationOrFailureDoesNotSaveOrTouchCredentials() async {
        let original = ServerConfig(alias: "Original", serverProtocol: .nfs, hostname: "nas.invalid", sharePath: "/volume1/media", keychainItemId: "old")
        var edited = original
        edited.alias = "Edited"
        for installation in [PrivilegedMountInstaller.InstallResult.cancelled, .failed("fixture installation failure")] {
            var persisted = original
            let result = await ServerConfigurationSaver.save(config: edited, passwordChange: .replace("new"),
                isNFSHelperInstalled: { false }, installNFSHelper: { installation },
                savePassword: { _, _ in XCTFail("Must not write credentials before NFS setup succeeds"); return "new-id" },
                deletePassword: { _ in XCTFail("Must preserve credentials"); return true },
                persist: { persisted = $0; XCTFail("Must not save before NFS setup succeeds"); return .success(()) })
            XCTAssertThrowsError(try result.get()) { error in
                XCTAssertFalse(error.localizedDescription.isEmpty)
                if case .failed(let message) = installation {
                    XCTAssertTrue(error.localizedDescription.contains(message))
                }
            }
            XCTAssertEqual(persisted.alias, original.alias)
            XCTAssertEqual(persisted.keychainItemId, original.keychainItemId)
        }
    }

    @MainActor
    func testCancelledNFSSetupCanBeRetriedAndIsNotRepeatedAfterSuccess() async throws {
        let config = ServerConfig(alias: "NAS", serverProtocol: .nfs, hostname: "nas.invalid", sharePath: "/volume1/media")
        var installed = false
        var installCount = 0
        var persistCount = 0
        for attempt in 1...3 {
            let result = await ServerConfigurationSaver.save(config: config, passwordChange: .unchanged,
                isNFSHelperInstalled: { installed },
                installNFSHelper: {
                    installCount += 1
                    if attempt == 1 { return .cancelled }
                    installed = true
                    return .installed
                },
                savePassword: { _, _ in XCTFail("Unexpected credential write"); return nil },
                deletePassword: { _ in XCTFail("Unexpected credential deletion"); return false },
                persist: { _ in persistCount += 1; return .success(()) })
            if attempt == 1 {
                XCTAssertThrowsError(try result.get())
            } else {
                XCTAssertEqual(try result.get().config.id, config.id)
            }
        }
        XCTAssertEqual(installCount, 2)
        XCTAssertEqual(persistCount, 2)
    }

    func testOnlySuccessfulTargetChangesClearThePreviousOperation() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let state = AppState(configURL: folder.appendingPathComponent("config.json"))
        var config = ServerConfig(alias: "Original", hostname: "nas.invalid", sharePath: "media")
        try state.addServer(config).get()
        state.serverOperations[config.id] = .mounted("/Volumes/media")
        config.alias = "Renamed"
        try state.updateServer(config).get()
        XCTAssertEqual(state.serverOperations[config.id], .mounted("/Volumes/media"))
        config.sharePath = "other"
        try state.updateServer(config).get()
        XCTAssertEqual(state.serverOperations[config.id], .idle)
        state.serverOperations[config.id] = .failed("Busy", mountPath: "/Volumes/other")
        try FileManager.default.removeItem(at: folder)
        config.hostname = "changed.invalid"
        XCTAssertThrowsError(try state.updateServer(config).get())
        XCTAssertEqual(state.servers[0].hostname, "nas.invalid")
        XCTAssertEqual(state.serverOperations[config.id], .failed("Busy", mountPath: "/Volumes/other"))
    }

    func testFailedWritesDoNotPublishUnsavedAddEditOrRemoval() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let configURL = folder.appendingPathComponent("config.json")
        let state = AppState(configURL: configURL)
        var config = ServerConfig(alias: "Original", hostname: "nas.local", sharePath: "media")
        try state.addServer(config).get()
        let originalBytes = try Data(contentsOf: configURL)
        try FileManager.default.removeItem(at: folder)
        config.alias = "Changed"
        XCTAssertThrowsError(try state.updateServer(config).get())
        XCTAssertThrowsError(try state.removeServer(id: config.id).get())
        XCTAssertThrowsError(try state.addServer(ServerConfig(alias: "Other", hostname: "other.local", sharePath: "media")).get())
        XCTAssertEqual(state.servers.count, 1)
        XCTAssertEqual(state.servers[0].alias, "Original")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try originalBytes.write(to: configURL)
        XCTAssertEqual(AppState(configURL: configURL).servers[0].alias, "Original")
    }
}
