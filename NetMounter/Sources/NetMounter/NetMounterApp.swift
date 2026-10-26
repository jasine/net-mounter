import SwiftUI

@main
struct NetMounterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        #if DEBUG
        if ProcessInfo.processInfo.environment["NETMOUNTER_SENTRY_VERIFY"] == "1" { return }
        #endif
        LogBootstrap.setup()
    }

    var body: some Scene {
        Settings {
            Text("Settings Window (Placeholder)")
                .padding()
        }
    }
}
