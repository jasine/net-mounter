import Foundation
import Sentry

/// Diagnostics with a persisted user opt-out. This is the only boundary allowed to send app data to Sentry.
final class DiagnosticsService {
    static let shared = DiagnosticsService()
    static let consentKey = "diagnosticsEnabled"
    static let defaultEnabled = true
    // Public ingestion key, not an API/authentication token.
    static let dsn = "https://5b3c520b6fc7bd91098c74bc9e88dcd8@o4512272169172992.ingest.us.sentry.io/4512317660725248"

    private let defaults: UserDefaults
    private let cacheURL: URL
    private let lock = NSRecursiveLock()
    private var enabled = false
    private var generation = 0
    private var lastFailures: [String: TimeInterval] = [:]

    init(defaults: UserDefaults = .standard, cacheURL: URL? = nil) {
        self.defaults = defaults
        self.cacheURL = cacheURL ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NetMounterDiagnostics", isDirectory: true)
    }

    var isEnabledByPreference: Bool {
        defaults.object(forKey: Self.consentKey) as? Bool ?? Self.defaultEnabled
    }

    func startIfEnabled() {
        setEnabled(isEnabledByPreference)
    }

    /// Called on the main thread at startup or from Settings. The SDK stays off when the user has disabled collection.
    func setEnabled(_ value: Bool, persist: Bool = true) {
        lock.lock()
        if persist { defaults.set(value, forKey: Self.consentKey) }
        guard value != enabled else {
            lock.unlock()
            if !value { purgeCache() }
            return
        }
        enabled = value
        generation += 1
        lastFailures.removeAll()
        lock.unlock()
        if value {
            SentrySDK.start { options in
                self.configure(options)
            }
        } else {
            // Stop new captures first. SDK close can finish reports queued while collection was on.
            // Best-effort deletion prevents retained reports when collection is enabled again.
            SentrySDK.close()
            purgeCache()
        }
    }

    func configure(_ options: Options) {
        options.dsn = Self.dsn
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "development"
        options.releaseName = "net-mounter@\(version)"
        options.dist = info["CFBundleVersion"] as? String ?? "development"
        #if DEBUG
        options.environment = "development"
        #else
        options.environment = "production"
        #endif
        options.cacheDirectoryPath = cacheURL.path
        options.sendDefaultPii = false
        options.enableMemoryIntrospection = false
        options.enableUncaughtNSExceptionReporting = true
        options.attachStacktrace = true
        // Screenshot/view hierarchy collection is not supported by the macOS SDK.
        // Required for uncaught macOS NSExceptions; other swizzled collectors stay disabled.
        options.enableSwizzling = true
        options.enableAutoBreadcrumbTracking = false
        options.enableNetworkBreadcrumbs = false
        options.enableNetworkTracking = false
        options.enableFileIOTracing = false
        options.enableCoreDataTracing = false
        options.enableAutoPerformanceTracing = false
        options.enableMetrics = false
        options.enableLogs = false
        options.enableMetricKit = false
        // Keychain/admin authorization deliberately blocks; avoid misleading hang reports.
        options.enableAppHangTracking = false
        options.tracesSampleRate = 0.2
        #if DEBUG
        // Isolated end-to-end verifier also proves transaction ingestion.
        if ProcessInfo.processInfo.environment["NETMOUNTER_SENTRY_VERIFY"] == "1" {
            options.tracesSampleRate = 1.0
        }
        #endif
        options.maxBreadcrumbs = 80
        options.add(inAppInclude: "NetMounter")
        options.beforeBreadcrumb = { breadcrumb in Self.sanitize(breadcrumb) }
        // SDK 9.x uses beforeSend for both errors and transactions.
        options.beforeSend = { [weak self] event in
            guard self?.isEnabled == true else { return nil }
            if event is Transaction {
                guard DiagnosticOperation(rawValue: event.transaction ?? "") != nil else { return nil }
            }
            return Self.sanitize(event)
        }
        // We create only root operation transactions, never automatic child spans.
        options.beforeSendSpan = { _ in nil }
    }

