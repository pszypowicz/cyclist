import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = StatusItemController()
    private let aerospace = AeroSpaceClient()
    private var mru: MRUTracker!
    private var controller: SwitcherController!
    private var permissionTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Settings.registerDefaults()
        AX.configureGlobalTimeout()
        aerospace.start()
        mru = MRUTracker()
        controller = SwitcherController(mru: mru)
        controller.onTapInvalidated = { [weak self] in self?.scheduleRecovery() }
        statusItem.setUp()
        ensurePermissionAndStart()
        // Optional: unlocks live titles for windows in other Spaces via
        // CGWindowList. Used solely to read titles; Cyclist never captures
        // window contents. Without it, last-seen titles are used instead.
        let screenRecording = CGPreflightScreenCaptureAccess()
        Log.write("startup: screen recording \(screenRecording ? "granted" : "not granted")")
        if !screenRecording {
            CGRequestScreenCaptureAccess()
        }
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
