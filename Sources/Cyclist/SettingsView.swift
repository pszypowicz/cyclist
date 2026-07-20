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
    @AppStorage(Settings.windowSwitcherKey) private var windowSwitcher = true
    @AppStorage(Settings.showHiddenAppsKey) private var showHiddenApps = true
    @AppStorage(Settings.showMinimizedWindowsKey) private var showMinimizedWindows = true
    @AppStorage(Settings.showWindowsInOtherSpacesKey) private var showWindowsInOtherSpaces = true
    @AppStorage(Settings.showAppsWithNoWindowKey) private var showAppsWithNoWindow = false
    @AppStorage(Settings.liveOtherSpaceTitlesKey) private var liveOtherSpaceTitles = false
    @AppStorage(Settings.trackpadSwipeKey) private var trackpadSwipe = true
    @AppStorage(Settings.keyboardSpaceNavKey) private var keyboardSpaceNav = true
    @AppStorage(Settings.showMenuBarIconKey) private var showMenuBarIcon = true
    @AppStorage(Settings.aerospaceIntegrationKey) private var aerospaceIntegration = false
    @AppStorage(Settings.aerospaceFollowWorkspaceKey) private var aerospaceFollowWorkspace = true
    @AppStorage(Settings.showHollowWorkspacesKey) private var showHollowWorkspaces = false
    @AppStorage(Settings.switcherSizeKey) private var switcherSize = SwitcherSize.medium.rawValue
    @AppStorage(Settings.switchAppsShortcutKey) private var switchAppsShortcut = "cmd+tab"
    @AppStorage(Settings.switchWindowsShortcutKey) private var switchWindowsShortcut = "cmd+backtick"
    @AppStorage(Settings.previousSpaceShortcutKey) private var previousSpaceShortcut = "ctrl+left"
    @AppStorage(Settings.nextSpaceShortcutKey) private var nextSpaceShortcut = "ctrl+right"
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var accessibilityGranted = AXIsProcessTrusted()
    @State private var screenRecordingGranted = CGPreflightScreenCaptureAccess()
    @ObservedObject private var recorder = ShortcutRecorder.shared

    // Two side-by-side columns keep the window at a glanceable height;
    // both stretch to the taller column so their backgrounds stay flush.
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Form {
                generalSection
                switchingSection
                windowFiltersSection
                appSwitcherListSection
            }
            .formStyle(.grouped)
            .frame(width: 360)
            .frame(maxHeight: .infinity)
            Form {
                shortcutsSection
                navigationSection
                aerospaceSection
            }
            .formStyle(.grouped)
            .frame(width: 360)
            .frame(maxHeight: .infinity)
        }
        .fixedSize()
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            accessibilityGranted = AXIsProcessTrusted()
            screenRecordingGranted = CGPreflightScreenCaptureAccess()
        }
        // System Settings is a second writer of the login-item and
        // permission state, and none of it offers a change notification,
        // so everything is re-read at the moments the user can next see
        // it: changing them over there deactivates this app, and both
        // returning here and reopening the window activate it again.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            launchAtLogin = SMAppService.mainApp.status == .enabled
            accessibilityGranted = AXIsProcessTrusted()
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
            // Accessibility is the one permission Cyclist cannot run
            // without; the launch prompt registers the row in the pane,
            // so unlike Screen Recording there is a toggle waiting there.
            if !accessibilityGranted {
                HStack(spacing: 4) {
                    Text("Accessibility is not granted - every hotkey is inactive.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Open Pane") {
                        openPrivacyPane("Privacy_Accessibility")
                    }
                    .controlSize(.small)
                }
            }
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
                if on { ScreenRecordingPermission.request() }
            }
            if liveOtherSpaceTitles, !screenRecordingGranted {
                HStack(spacing: 4) {
                    // The macOS 26 pane lists only granted apps; the +
                    // button there is how the grant happens.
                    Text("Not granted - add Cyclist with the + button.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Open Pane") {
                        openPrivacyPane("Privacy_ScreenCapture")
                    }
                    .controlSize(.small)
                }
            }
        } header: {
            Text("General")
        }
    }

    private var switchingSection: some View {
        Section("Switching") {
            Toggle(isOn: $appSwitcher) {
                HStack(spacing: 4) {
                    Text("App switcher")
                    InfoDot("Replaces the app-switch binding (Cmd+Tab by default) with Cyclist's list. Off returns the binding to macOS immediately, leaving Space navigation as Cyclist's job.")
                }
            }
            Toggle(isOn: $windowSwitcher) {
                HStack(spacing: 4) {
                    Text("Window switcher")
                    InfoDot("Switches among the frontmost app's windows on the window-switch binding (Cmd+` by default). Off returns the binding to macOS immediately.")
                }
            }
            Picker(selection: $switcherSize) {
                ForEach(SwitcherSize.allCases) { size in
                    Text(size.label).tag(size.rawValue)
                }
            } label: {
                HStack(spacing: 4) {
                    Text("Switcher size")
                    InfoDot("Scales the switcher overlay - its text, icons, and spacing together - to a preset. Larger reads more easily across the room or on a high-resolution display; smaller fits more windows on screen. Applies the next time the switcher opens. For system-wide magnification beyond this, macOS Zoom (System Settings > Accessibility > Zoom) enlarges any app.")
                }
            }
        }
    }

    // The list filters split by scope. Minimized and other-Spaces are
    // per-window predicates that both the app switcher and the window
    // switcher honor, so they stay live while either feature is on; hidden
    // and no-windows are per-app and only the app switcher reads them.
    // Keeping them in one section would tie the window filters' disabled
    // state to the app switcher alone, graying them out while they still
    // shape the window switcher's list.
    private var windowFiltersSection: some View {
        Section {
            Toggle("Show minimized windows", isOn: $showMinimizedWindows)
            Toggle("Show windows in other Spaces", isOn: $showWindowsInOtherSpaces)
        } header: {
            Text("Windows shown")
        } footer: {
            Text("Applies to both the app switcher and the window switcher.")
        }
        .disabled(!appSwitcher && !windowSwitcher)
    }

    private var appSwitcherListSection: some View {
        Section {
            Toggle("Show hidden apps", isOn: $showHiddenApps)
            Toggle(isOn: $showAppsWithNoWindow) {
                HStack(spacing: 4) {
                    Text("Show apps with no open window")
                    InfoDot("Lists running apps with no open window. Selecting one behaves like clicking its Dock icon, so the app reopens a window.")
                }
            }
        } header: {
            Text("App switcher list")
        } footer: {
            Text("Applies to the app switcher only.")
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
            shortcutRow(key: Settings.switchAppsShortcutKey, value: switchAppsShortcut,
                        info: "Opens the app switcher. Hold the shortcut's modifiers to keep the list open; a quick tap returns to the previous window. Shift reverses the direction.")
            shortcutRow(key: Settings.switchWindowsShortcutKey, value: switchWindowsShortcut,
                        info: "Switches among the windows of the frontmost app, including minimized ones and windows in other Spaces.")
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
            Toggle(isOn: $aerospaceFollowWorkspace) {
                HStack(spacing: 4) {
                    Text("Follow workspace switches")
                    InfoDot("When your AeroSpace workspace shortcut (e.g. Option+1-9, defined in the AeroSpace config) switches to a workspace whose windows are on the main desktop, Cyclist follows you to that desktop - so the shortcut works even from a fullscreen Space. AeroSpace still makes the switch; Cyclist only brings you to the right native Space.")
                }
            }
            .disabled(!aerospaceIntegration)
            Toggle(isOn: $showHollowWorkspaces) {
                HStack(spacing: 4) {
                    Text("Show hollow workspaces")
                    InfoDot("A hollow workspace is one whose windows all went native-fullscreen; visiting it shows a bare desktop, so navigation skips it by default and stops on the fullscreen Spaces instead. Enable to keep those stops.")
                }
            }
            .disabled(!aerospaceIntegration)
        } header: {
            Text("AeroSpace (advanced)")
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

    private func openPrivacyPane(_ anchor: String) {
        NSWorkspace.shared.open(URL(string:
            "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!)
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
