import Cocoa
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject, NSPopoverDelegate {
    var statusItem: NSStatusItem!
    var popover: NSPopover!
    
    // Dependencies
    var appState: AppState!
    var autoMountService: AutoMountService!
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Initialize dependencies
        appState = AppState()
        autoMountService = AutoMountService(appState: appState)
        
        // Setup Popover
        popover = NSPopover()
        popover.contentSize = NSSize(width: 320, height: 400)
        popover.behavior = .transient
        popover.delegate = self
        
        // 使用 PopoverContentView 包装，它会根据 isUIVisible 条件渲染内容
        let rootView = PopoverContentView()
            .environmentObject(appState)
            .environmentObject(autoMountService)
            .frame(width: 320)
        
        popover.contentViewController = NSHostingController(rootView: rootView)
        
        // Setup Status Item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "externaldrive.badge.wifi", accessibilityDescription: "NetMounter")
            button.action = #selector(togglePopover(_:))
            button.target = self
        }
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


