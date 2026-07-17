import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = StatusItemController()
    private let aerospace = AeroSpaceClient()
    private let wsEvents = WindowServerEvents()
    private var mru: MRUTracker!
    private var recency: WindowFocusTracker!
    private var controller: SwitcherController!
    private var permissionTimer: Timer?
    // Last applied values: defaults KVO fires on every write, including
    // same-value ones, and start/stop must not run twice.
    private var enabledApplied = false
    private var aerospaceApplied = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        Settings.registerDefaults()
        _ = ShortcutSettings.shared
        AX.configureGlobalTimeout()
        aerospaceApplied = Settings.aerospaceIntegration
        if aerospaceApplied {
            aerospace.start()
        }
        mru = MRUTracker()
        recency = WindowFocusTracker(events: wsEvents)
        controller = SwitcherController(mru: mru, recency: recency, aerospace: aerospace, events: wsEvents)
        // Start delivering only after every consumer has wired its callbacks.
        wsEvents.start()
        controller.onTapInvalidated = { [weak self] in self?.scheduleRecovery() }
        statusItem.setUp()
        // Enabled and the AeroSpace integration apply through defaults KVO,
        // so the menu toggle and `defaults write` are the same mechanism
        // and external writes take effect immediately.
        for key in [Settings.enabledKey, Settings.aerospaceIntegrationKey] {
            UserDefaults.standard.addObserver(self, forKeyPath: key, options: [], context: nil)
        }
        enabledApplied = Settings.enabled
        if enabledApplied {
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

    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        // KVO from an external `defaults write` can arrive off-main.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.applyEnabled()
            self.applyAerospace()
        }
    }

    // Disabled means the taps are down and every shortcut is native again;
    // the trackers and the AeroSpace client keep running so a re-enable
    // resumes with fresh MRU order.
    private func applyEnabled() {
        let enabled = Settings.enabled
        guard enabled != enabledApplied else { return }
        enabledApplied = enabled
        statusItem.refreshEnabled()
        if enabled {
            Log.write("enabled; installing hooks")
            ensurePermissionAndStart()
        } else {
            Log.write("disabled; native behavior until re-enabled")
            permissionTimer?.invalidate()
            permissionTimer = nil
            controller.stop()
        }
    }

    private func applyAerospace() {
        let on = Settings.aerospaceIntegration
        guard on != aerospaceApplied else { return }
        aerospaceApplied = on
        if on {
            aerospace.start()
        } else {
            aerospace.stop()
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
        // A tap-invalidation callback queued just before a disable must not
        // restart polling against the user's choice.
        guard Settings.enabled else { return }
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
