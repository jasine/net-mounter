import Cocoa
import SwiftUI
import Combine

class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject, NSPopoverDelegate {
    var statusItem: NSStatusItem!
    var popover: NSPopover!

    // Dependencies
    var appState: AppState!
    var autoMountService: AutoMountService!
    var sleepWakeManager: SleepWakeManager!
    private var statusIconTimer: AnyCancellable?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
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
            guard let self = self,
                  self.appState.servers.contains(where: { $0.id == serverID }),
                  let fingerprint = NetworkMonitor.shared.currentFingerprint else { return }
            self.autoMountService.evaluateAutoMount(for: fingerprint)
        }

        // Setup Popover
        popover = NSPopover()
        popover.contentSize = NSSize(width: 320, height: 400)
        popover.behavior = .transient
        popover.delegate = self
        
        // 使用 PopoverContentView 包装，它会根据 isUIVisible 条件渲染内容
        let rootView = PopoverContentView()
            .environmentObject(appState)
            .environmentObject(autoMountService)
            .frame(width: 380)
        
        popover.contentViewController = NSHostingController(rootView: rootView)
        
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
    }

    private func updateStatusIcon() {
        let status = appState.computeMountStatus(fingerprint: NetworkMonitor.shared.currentFingerprint)
        statusItem.button?.image = NSImage(
            systemSymbolName: status.iconName,
            accessibilityDescription: "NetMounter"
        )
    }
    
    @objc func togglePopover(_ sender: AnyObject?) {
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

    func handleIncomingURL(_ url: URL) {
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
            appState.addServer(config)
        }
    }

    // MARK: - NSPopoverDelegate
    func popoverWillShow(_ notification: Notification) {
        appState.isUIVisible = true
    }
    
    func popoverDidClose(_ notification: Notification) {
        appState.isUIVisible = false
    }
}


