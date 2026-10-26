import AppKit
import SwiftUI
import XCTest
@testable import NetMounter

/// Opt-in layout captures and isolated help interactions. No AppDelegate, credentials, discovery, or mount actions.
final class UIRenderingTests: XCTestCase {
    @MainActor
    func testOffscreenLayouts() throws {
        guard let outputPath = ProcessInfo.processInfo.environment["NETMOUNTER_UI_SNAPSHOTS"] else {
            throw XCTSkip("Set NETMOUNTER_UI_SNAPSHOTS to capture isolated UI fixtures.")
        }
        let output = URL(fileURLWithPath: outputPath)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let suite = "NetMounterDiagnosticsLayout-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try capture(SettingsView().defaultAppStorage(defaults), name: "settings-diagnostics",
                    size: NSSize(width: 380, height: 650), output: output)
        try capture(SettingsView().defaultAppStorage(defaults).environment(\.locale, Locale(identifier: "zh-Hans")),
                    name: "settings-diagnostics-zh", size: NSSize(width: 380, height: 650), output: output)
        let state = AppState(configURL: output.appendingPathComponent("unused-config.json"))
        let fingerprint = NetworkFingerprint(ssid: "Fixture network", interfaceType: .wifi)
        let server = ServerConfig(alias: "Home NAS", hostname: "nas.invalid", sharePath: "media",
                                  keychainItemId: "fixture-not-a-real-credential",
                                  autoMountRules: [AutoMountRule(fingerprint: fingerprint)])
        state.servers = [server]
        try capture(ServerDetailView().environmentObject(state), name: "new-server", size: NSSize(width: 380, height: 600), output: output)
        try capture(ServerDetailView(config: server).environmentObject(state), name: "edit-server", size: NSSize(width: 380, height: 600), output: output)
        var nfs = server
        nfs.serverProtocol = .nfs
        nfs.sharePath = "/volume1/media"
        nfs.keychainItemId = nil
        try capture(ServerDetailView(config: nfs).environmentObject(state), name: "nfs-server", size: NSSize(width: 380, height: 600), output: output)
        for (name, operation) in [("mount-failure", ServerOperation.failed("The server did not respond. Check your network, then retry.", mountPath: nil)),
                                   ("connecting", .connecting),
                                   ("unmount-failure", .failed("The volume is busy. Close any files using it, then retry.", mountPath: "/Volumes/fixture"))] {
            state.serverOperations[server.id] = operation
            try capture(ServerRow(server: server, onEdit: {}, onDelete: {}, onUpdatePins: { _ in })
                .environmentObject(state), name: name, size: NSSize(width: 380, height: 240), output: output)
        }
    }

    @MainActor
    func testDiagnosticHelpOpensWithoutChangingConsent() throws {
        guard let outputPath = ProcessInfo.processInfo.environment["NETMOUNTER_UI_SNAPSHOTS"] else {
            throw XCTSkip("Set NETMOUNTER_UI_SNAPSHOTS to exercise the isolated help popover.")
        }
        let output = URL(fileURLWithPath: outputPath)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        _ = NSApplication.shared
        var localizedImages: [String: Data] = [:]
        for locale in ["en", "zh-Hans"] {
            for enabled in [false, true] {
                let suite = "NetMounterDiagnosticHelp-\(UUID().uuidString)"
                let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
                defaults.set(enabled, forKey: DiagnosticsService.consentKey)
                defer { defaults.removePersistentDomain(forName: suite) }
                let host = NSHostingView(rootView: SettingsView().defaultAppStorage(defaults)
                    .environment(\.locale, Locale(identifier: locale)))
                let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 380, height: 500),
                                      styleMask: .borderless, backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = host
                window.orderFront(nil)
                defer { window.close() }
                host.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
                let existingWindows = Set(NSApplication.shared.windows.map(ObjectIdentifier.init))
                // Positions in the isolated 380x500 settings fixture, measured from its renders.
                let point = NSPoint(x: locale == "en" ? 180 : 125, y: 259)
                let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point,
                    modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
                let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: point,
                    modifierFlags: [], timestamp: 0.1, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
                window.sendEvent(down)
                window.sendEvent(up)
                let deadline = Date().addingTimeInterval(2)
                var explanationWindow: NSWindow?
                while explanationWindow == nil && Date() < deadline {
                    RunLoop.current.run(until: Date().addingTimeInterval(0.02))
                    explanationWindow = NSApplication.shared.windows.first {
                        !existingWindows.contains(ObjectIdentifier($0)) && $0.isVisible
                    }
                }
                let popover = try XCTUnwrap(explanationWindow, "Click must open the help popover")
                XCTAssertEqual(defaults.bool(forKey: DiagnosticsService.consentKey), enabled)
                let content = try XCTUnwrap(popover.contentView)
                let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
                content.cacheDisplay(in: content.bounds, to: bitmap)
                let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                localizedImages[locale] = data
                try data.write(to: output.appendingPathComponent("diagnostic-help-\(locale)-\(enabled).png"))
                popover.close()
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                XCTAssertEqual(defaults.bool(forKey: DiagnosticsService.consentKey), enabled)
            }
        }
        XCTAssertNotEqual(localizedImages["en"], localizedImages["zh-Hans"], "Popover must honor the settings language")
    }

    @MainActor
    private func capture<V: View>(_ view: V, name: String, size: NSSize, output: URL) throws {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
        host.frame = NSRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: .darkAqua)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            return XCTFail("No bitmap for \(name)")
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: output.appendingPathComponent(name + ".png"))
        window.contentView = nil
    }
}
