import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @Environment(\.dismiss) var dismiss
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @State private var launchStatusMessage: String = ""
    
    var body: some View {
        ZStack {
            LiquidGlassBackground()
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
            
            VStack(spacing: 0) {
                // Header
                HStack {
                    Text("Settings")
                        .font(.system(.title2, design: .rounded))
                        .fontWeight(.bold)
                        .foregroundColor(.primary)
                    Spacer()
                    Button("Done") {
                        dismiss()
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.thinMaterial)
                    .cornerRadius(12)
                    .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)
                }
                .padding()
                
                // Content
                ScrollView {
                    VStack(spacing: 20) {
                        
                        // 1. General Group
                        VStack(alignment: .leading, spacing: 12) {
                            Text("General")
                                .font(.headline)
                                .foregroundColor(.secondary)
                                .padding(.leading, 4)
                            
                            VStack(alignment: .leading, spacing: 12) {
                                Toggle("Launch at Login", isOn: Binding(
                                    get: { launchAtLogin },
                                    set: { newValue in
                                        launchAtLogin = newValue
                                        toggleLaunchAtLogin(enabled: newValue)
                                    }
                                ))
                                .toggleStyle(.switch)
                                
                                if !launchStatusMessage.isEmpty {
                                    Text(launchStatusMessage)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading) // Ensure full width and leading alignment
                            .background(.regularMaterial)
                            .cornerRadius(16)
                            .overlay(
                                RoundedRectangle(cornerRadius: 16)
                                    .stroke(.white.opacity(0.2), lineWidth: 1)
                            )
                        }
                        
                        // 2. Application Group (Quit)
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Application")
                                .font(.headline)
                                .foregroundColor(.secondary)
                                .padding(.leading, 4)
                            
                            Button(action: {
                                exit(0)
                            }) {
                                HStack {
                                    Text("Quit NetMounter")
                                        .fontWeight(.medium)
                                    Spacer()
                                    Image(systemName: "power")
                                }
                                .foregroundColor(.red.opacity(0.9))
                                .padding(.vertical, 4)
                            }
                            .buttonStyle(.plain)
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.regularMaterial)
                            .cornerRadius(16)
                            .overlay(
                                RoundedRectangle(cornerRadius: 16)
                                    .stroke(.white.opacity(0.2), lineWidth: 1)
                            )
                        }
                        
                        // 3. About Group
                        VStack(alignment: .leading, spacing: 12) {
                            Text("About")
                                .font(.headline)
                                .foregroundColor(.secondary)
                                .padding(.leading, 4)
                            
                            VStack(alignment: .leading, spacing: 16) {
                                HStack(spacing: 16) {
                                    ZStack {
                                        Circle().fill(.white.opacity(0.1))
                                            .frame(width: 56, height: 56)
                                        Image(systemName: "server.rack")
                                            .resizable()
                                            .aspectRatio(contentMode: .fit)
                                            .frame(width: 32, height: 32)
                                            .foregroundColor(.cyan)
                                    }
                                    
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("NetMounter")
                                            .font(.system(.title3, design: .rounded))
                                            .fontWeight(.semibold)
                                        Text("Version 1.0.0")
                                            .font(.subheadline)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                
                                Text("A lightweight, menu bar based net auto mounter for macOS.")
                                    .font(.callout)
                                    .foregroundColor(.primary.opacity(0.8))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.regularMaterial)
                            .cornerRadius(16)
                            .overlay(
                                RoundedRectangle(cornerRadius: 16)
                                    .stroke(.white.opacity(0.2), lineWidth: 1)
                            )
                        }
                    }
                    .padding()
                }
            }
        }
        .frame(width: 320, height: 500) // Increase height to accommodate 3 groups
    }
    
    private func toggleLaunchAtLogin(enabled: Bool) {
        // macOS 有代码签名限制，LaunchAgent 只能启动位于受信任位置的应用
        // 应用必须在 /Applications 目录下才能通过 LaunchAgent 自启动
        
        let label = "com.netmounter.launchagent"
        let plistName = "\(label).plist"
        let libraryURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        let launchAgentsURL = libraryURL.appendingPathComponent("LaunchAgents")
        let plistURL = launchAgentsURL.appendingPathComponent(plistName)
        
        if enabled {
            // 获取应用 bundle 路径
            guard let bundlePath = Bundle.main.bundlePath as String?,
                  let executablePath = Bundle.main.executablePath else {
                launchStatusMessage = "Error: Could not get app path."
                launchAtLogin = false
                return
            }
            
            // 检查应用是否在 /Applications 目录下
            let isInApplications = bundlePath.hasPrefix("/Applications/")
            
            if !isInApplications {
                launchStatusMessage = "⚠️ Please move NetMounter.app to /Applications first, then try again."
                launchAtLogin = false
                return
            }
            
            // Create LaunchAgent
            let plistContent = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key>
                <string>\(label)</string>
                <key>ProgramArguments</key>
                <array>
                    <string>\(executablePath)</string>
                </array>
                <key>RunAtLoad</key>
                <true/>
                <key>KeepAlive</key>
                <false/>
            </dict>
            </plist>
            """
            
            do {
                try FileManager.default.createDirectory(at: launchAgentsURL, withIntermediateDirectories: true)
                try plistContent.write(to: plistURL, atomically: true, encoding: .utf8)
                launchStatusMessage = "✓ Launch Agent created."
            } catch {
                launchStatusMessage = "Error creating Launch Agent: \(error)"
                launchAtLogin = false
            }
        } else {
            // Remove LaunchAgent
            do {
                if FileManager.default.fileExists(atPath: plistURL.path) {
                    try FileManager.default.removeItem(at: plistURL)
                }
                launchStatusMessage = "Launch Agent removed."
            } catch {
                launchStatusMessage = "Error removing Launch Agent: \(error)"
            }
        }
    }
}
