import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = StatusItemController()
    private let aerospace = AeroSpaceClient()
    private let wsEvents = WindowServerEvents()
    private var mru: MRUTracker!
    private var recency: WindowFocusTracker!
    private var controller: SwitcherController!
    private var permissionTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        Settings.registerDefaults()
        Config.load()
        AX.configureGlobalTimeout()
        if Config.aerospaceIntegration {
            aerospace.start()
        }
        Config.startWatching { [weak self] old, new in
            guard let self else { return }
            if old.aerospaceIntegration != new.aerospaceIntegration {
                if new.aerospaceIntegration {
                    self.aerospace.start()
                } else {
                    self.aerospace.stop()
                }
            }
        }
        mru = MRUTracker()
        recency = WindowFocusTracker(events: wsEvents)
        controller = SwitcherController(mru: mru, recency: recency, aerospace: aerospace, events: wsEvents)
        // Start delivering only after every consumer has wired its callbacks.
        wsEvents.start()
        controller.onTapInvalidated = { [weak self] in self?.scheduleRecovery() }
        statusItem.setUp()
        // Disabled means the taps are down and every shortcut is native
        // again; the trackers and the AeroSpace client keep running so a
        // re-enable resumes with fresh MRU order.
        statusItem.onEnabledToggled = { [weak self] enabled in
            guard let self else { return }
            if enabled {
                Log.write("enabled via menu")
                self.ensurePermissionAndStart()
            } else {
                Log.write("disabled via menu; native behavior until re-enabled")
                self.permissionTimer?.invalidate()
                self.permissionTimer = nil
                self.controller.stop()
            }
        }
        if Settings.enabled {
            ensurePermissionAndStart()
        } else {
            Log.write("startup: disabled by setting; hooks not installed")
        }
        // Optional: unlocks live titles for windows in other Spaces via
        // CGWindowList. Used solely to read titles; Cyclist never captures
        // window contents. Without it, last-seen titles are used instead.
        let screenRecording = CGPreflightScreenCaptureAccess()
        Log.write("startup: screen recording \(screenRecording ? "granted" : "not granted")")
        if !screenRecording {
            CGRequestScreenCaptureAccess()
        }
    }

    // An accessory app shows no menu bar, but key-equivalent routing still
    // consults the main menu while the app is active (a utility window is
    // key) - without one, Cmd+W and Cmd+Q are dead in those windows.
    private func installMainMenu() {
        let main = NSMenu()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(
            title: "Quit Cyclist", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        main.addItem(appItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(NSMenuItem(
            title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        let windowItem = NSMenuItem()
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.mainMenu = main
    }

    private func ensurePermissionAndStart() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(options), controller.start() {
            return
        }
        scheduleRecovery()
    }

    // Poll until Accessibility is granted (first launch, or re-granted after
    // a runtime revocation invalidated the tap) and the tap is rebuilt. Also
    // covers tap creation failing while trusted, e.g. a stale TCC entry.
    private func scheduleRecovery() {
        guard permissionTimer == nil else { return }
        Log.write("event tap down or Accessibility not granted; polling to rebuild")
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            guard let self, AXIsProcessTrusted(), self.controller.start() else { return }
            timer.invalidate()
            self.permissionTimer = nil
            Log.write("event tap running")
        }
    }
}
