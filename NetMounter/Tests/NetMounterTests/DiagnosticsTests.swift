import Foundation
import Sentry
import XCTest
@testable import NetMounter

final class DiagnosticsTests: XCTestCase {
    func testMissingPreferenceDefaultsToEnabledWithoutPersistingOrStartingSDK() throws {
        let suite = "NetMounter.DiagnosticsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let diagnostics = DiagnosticsService(defaults: defaults)
        XCTAssertTrue(diagnostics.isEnabledByPreference)
        XCTAssertNil(defaults.object(forKey: DiagnosticsService.consentKey))
        XCTAssertFalse(SentrySDK.isEnabled)
    }

    func testSavedOptOutIsPreservedAcrossServiceInstances() throws {
        let suite = "NetMounter.DiagnosticsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let diagnostics = DiagnosticsService(defaults: defaults, cacheURL: cache)
        diagnostics.setEnabled(false)
        let restarted = DiagnosticsService(defaults: defaults, cacheURL: cache)
        XCTAssertFalse(restarted.isEnabledByPreference)
        restarted.startIfEnabled()
        XCTAssertEqual(defaults.object(forKey: DiagnosticsService.consentKey) as? Bool, false)
        XCTAssertFalse(SentrySDK.isEnabled)
    }

    func testSavedEnabledPreferenceIsPreserved() throws {
        let suite = "NetMounter.DiagnosticsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: DiagnosticsService.consentKey)
        XCTAssertTrue(DiagnosticsService(defaults: defaults).isEnabledByPreference)
        XCTAssertEqual(defaults.object(forKey: DiagnosticsService.consentKey) as? Bool, true)
    }

