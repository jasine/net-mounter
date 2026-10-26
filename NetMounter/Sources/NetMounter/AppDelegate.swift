import Cocoa
import SwiftUI
import Combine
#if DEBUG
import Sentry
#endif

class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject, NSPopoverDelegate {
    var statusItem: NSStatusItem!
    var popover: NSPopover!

    // Dependencies
    var appState: AppState!
    var autoMountService: AutoMountService!
    var sleepWakeManager: SleepWakeManager!
    private var statusIconTimer: AnyCancellable?
    private var mountStateObserver: AnyCancellable?
    private var fingerprintObserver: AnyCancellable?
    var preventPopoverClose = false
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        // Isolated end-to-end check: no configuration, Keychain, mounts or scans are touched.
        if ProcessInfo.processInfo.environment["NETMOUNTER_SENTRY_VERIFY"] == "1" {
            let diagnostics = DiagnosticsService(
                cacheURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            )
            diagnostics.setEnabled(true, persist: false)
            diagnostics.sendTestEvent()
            DispatchQueue.global(qos: .utility).async {
                SentrySDK.flush(timeout: 15)
                diagnostics.setEnabled(false, persist: false)
                DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
            }
            return
        }
        #endif
        DiagnosticsService.shared.startIfEnabled()
        DiagnosticsService.shared.breadcrumb(.launch)
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:replyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )

        // Initialize dependencies
        appState = AppState()
        autoMountService = AutoMountService(appState: appState)
        sleepWakeManager = SleepWakeManager(
            appState: appState,
            networkMonitor: .shared,
            autoMountService: autoMountService
        )

        NotificationService.shared.setup()
        NotificationService.shared.onRetry = { [weak self] serverID in
            DispatchQueue.main.async {
                self?.autoMountService.retryMount(serverID)
            }
        }

        // Setup Popover
        popover = NSPopover()
        popover.contentSize = NSSize(width: 380, height: 400)
        popover.behavior = .transient
        popover.delegate = self
        
        // 使用 PopoverContentView 包装，它会根据 isUIVisible 条件渲染内容
        let rootView = PopoverContentView()
            .environmentObject(appState)
            .environmentObject(autoMountService)
            .frame(width: 380)
        
        popover.contentViewController = NSHostingController(rootView: rootView)
        popover.contentViewController?.view.setContentHuggingPriority(.defaultHigh, for: .vertical)
        
        // Setup Status Item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "externaldrive.badge.wifi", accessibilityDescription: "NetMounter")
            button.action = #selector(togglePopover(_:))
            button.target = self
        }

        statusIconTimer = Timer.publish(every: 10, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.updateStatusIcon() }

        mountStateObserver = NotificationCenter.default
            .publisher(for: .mountStateDidChange)
            .sink { [weak self] _ in self?.updateStatusIcon() }

        // The status icon depends on the network fingerprint, which resolves
        // asynchronously after launch. Refresh as soon as it lands instead of
        // waiting for the 10s timer, otherwise the icon shows the placeholder
        // (idle/wifi) until then.
        fingerprintObserver = NetworkMonitor.shared.$currentFingerprint
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateStatusIcon() }

        updateStatusIcon()
    }

    private func updateStatusIcon() {
        let fingerprint = NetworkMonitor.shared.currentFingerprint
        let servers = appState.servers
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let status = AppState.computeMountStatus(servers: servers, fingerprint: fingerprint)
            DispatchQueue.main.async {
                self?.statusItem.button?.image = NSImage(
                    systemSymbolName: status.iconName,
                    accessibilityDescription: "NetMounter"
                )
            }
        }
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        DiagnosticsService.shared.breadcrumb(.quit)
    }

    @objc func togglePopover(_ sender: AnyObject?) {
        DiagnosticsService.shared.breadcrumb(.popover)
        if let button = statusItem.button {
            if popover.isShown {
                popover.performClose(sender)
            } else {
                NSApplication.shared.activate(ignoringOtherApps: true)
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                popover.contentViewController?.view.window?.makeKey()
            }
        }
    }
    
    // MARK: - URL Scheme

    @objc private func handleGetURLEvent(_ event: NSAppleEventDescriptor, replyEvent: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: urlString) else { return }
        handleIncomingURL(url)
    }

    private func handleIncomingURL(_ url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "netmounter",
              components.host == "add" else { return }

        let params = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
                item.value.map { (item.name, $0) }
            }
        )

        guard let host = params["host"], !host.isEmpty else { return }

        let proto = NetworkProtocol(rawValue: params["proto"] ?? "smb") ?? .smb
        let share = params["share"] ?? ""
        let alias = params["alias"] ?? host

        let normalizedShare = share.trimmingCharacters(in: CharacterSet(charactersIn: "/\\")).lowercased()
        let isDuplicate = appState.servers.contains {
            $0.hostname.lowercased() == host.lowercased()
                && $0.serverProtocol == proto
                && $0.normalizedSharePath.lowercased() == normalizedShare
        }

        if isDuplicate {
            let alert = NSAlert()
            alert.messageText = "Server Already Exists"
            alert.informativeText = "\(proto.displayName) server \"\(alias)\" (\(host)/\(share)) is already configured."
            alert.addButton(withTitle: "OK")
            alert.alertStyle = .informational
            alert.runModal()
            return
        }

        let alert = NSAlert()
        alert.messageText = "Add Server?"
        alert.informativeText = "Add \(proto.displayName) server \"\(alias)\" (\(host)/\(share))?"
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .informational

        if alert.runModal() == .alertFirstButtonReturn {
            let config = ServerConfig(
                alias: alias,
                serverProtocol: proto,
                hostname: host,
                sharePath: share
            )
            if let validation = config.validationMessage {
                let errorAlert = NSAlert()
                errorAlert.messageText = String(localized: "Could not save", bundle: .module)
                errorAlert.informativeText = validation
                errorAlert.runModal()
            } else if case .failure(let error) = appState.addServer(config) {
                let errorAlert = NSAlert()
                errorAlert.messageText = String(localized: "Could not save", bundle: .module)
                errorAlert.informativeText = error.localizedDescription
                errorAlert.runModal()
            }
        }
    }

    // MARK: - NSPopoverDelegate
    func popoverShouldClose(_ popover: NSPopover) -> Bool {
        !preventPopoverClose
    }

    func popoverWillShow(_ notification: Notification) {
        appState.isUIVisible = true
    }

    func popoverDidClose(_ notification: Notification) {
        appState.isUIVisible = false
    }
}


