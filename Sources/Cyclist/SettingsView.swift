import Combine
import ServiceManagement
import SwiftUI

// A hover affordance for the settings whose meaning is not obvious from
// the label. The native help tooltip takes over a second to appear and
// cannot be styled, so the info circle presents a popover after a short
// hover delay instead.
private struct InfoDot: View {
    let text: String
    init(_ text: String) { self.text = text }

    @State private var shown = false
    @State private var hoverDelay: Task<Void, Never>?

    var body: some View {
        Image(systemName: "info.circle")
            .foregroundStyle(.secondary)
            .onHover { inside in
                hoverDelay?.cancel()
                if inside {
                    hoverDelay = Task {
                        try? await Task.sleep(nanoseconds: 150_000_000)
                        guard !Task.isCancelled else { return }
                        shown = true
                    }
                } else {
                    shown = false
                }
            }
            .popover(isPresented: $shown) {
                Text(text)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 280, alignment: .leading)
                    .padding(12)
            }
    }
}

struct SettingsView: View {
    @AppStorage(Settings.includeHiddenKey) private var includeHidden = true
    @AppStorage(Settings.includeMinimizedKey) private var includeMinimized = true
    @AppStorage(Settings.includeOtherSpacesKey) private var includeOtherSpaces = true
    @AppStorage(Settings.includeNoWindowsKey) private var includeNoWindows = false
    @AppStorage(Settings.trackpadSwipeKey) private var trackpadSwipe = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var aerospaceIntegration = Config.aerospaceIntegration
    @State private var showHollowWorkspaces = Config.showHollowWorkspaces

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $launchAtLogin) {
                    Label("Launch at Login", systemImage: "power")
                }
                .onChange(of: launchAtLogin) { setLaunchAtLogin($0) }
            } header: {
                Text("General")
            } footer: {
                Text("A macOS login item; also listed in System Settings > General > Login Items.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Switcher list") {
                Toggle("Include hidden apps", isOn: $includeHidden)
                Toggle("Include minimized apps", isOn: $includeMinimized)
                Toggle("Include apps in other Spaces", isOn: $includeOtherSpaces)
                Toggle(isOn: $includeNoWindows) {
                    HStack(spacing: 4) {
                        Text("Include apps with no windows")
                        InfoDot("Lists running apps that have no windows at all. Selecting one behaves like clicking its Dock icon, so the app reopens a window.")
                    }
                }
            }
            Section("Navigation") {
                Toggle(isOn: $trackpadSwipe) {
                    HStack(spacing: 4) {
                        Text("Trackpad swipe navigation")
                        InfoDot("Steps through Spaces instantly on the system three- or four-finger swipe instead of playing the animated transition. The system gesture must stay enabled in System Settings > Trackpad > More Gestures.")
                    }
                }
            }
            Section {
                Toggle(isOn: $aerospaceIntegration) {
                    HStack(spacing: 4) {
                        Text("AeroSpace integration")
                        InfoDot("Bridges to the AeroSpace tiling window manager over its socket: its workspaces join Ctrl+Left/Right navigation and windows parked in hidden workspaces get switcher rows. Requires AeroSpace running.")
                    }
                }
                .onChange(of: aerospaceIntegration) { newValue in
                    guard newValue != Config.aerospaceIntegration else { return }
                    Config.set(section: "aerospace", key: "integration", to: newValue)
                }
                Toggle(isOn: $showHollowWorkspaces) {
                    HStack(spacing: 4) {
                        Text("Show hollow workspaces")
                        InfoDot("A hollow workspace is one whose windows all went native-fullscreen; visiting it shows a bare desktop, so navigation skips it by default and stops on the fullscreen Spaces instead. Enable to keep those stops.")
                    }
                }
                .disabled(!aerospaceIntegration)
                .onChange(of: showHollowWorkspaces) { newValue in
                    guard newValue != Config.showHollowWorkspaces else { return }
                    Config.set(section: "aerospace", key: "show-hollow-workspaces", to: newValue)
                }
            } header: {
                Text("AeroSpace (advanced)")
            } footer: {
                Text("Stored in \(Config.displayPath); hand edits apply live.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 360)
        .fixedSize()
        .onReceive(NotificationCenter.default.publisher(for: Config.didChangeNotification)) { _ in
            aerospaceIntegration = Config.aerospaceIntegration
            showHollowWorkspaces = Config.showHollowWorkspaces
        }
        .onAppear {
            // System Settings > General > Login Items is a second writer of
            // this state; re-read whenever the window comes up.
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    // Native login item via SMAppService: the app appears in System
    // Settings > General > Login Items and macOS owns the launch.
    private func setLaunchAtLogin(_ enable: Bool) {
        guard enable != (SMAppService.mainApp.status == .enabled) else { return }
        do {
            if enable {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Log.write("launch at login toggle failed: \(error)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    static func showWindow() {
        UtilityWindow.show(id: "cyclist-settings", title: "Cyclist Settings", content: SettingsView())
    }
}
