import Cocoa
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
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
        popover.behavior = .transient // Closes when clicking outside
        
        // We use a wrapper view to inject environment objects
        let rootView = ServerListView()
            .environmentObject(appState)
            .environmentObject(autoMountService)
            .frame(width: 320) // Enforce width in SwiftUI as well
        
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
                // Must activate app to receive focus/events
                NSApplication.shared.activate(ignoringOtherApps: true)
                
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                
                // Force window to be key to "capture" initial focus
                popover.contentViewController?.view.window?.makeKey()
            }
        }
    }
}
