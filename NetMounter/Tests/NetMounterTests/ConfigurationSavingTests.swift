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
    func testNFSSavePersistsWithoutAuthorizationOrCredentials() async throws {
        for reservedPort in [false, true] {
            var config = ServerConfig(alias: "NAS", serverProtocol: .nfs, hostname: "nas.invalid", sharePath: "/volume1/media")
            config.usesReservedNFSPort = reservedPort
            var persisted = false
            let result = await ServerConfigurationSaver.save(config: config, passwordChange: .unchanged,
                savePassword: { _, _ in XCTFail("NFS must not write credentials"); return nil },
                deletePassword: { _ in XCTFail("NFS must not delete credentials"); return false },
                persist: { saved in
                    XCTAssertEqual(saved.usesReservedNFSPort, reservedPort)
                    persisted = true
                    return .success(())
                })
            XCTAssertEqual(try result.get().config.id, config.id)
            XCTAssertTrue(persisted)
        }
    }

    func testSavingHasNoPrivilegedInstallationEntryPoint() throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/NetMounter/Services/ServerConfigurationSaver.swift")
        XCTAssertFalse(try String(contentsOf: source).contains("PrivilegedMountInstaller"))
    }
}