    func testDiagnosticsStringsUseThePackagedChineseLocalization() throws {
        let file = try XCTUnwrap(Bundle.module.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: "zh-Hans"))
        let bundle = try XCTUnwrap(Bundle(url: file.deletingLastPathComponent()))
        XCTAssertEqual(bundle.localizedString(forKey: "Diagnostics", value: nil, table: nil), "诊断")
        XCTAssertEqual(bundle.localizedString(forKey: "Share diagnostic data", value: nil, table: nil), "共享诊断数据")
        XCTAssertEqual(bundle.localizedString(forKey: "Send diagnostic test", value: nil, table: nil), "发送诊断测试")
    }

    func testFailureClassificationNeverUsesDescriptionsOrUnknownDomains() {
        let secret = "smb://alice:password@192.168.0.42/private-share"
        let failure = DiagnosticFailure(NSError(domain: secret, code: 42, userInfo: [NSLocalizedDescriptionKey: secret]))
        XCTAssertEqual(failure.family, "other")
        XCTAssertEqual(failure.code, 42)
        XCTAssertFalse(failure.expected)
        XCTAssertEqual(DiagnosticFailure(WOLError.invalidMACAddress("aa:bb:cc:dd:ee:ff")).family, "invalid_mac")
        XCTAssertEqual(DiagnosticFailure(WOLError.sendFailed(secret)).family, "wol_send")
    }

    func testExpectedCancellationAndBusyAreNotIssues() {
        XCTAssertTrue(DiagnosticFailure(ConnectionError.cancelled).expected)
        XCTAssertTrue(DiagnosticFailure(CocoaError(.userCancelled)).expected)
        XCTAssertTrue(DiagnosticFailure(MountError.mountFailed(EBUSY)).expected)
        XCTAssertTrue(DiagnosticFailure(KeychainManager.ReadError.status(-128)).expected)
        XCTAssertFalse(DiagnosticFailure(MountError.timedOut).expected)
        XCTAssertFalse(DiagnosticFailure(MountError.authenticationFailed).expected)
    }

    func testMeasurementCompletesOnlyOnceEvenAcrossThreads() {
        let lock = NSLock()
        var count = 0
        let measurement = DiagnosticMeasurement { _ in
            lock.lock()
            count += 1
            lock.unlock()
        }
        DispatchQueue.concurrentPerform(iterations: 100) { _ in measurement.finish() }
        XCTAssertEqual(count, 1)
    }

    func testOptOutDoesNotStartSDKAndPurgesOnlyDiagnosticsCache() throws {
        let suite = "NetMounter.DiagnosticsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cache = root.appendingPathComponent("diagnostics")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("pending sensitive data".utf8).write(to: cache.appendingPathComponent("pending"))
        try Data("keep".utf8).write(to: root.appendingPathComponent("config.json"))
        defaults.set(false, forKey: DiagnosticsService.consentKey)
        let diagnostics = DiagnosticsService(defaults: defaults, cacheURL: cache)
        diagnostics.startIfEnabled()
        diagnostics.sendTestEvent()
        diagnostics.begin(.mount).finish(error: MountError.timedOut)
        XCTAssertFalse(defaults.bool(forKey: DiagnosticsService.consentKey))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("config.json")), Data("keep".utf8))
        XCTAssertFalse(SentrySDK.isEnabled)
    }

    func testSDKOptionsDisableSensitiveAutomaticInstrumentation() {
        let diagnostics = DiagnosticsService()
        let options = Options()
        diagnostics.configure(options)
        XCTAssertFalse(options.sendDefaultPii)
        XCTAssertFalse(options.enableMemoryIntrospection)
        XCTAssertTrue(options.enableSwizzling)
        XCTAssertTrue(options.enableUncaughtNSExceptionReporting)
        XCTAssertFalse(options.enableAutoBreadcrumbTracking)
        XCTAssertFalse(options.enableNetworkBreadcrumbs)
        XCTAssertFalse(options.enableNetworkTracking)
        XCTAssertFalse(options.enableFileIOTracing)
        XCTAssertFalse(options.enableLogs)
        XCTAssertFalse(options.enableMetricKit)
        XCTAssertTrue(options.enableCrashHandler)
        XCTAssertTrue(options.attachStacktrace)
        XCTAssertEqual(options.tracesSampleRate?.doubleValue, 0.2)
        XCTAssertNotNil(options.beforeBreadcrumb)
        // Every signal callback is consent-gated, including traces.
        XCTAssertNil(options.beforeSend?(Event(level: .error)))
    }

    func testBreadcrumbsUseClosedVocabularyAndRemoveArbitraryData() throws {
        let crumb = Breadcrumb(level: .info, category: "netmounter")
        crumb.message = DiagnosticOperation.mount.rawValue
        crumb.setData(value: "failure", key: "outcome")
        crumb.setData(value: "192.168.0.42", key: "host")
        crumb.setData(value: "secret", key: "password")
        let sanitized = try XCTUnwrap(DiagnosticsService.sanitize(crumb))
        XCTAssertEqual(sanitized.data?.count, 1)
        XCTAssertEqual(sanitized.data?["outcome"] as? String, "failure")
        let network = Breadcrumb(level: .info, category: "http")
        network.message = "GET https://private.example.com"
        XCTAssertNil(DiagnosticsService.sanitize(network))
        crumb.message = "smb://alice:password@private/share"
        XCTAssertNil(DiagnosticsService.sanitize(crumb))
    }

    func testEventSanitizationRemovesIdentityTextAndPathsButKeepsStackAddresses() throws {
        let secret = "smb://alice:password@192.168.0.42/private-share"
        let event = Event(level: .error)
        event.message = SentryMessage(formatted: secret)
        event.error = NSError(domain: secret, code: 1)
        let user = User(userId: "alice")
        user.email = "alice@example.com"
        event.user = user
        event.serverName = "private-server"
        event.extra = ["password": "password", "config": secret]
        event.tags = ["host": secret, "operation": "mount", "error_family": "timeout", "error_code": "0", "protocol": "smb"]
        event.context = ["os": ["name": "macOS", "version": "14.0"], "device": ["name": "Alice's Mac", "arch": "arm64"], "config": ["url": secret]]
        let frame = Frame()
        frame.fileName = "/Users/alice/Code/NetMounter/MountingManager.swift"
        frame.package = "/Users/alice/Applications/NetMounter.app/Contents/MacOS/NetMounter"
        frame.instructionAddress = "0x1234"
        frame.lineNumber = 100
        frame.vars = ["url": secret]
        frame.contextLine = secret
        let stack = SentryStacktrace(frames: [frame], registers: [:])
        let exception = Exception(value: secret, type: "NSInvalidArgumentException")
        exception.stacktrace = stack
        let mechanism = Mechanism(type: "nsexception")
        mechanism.data = ["reason": secret]
        exception.mechanism = mechanism
        event.exceptions = [exception]
        let image = DebugMeta()
        image.codeFile = "/Users/alice/Applications/NetMounter.app/Contents/MacOS/NetMounter"
        image.debugID = "test-uuid"
        event.debugMeta = [image]
        let sanitized = DiagnosticsService.sanitize(event)
        XCTAssertNil(sanitized.user)
        XCTAssertNil(sanitized.error)
        XCTAssertNil(sanitized.extra)
        XCTAssertNil(sanitized.serverName)
        XCTAssertNil(sanitized.tags?["host"])
        XCTAssertNil(sanitized.context?["config"])
        XCTAssertNil(sanitized.context?["device"]?["name"])
        XCTAssertEqual(sanitized.context?["device"]?["arch"] as? String, "arm64")
        XCTAssertEqual(sanitized.message?.formatted, "mount failed (timeout:0)")
        XCTAssertEqual(exception.value, "Exception details removed for privacy")
        XCTAssertNil(exception.mechanism?.data)
        XCTAssertEqual(frame.fileName, "MountingManager.swift")
        XCTAssertEqual(frame.package, "NetMounter")
        XCTAssertEqual(frame.instructionAddress, "0x1234")
        XCTAssertEqual(frame.lineNumber, 100)
        XCTAssertNil(frame.vars)
        XCTAssertNil(frame.contextLine)
        XCTAssertEqual(image.codeFile, "NetMounter")
        XCTAssertEqual(image.debugID, "test-uuid")
        let payload = String(describing: sanitized.serialize())
        for forbidden in ["alice", "password", "192.168.0.42", "private-share", "/Users/"] {
            XCTAssertFalse(payload.contains(forbidden), payload)
        }
    }

    func testUnrecognizedMessagesAndFingerprintsAreDropped() {
        let event = Event(level: .fatal)
        event.message = SentryMessage(formatted: "password=secret")
        event.fingerprint = ["private-host"]
        event.transaction = "smb://private/share"
        event.tags = ["operation": "private-host", "error_family": "private-share", "error_code": "password"]
        DiagnosticsService.sanitize(event)
        XCTAssertNil(event.message)
        XCTAssertNil(event.fingerprint)
        XCTAssertNil(event.transaction)
        XCTAssertTrue(event.tags?.isEmpty == true)
    }
    func testContextAndExceptionNamesCannotCarryArbitraryText() throws {
        let secret = "smb://alice:password@private/share"
        let event = Event(level: .fatal)
        event.context = ["os": ["name": secret, "kernel_version": secret],
                         "app": ["app_identifier": secret, "app_version": secret],
                         "diagnostics": ["duration_ms": secret]]
        let exception = Exception(value: secret, type: secret)
        exception.module = secret
        exception.mechanism = Mechanism(type: secret)
        event.exceptions = [exception]
        DiagnosticsService.sanitize(event)
        XCTAssertEqual(exception.type, "NativeException")
        XCTAssertEqual(exception.mechanism?.type, "generic")
        XCTAssertNil(exception.module)
        XCTAssertFalse(String(describing: event.serialize()).contains("alice"))
    }

    func testBeforeSendAlsoGatesTransactionsInSDK9() {
        let options = Options()
        DiagnosticsService().configure(options)
        let event = Event(level: .info)
        event.type = "transaction"
        event.transaction = DiagnosticOperation.mount.rawValue
        XCTAssertNil(options.beforeSend?(event))
        XCTAssertNotNil(options.beforeSendSpan)
    }

}
