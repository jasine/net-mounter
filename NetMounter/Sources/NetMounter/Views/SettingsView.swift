import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @Environment(\.dismiss) var dismiss
    @Environment(\.locale) private var locale
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchStatusMessage: String = ""
    @State private var showDiagnosticInfo = false
    @AppStorage(DiagnosticsService.consentKey) private var diagnosticsEnabled = DiagnosticsService.defaultEnabled
    #if DEBUG
    @State private var diagnosticTestSent = false
    #endif
    
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
                        
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Diagnostics", bundle: .module)
                                .font(.headline)
                                .foregroundColor(.secondary)
                                .padding(.leading, 4)

                            VStack(alignment: .leading, spacing: 12) {
                                HStack(spacing: 6) {
                                    Text("Share diagnostic data", bundle: .module)
                                    Button {
                                        showDiagnosticInfo = true
                                    } label: {
                                        Image(systemName: "questionmark.circle")
                                            .padding(2)
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(.secondary)
                                    .accessibilityLabel(Text("About diagnostic data", bundle: .module))
                                    .help(diagnosticDescription)
                                    .popover(isPresented: $showDiagnosticInfo) {
                                        VStack(alignment: .leading, spacing: 12) {
                                            Text("About diagnostic data", bundle: .module)
                                                .font(.headline)
                                            diagnosticDescription
                                                .font(.callout)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                        .padding()
                                        .frame(width: 340)
                                        .environment(\.locale, locale)
                                    }
                                    Toggle(isOn: $diagnosticsEnabled) {
                                        Text("Share diagnostic data", bundle: .module)
                                    }
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                                    .onChange(of: diagnosticsEnabled) { _, enabled in
                                        DiagnosticsService.shared.setEnabled(enabled)
                                        #if DEBUG
                                        diagnosticTestSent = false
                                        #endif
                                    }
                                }
                                #if DEBUG
                                if diagnosticsEnabled {
                                    Button {
                                        DiagnosticsService.shared.sendTestEvent()
                                        diagnosticTestSent = true
                                    } label: {
                                        Text("Send diagnostic test", bundle: .module)
                                    }
                                    if diagnosticTestSent {
                                        Text("Diagnostic test queued. Delivery depends on network availability.", bundle: .module)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                #endif
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

                        // 2. Application Group (Quit)
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Application")
                                .font(.headline)
                                .foregroundColor(.secondary)
                                .padding(.leading, 4)
                            
                            Button(action: {
                                dismiss()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                    NSApplication.shared.terminate(nil)
                                }
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
                                        Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown")")
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
        .frame(width: 380, height: 500) // Increase height to accommodate 3 groups
    }
    
    private var diagnosticDescription: Text {
        Text("Enabled by default; you can turn this off. Sends crash reports, error codes, app/OS versions and operation timing to Sentry in the US. Passwords, usernames, server addresses, share paths and MAC addresses are excluded. Sentry processes the connection IP address; IP and inferred location are scrubbed on the server. Turning this off stops new collection and attempts to delete the local diagnostic cache. Reports already queued may still be delivered; reports already sent cannot be recalled.", bundle: .module)
    }

    private func toggleLaunchAtLogin(enabled: Bool) {
        let diagnostic = DiagnosticsService.shared.begin(.loginItem)
        let service = SMAppService.mainApp
        do {
            if enabled {
                try service.register()
                launchStatusMessage = "Launch at login enabled."
            } else {
                try service.unregister()
                launchStatusMessage = "Launch at login disabled."
            }
            diagnostic.finish()
        } catch {
            diagnostic.finish(error: error)
            launchStatusMessage = "Error: \(error.localizedDescription)"
            launchAtLogin = !enabled // revert toggle
        }
    }
}
