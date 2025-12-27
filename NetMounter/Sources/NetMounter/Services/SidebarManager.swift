import Foundation
import CoreServices

class SidebarManager {
    static let shared = SidebarManager()
    
    func addToSidebar(url: URL) {
        // macOS 15+ restricted C-API and AppleScript permissions are tricky.
        // Reverting to sfltool which seemed to execute successfully, 
        // and attempting to force a refresh by restarting sharedfilelistd.
        
        let name = url.lastPathComponent
        let path = url.path
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sfltool")
        process.arguments = [
            "add-item",
            "-n", name,
            path,
            "com.apple.LSSharedFileList.FavoriteItems"
        ]
        
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                // print("Successfully queued \(name) for Sidebar via sfltool")
                // Attempt to refresh sidebar invisibly
                let refresh = Process()
                refresh.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
                refresh.arguments = ["sharedfilelistd"]
                try? refresh.run()
            } else {
                print("sfltool failed with exit code: \(process.terminationStatus)")
            }
        } catch {
            print("Failed to run sfltool: \(error)")
        }
    }
}
