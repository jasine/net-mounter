import SwiftUI

@main
struct NetMounterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        LogBootstrap.setup()
    }

    var body: some Scene {
        Settings {
            Text("Settings Window (Placeholder)")
                .padding()
        }
    }
}