    private var isEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return enabled
    }

    func breadcrumb(_ operation: DiagnosticOperation, outcome: String = "started") {
        lock.lock()
        defer { lock.unlock() }
        guard enabled else { return }
        let crumb = Breadcrumb(level: .info, category: "netmounter")
        crumb.message = operation.rawValue
        crumb.setData(value: outcome, key: "outcome")
        SentrySDK.addBreadcrumb(crumb)
    }

    func begin(_ operation: DiagnosticOperation, protocolType: NetworkProtocol? = nil,
               automatic: Bool? = nil, reportFailure: Bool = true) -> DiagnosticMeasurement {
        lock.lock()
        defer { lock.unlock() }
        guard enabled else { return DiagnosticMeasurement { _ in } }
        let currentGeneration = generation
        let start = ProcessInfo.processInfo.systemUptime
        let span = SentrySDK.startTransaction(name: operation.rawValue, operation: "netmounter.operation")
        if let protocolType { span.setTag(value: protocolType.rawValue, key: "protocol") }
        if let automatic { span.setTag(value: automatic ? "automatic" : "manual", key: "trigger") }
        breadcrumb(operation)
        return DiagnosticMeasurement { [weak self] error in
            guard let self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            // An operation crossing an off/on cycle must not revive old data.
            guard self.enabled, self.generation == currentGeneration else { return }
            let duration = max(0, ProcessInfo.processInfo.systemUptime - start)
            let failure = error.map(DiagnosticFailure.init)
            span.setData(value: duration * 1_000, key: "duration_ms")
            span.setTag(value: error == nil ? "success" : "failure", key: "outcome")
            self.breadcrumb(operation, outcome: error == nil ? "success" : "failure")
            if let failure, reportFailure, !failure.expected {
                self.capture(operation, failure: failure, duration: duration, protocolType: protocolType,
                             automatic: automatic, span: span)
            }
            span.finish(status: error == nil ? .ok : (failure?.expected == true ? .cancelled : .internalError))
        }
    }

    private func capture(_ operation: DiagnosticOperation, failure: DiagnosticFailure, duration: TimeInterval,
                         protocolType: NetworkProtocol?, automatic: Bool?, span: Span) {
        let key = "\(operation.rawValue):\(failure.family):\(failure.code):\(protocolType?.rawValue ?? "none")"
        let now = ProcessInfo.processInfo.systemUptime
        lastFailures = lastFailures.filter { now - $0.value < 60 }
        if operation != .verification {
            guard lastFailures[key] == nil, lastFailures.count < 20 else { return }
            lastFailures[key] = now
        }
        // Construct a fresh event instead of sending NSError.userInfo or localizedDescription.
        let message = "\(operation.rawValue) failed (\(failure.family):\(failure.code))"
        let event = Event(level: .error)
        event.message = SentryMessage(formatted: message)
        event.tags = ["operation": operation.rawValue, "error_family": failure.family,
                      "error_code": String(failure.code)]
        if let protocolType { event.tags?["protocol"] = protocolType.rawValue }
        if let automatic { event.tags?["trigger"] = automatic ? "automatic" : "manual" }
        event.fingerprint = [operation.rawValue, failure.family, String(failure.code), protocolType?.rawValue ?? "none"]
        event.context = ["diagnostics": ["duration_ms": duration * 1_000]]
        SentrySDK.capture(event: event) { scope in
            scope.span = span
        }
    }

    /// Explicit user-triggered verification, never run automatically in production.
    func sendTestEvent() {
        begin(.verification).finish(error: MountError.invalidURL)
    }

    private func purgeCache() {
        try? FileManager.default.removeItem(at: cacheURL)
    }

    static func sanitize(_ breadcrumb: Breadcrumb) -> Breadcrumb? {
        guard breadcrumb.category == "netmounter",
              let message = breadcrumb.message, DiagnosticOperation(rawValue: message) != nil else { return nil }
        let outcome = breadcrumb.data?["outcome"] as? String ?? "started"
        let clean = Breadcrumb(level: breadcrumb.level, category: "netmounter")
        clean.message = message
        clean.timestamp = breadcrumb.timestamp
        clean.setData(value: ["started", "success", "failure", "cancelled"].contains(outcome) ? outcome : "started", key: "outcome")
        return clean
    }

    @discardableResult
    static func sanitize(_ event: Event) -> Event {
        event.user = nil
        event.request = nil
        event.serverName = nil
        event.extra = nil
        event.modules = nil
        event.error = nil
        event.logger = nil
        let tags = event.tags ?? [:]
        var safeTags: [String: String] = [:]
        if let operation = tags["operation"], DiagnosticOperation(rawValue: operation) != nil { safeTags["operation"] = operation }
        if let family = tags["error_family"], DiagnosticFailure.families.contains(family) { safeTags["error_family"] = family }
        if let code = tags["error_code"], Int(code) != nil { safeTags["error_code"] = code }
        if let value = tags["protocol"], NetworkProtocol(rawValue: value) != nil { safeTags["protocol"] = value }
        if let value = tags["trigger"], ["automatic", "manual"].contains(value) { safeTags["trigger"] = value }
        if let value = tags["outcome"], ["success", "failure"].contains(value) { safeTags["outcome"] = value }
        event.tags = safeTags
        if let operation = safeTags["operation"], let family = safeTags["error_family"], let code = safeTags["error_code"] {
            event.message = SentryMessage(formatted: "\(operation) failed (\(family):\(code))")
            event.fingerprint = [operation, family, code, safeTags["protocol"] ?? "none"]
        } else {
            event.message = nil
            event.fingerprint = nil
        }
        if DiagnosticOperation(rawValue: event.transaction ?? "") == nil { event.transaction = nil }
        let contextKeys: [String: Set<String>] = [
            "os": ["name", "version", "build"],
            "device": ["arch", "family", "memory_size"],
            "app": ["app_identifier", "app_version", "app_build"],
            "trace": ["trace_id", "span_id", "parent_span_id", "op", "status"],
            "diagnostics": ["duration_ms"]
        ]
        event.context = event.context?.reduce(into: [:]) { result, item in
            guard let allowed = contextKeys[item.key] else { return }
            result[item.key] = item.value.filter { allowed.contains($0.key) && safeContextValue($0.value, key: $0.key) }
        }
        event.breadcrumbs = event.breadcrumbs?.compactMap { sanitize($0) }
        event.exceptions?.forEach { exception in
            // Exception reasons may include URLs or secret-bearing assertion values.
            exception.value = "Exception details removed for privacy"
            let nativeTypes: Set<String> = [
                "NSException", "NSInvalidArgumentException", "NSRangeException",
                "NSInternalInconsistencyException", "NSMallocException", "NSGenericException",
                "EXC_BAD_ACCESS", "EXC_BAD_INSTRUCTION", "EXC_ARITHMETIC", "EXC_BREAKPOINT",
                "EXC_CRASH", "EXC_RESOURCE", "EXC_GUARD", "SIGABRT", "SIGSEGV",
                "SIGBUS", "SIGILL", "SIGFPE", "SIGTRAP", "FatalError", "CPPException"
            ]
            if !nativeTypes.contains(exception.type ?? "") { exception.type = "NativeException" }
            exception.module = nil
            exception.mechanism?.data = nil
            exception.mechanism?.desc = nil
            exception.mechanism?.helpLink = nil
            exception.mechanism?.meta = nil
            if let mechanism = exception.mechanism,
               !["mach", "signal", "nsexception", "cpp_exception", "generic"].contains(mechanism.type) {
                mechanism.type = "generic"
            }
            sanitize(exception.stacktrace)
        }
        event.threads?.forEach { thread in
            thread.name = nil
            sanitize(thread.stacktrace)
        }
        sanitize(event.stacktrace)
        event.debugMeta?.forEach { image in
            image.codeFile = image.codeFile.map { URL(fileURLWithPath: $0).lastPathComponent }
        }
        return event
    }

    private static func safeContextValue(_ value: Any, key: String) -> Bool {
        if ["duration_ms", "memory_size"].contains(key) {
            guard let number = value as? NSNumber else { return false }
            return number.doubleValue.isFinite && number.doubleValue >= 0
        }
        guard let string = value as? String else { return false }
        switch key {
        case "name": return ["macOS", "Mac OS X"].contains(string)
        case "arch": return ["arm64", "arm64e", "x86_64"].contains(string)
        case "family": return string == "Mac"
        case "app_identifier": return string == Bundle.main.bundleIdentifier
        case "op": return string == "netmounter.operation"
        case "status": return ["ok", "cancelled", "internal_error", "unknown"].contains(string)
        case "trace_id", "span_id", "parent_span_id":
            return string.range(of: "^[0-9a-fA-F]{16}([0-9a-fA-F]{16})?$", options: .regularExpression) != nil
        case "version", "app_version", "app_build", "build":
            return string.range(of: "^[0-9]{1,3}([.][0-9]{1,3}){0,2}[A-Za-z]{0,3}[0-9]{0,4}$", options: .regularExpression) != nil
        // kernel_version can include a developer's filesystem paths, so it is excluded.
        default: return false
        }
    }

    private static func sanitize(_ stacktrace: SentryStacktrace?) {
        stacktrace?.frames.forEach { frame in
            frame.fileName = frame.fileName.map { URL(fileURLWithPath: $0).lastPathComponent }
            frame.module = frame.module.map { URL(fileURLWithPath: $0).lastPathComponent }
            frame.package = frame.package.map { URL(fileURLWithPath: $0).lastPathComponent }
            frame.vars = nil
            frame.contextLine = nil
            frame.preContext = nil
            frame.postContext = nil
        }
    }
}
