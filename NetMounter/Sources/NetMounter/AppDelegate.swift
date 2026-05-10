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
        // Initialize dependencies
        appState = AppState()
        autoMountService = AutoMountService(appState: appState)
        sleepWakeManager = SleepWakeManager(
            appState: appState,
            networkMonitor: .shared,
            autoMountService: autoMountService
        )

        NotificationService.shared.requestAuthorization()
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
    
    // MARK: - NSPopoverDelegate
    func popoverWillShow(_ notification: Notification) {
        appState.isUIVisible = true
    }
    
    func popoverDidClose(_ notification: Notification) {
        appState.isUIVisible = false
    }
}


