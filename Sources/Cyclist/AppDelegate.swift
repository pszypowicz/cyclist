import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = StatusItemController()
    private var mru: MRUTracker!
    private var controller: SwitcherController!
    private var permissionTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Settings.registerDefaults()
        AX.configureGlobalTimeout()
        mru = MRUTracker()
        controller = SwitcherController(mru: mru)
        statusItem.setUp()
        ensurePermissionAndStart()
    }

    private func ensurePermissionAndStart() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(options) {
            startTap()
            return
        }
        // Poll until the user grants Accessibility in System Settings, then attach.
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            guard AXIsProcessTrusted() else { return }
            timer.invalidate()
            self?.permissionTimer = nil
            self?.startTap()
        }
    }

    private func startTap() {
        if !controller.start() {
            NSLog("Cyclist: failed to create the keyboard event tap")
        }
    }
}
