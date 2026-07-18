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
    @AppStorage(Settings.appSwitcherKey) private var appSwitcher = true
    @AppStorage(Settings.windowCyclerKey) private var windowCycler = true
    @AppStorage(Settings.includeHiddenKey) private var includeHidden = true
    @AppStorage(Settings.includeMinimizedKey) private var includeMinimized = true
    @AppStorage(Settings.includeOtherSpacesKey) private var includeOtherSpaces = true
    @AppStorage(Settings.includeNoWindowsKey) private var includeNoWindows = false
    @AppStorage(Settings.liveOtherSpaceTitlesKey) private var liveOtherSpaceTitles = true
    @AppStorage(Settings.trackpadSwipeKey) private var trackpadSwipe = true
    @AppStorage(Settings.keyboardSpaceNavKey) private var keyboardSpaceNav = true
    @AppStorage(Settings.showMenuBarIconKey) private var showMenuBarIcon = true
    @AppStorage(Settings.aerospaceIntegrationKey) private var aerospaceIntegration = false
    @AppStorage(Settings.showHollowWorkspacesKey) private var showHollowWorkspaces = false
    @AppStorage(Settings.switcherShortcutKey) private var switcherShortcut = "cmd+tab"
    @AppStorage(Settings.cycleWindowsShortcutKey) private var cycleWindowsShortcut = "cmd+backtick"
    @AppStorage(Settings.previousSpaceShortcutKey) private var previousSpaceShortcut = "ctrl+left"
    @AppStorage(Settings.nextSpaceShortcutKey) private var nextSpaceShortcut = "ctrl+right"
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var screenRecordingGranted = CGPreflightScreenCaptureAccess()
    @ObservedObject private var recorder = ShortcutRecorder.shared

    // Two side-by-side columns keep the window at a glanceable height;
    // both stretch to the taller column so their backgrounds stay flush.
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Form {
                generalSection
                switchingSection
                switcherListSection
                navigationSection
            }
            .formStyle(.grouped)
            .frame(width: 360)
            .frame(maxHeight: .infinity)
            Form {
                shortcutsSection
                aerospaceSection
            }
            .formStyle(.grouped)
            .frame(width: 360)
            .frame(maxHeight: .infinity)
        }
        .fixedSize()
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            screenRecordingGranted = CGPreflightScreenCaptureAccess()
        }
        // System Settings is a second writer of the login-item and Screen
        // Recording state, and neither offers a change notification, so
        // both are re-read at the moments the user can next see them:
        // changing them over there deactivates this app, and both
        // returning here and reopening the window activate it again.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            launchAtLogin = SMAppService.mainApp.status == .enabled
            screenRecordingGranted = CGPreflightScreenCaptureAccess()
        }
        // An armed recording swallows every keyDown system-wide; it must
        // die with the window that shows it, or closing (or just clicking
        // away) mid-recording leaves the keyboard globally dead until Esc.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
            if (note.object as? NSWindow)?.identifier?.rawValue == "cyclist-settings" {
                recorder.cancel()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { note in
            if (note.object as? NSWindow)?.identifier?.rawValue == "cyclist-settings" {
                recorder.cancel()
            }
        }
    }

    private var generalSection: some View {
        Section {
            Toggle(isOn: $launchAtLogin) {
                Label("Launch at Login", systemImage: "power")
            }
            .onChange(of: launchAtLogin) { setLaunchAtLogin($0) }
            Toggle(isOn: $showMenuBarIcon) {
                HStack(spacing: 4) {
                    Text("Show menu bar icon")
                    InfoDot("Cyclist keeps running without the icon. To get back here: hold the switcher open and press comma, or relaunch Cyclist - reopening the app always shows this window.")
                }
            }
            Toggle(isOn: $liveOtherSpaceTitles) {
                HStack(spacing: 4) {
                    Text("Live titles from other Spaces")
                    InfoDot("Reads the titles of windows in other Spaces (fullscreen included) through the Screen Recording permission - titles only, never window contents. Off, those rows show the last title Cyclist saw, and Cyclist never requests the permission. If the Screen Recording pane does not list Cyclist, add /Applications/Cyclist.app there with the + button.")
                }
            }
            .onChange(of: liveOtherSpaceTitles) { on in
                if on { requestScreenRecording() }
            }
            if liveOtherSpaceTitles, !screenRecordingGranted {
                HStack(spacing: 4) {
                    Text("Screen Recording is not granted.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Request Access") {
                        requestScreenRecording()
                    }
                    .controlSize(.small)
                }
            }
        } header: {
            Text("General")
        } footer: {
            Text("Launch at Login is a macOS login item; also listed in System Settings > General > Login Items.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var switchingSection: some View {
        Section("Switching") {
            Toggle(isOn: $appSwitcher) {
                HStack(spacing: 4) {
                    Text("App switcher")
                    InfoDot("Replaces the switcher binding (Cmd+Tab by default) with Cyclist's list. Off returns the binding to macOS immediately, leaving Space navigation as Cyclist's job.")
                }
            }
            Toggle(isOn: $windowCycler) {
                HStack(spacing: 4) {
                    Text("Window cycler")
                    InfoDot("Cycles the frontmost app's windows on the cycle binding (Cmd+` by default). Off returns the binding to macOS immediately.")
                }
            }
        }
    }

    private var switcherListSection: some View {
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
        .disabled(!appSwitcher)
    }

    private var navigationSection: some View {
        Section("Navigation") {
            Toggle(isOn: $trackpadSwipe) {
                HStack(spacing: 4) {
                    Text("Trackpad swipe navigation")
                    InfoDot("Steps through Spaces instantly on the system three- or four-finger swipe instead of playing the animated transition. The system gesture must stay enabled in System Settings > Trackpad > More Gestures.")
                }
            }
            Toggle(isOn: $keyboardSpaceNav) {
                HStack(spacing: 4) {
                    Text("Keyboard Space navigation")
                    InfoDot("Steps through Spaces and workspaces with the Previous/Next Space shortcuts. Off returns those keys to macOS immediately.")
                }
            }
        }
    }

    private var shortcutsSection: some View {
        Section {
            shortcutRow(key: Settings.switcherShortcutKey, value: switcherShortcut,
                        info: "Opens the switcher. Hold the shortcut's modifiers to keep the list open; a quick tap returns to the previous window. Shift reverses the direction.")
            shortcutRow(key: Settings.cycleWindowsShortcutKey, value: cycleWindowsShortcut,
                        info: "Cycles the windows of the frontmost app, including minimized ones and windows in other Spaces.")
            shortcutRow(key: Settings.previousSpaceShortcutKey, value: previousSpaceShortcut,
                        info: "Steps to the previous Space or workspace on the active display.")
            shortcutRow(key: Settings.nextSpaceShortcutKey, value: nextSpaceShortcut,
                        info: "Steps to the next Space or workspace on the active display.")
        } header: {
            Text("Shortcuts")
        } footer: {
            Text(recorder.message
                ?? "Click a shortcut, then press the new keys; Esc cancels.")
                .font(.caption)
                .foregroundStyle(recorder.message == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
        }
    }

    private var aerospaceSection: some View {
        Section {
            Toggle(isOn: $aerospaceIntegration) {
                HStack(spacing: 4) {
                    Text("AeroSpace integration")
                    InfoDot("Bridges to the AeroSpace tiling window manager over its socket: its workspaces join Ctrl+Left/Right navigation and windows parked in hidden workspaces get switcher rows. Requires AeroSpace running.")
                }
            }
            Toggle(isOn: $showHollowWorkspaces) {
                HStack(spacing: 4) {
                    Text("Show hollow workspaces")
                    InfoDot("A hollow workspace is one whose windows all went native-fullscreen; visiting it shows a bare desktop, so navigation skips it by default and stops on the fullscreen Spaces instead. Enable to keep those stops.")
                }
            }
            .disabled(!aerospaceIntegration)
        } header: {
            Text("AeroSpace (advanced)")
        } footer: {
            Text("Every setting is scriptable: defaults write cz.szypowi.cyclist (see the README).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func shortcutRow(key: String, value: String, info: String) -> some View {
        HStack(spacing: 4) {
            Text(ShortcutRecorder.labels[key] ?? key)
            InfoDot(info)
            Spacer()
            Button(recorder.recordingKey == key ? "Press keys…" : Shortcut.parse(value)!.display) {
                recorder.begin(key: key)
            }
            .buttonStyle(.bordered)
        }
    }

    // The system permission prompt shows at most once per TCC state;
    // resetting this app's own ScreenCapture entry (unprivileged) re-arms
    // it, so the request genuinely prompts again. The guard keeps the
    // reset from ever touching a live grant; a refused reset falls back
    // to opening the pane directly.
    private func requestScreenRecording() {
        guard !ScreenRecordingPermission.granted else { return }
        let reset = Process()
        reset.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        reset.arguments = ["reset", "ScreenCapture",
                           Bundle.main.bundleIdentifier ?? "cz.szypowi.cyclist"]
        var rearmed = false
        if (try? reset.run()) != nil {
            reset.waitUntilExit()
            rearmed = reset.terminationStatus == 0
        }
        if rearmed {
            ScreenRecordingPermission.request()
        } else {
            Log.write("screen recording: tccutil reset refused; opening the pane instead")
            NSWorkspace.shared.open(URL(string:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
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
