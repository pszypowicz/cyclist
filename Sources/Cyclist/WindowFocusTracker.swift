import AppKit

// Most-recently-focused ordering of individual windows, complementing
// MRUTracker's app-level order: without it the switcher cannot offer "the
// window of that app I just came from" first, so bouncing between two
// windows of one app (a fullscreen browser window and a normal one, say)
// means cycling past every other row each time. Sources, all main-queue:
//   - the WindowServer focus stream (WindowServerFocus): the window server
//     announces every real focus change no matter how busy the app is or
//     how broken its Accessibility tree may be,
//   - the switcher's own commit paths, whose target is known before any
//     event arrives,
//   - a z-order seed at launch, so ordering is sane before events accrue.
// In-memory only: recency loses its value within minutes and window ids
// recycle across reboots, so persistence would buy nothing.
//
// Around an app activation macOS emits a focus-event storm for the app's
// on-Space windows: the first is the real focus, the rest are raises that
// would invert the app's window order if recorded. A snapshot of those
// windows taken at activation swallows the raise tail, consume-on-delivery
// so a genuine post-storm focus of the same window still counts. Cyclist's
// own commits pre-install the snapshot, because the storm can beat the
// activation notification.
final class WindowFocusTracker {
    // windowID -> monotonic focus sequence; higher = more recent.
    private var sequence: [Int: UInt64] = [:]
    private var counter: UInt64 = 0
    // The window holding focus right now, i.e. the last one recorded; the
    // switcher's quick tap suggests the best-ranked window EXCLUDING this.
    private(set) var latestWindowID: Int?

    private var storm: (pid: pid_t, windowIDs: Set<Int>, sawFocus: Bool, until: Date)?

    // The stream is shared (SpaceNavigator consumes its Space events) and
    // started by the owner once every consumer has wired its callbacks.
    init(events: WindowServerEvents) {
        // Seed from the current-Space z-order (front-to-back) so ordering
        // is sane immediately after launch instead of degrading to AX
        // enumeration order until focus events accumulate.
        for window in CGWindows.real([.optionOnScreenOnly]).reversed() {
            counter += 1
            sequence[window.id] = counter
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didActivate(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
        events.onFocused = { [weak self] windowID in self?.handleFocus(windowID) }
        events.onDestroyed = { [weak self] windowID in
            self?.sequence.removeValue(forKey: windowID)
        }
    }

    // The single mutation point. Recording is idempotent per focus change,
    // so duplicate deliveries (a commit followed by its own focus event)
    // just advance the same window's rank. Destroy events retire dead
    // entries, so the map stays bounded by the live window count.
    func noteFocus(windowID: Int, source: String) {
        counter += 1
        sequence[windowID] = counter
        latestWindowID = windowID
        Log.debug("recency: wid=\(windowID) seq=\(counter) via \(source)")
    }

    // 0 = never seen (or no window id); real ranks start at 1.
    func rank(of windowID: Int?) -> UInt64 {
        windowID.flatMap { sequence[$0] } ?? 0
    }

    // Called from the switcher right before it activates an app, so the
    // raise-storm snapshot is in place even when the storm beats the
    // activation notification.
    func expectActivation(of app: NSRunningApplication) {
        installStorm(pid: app.processIdentifier)
    }

    @objc private func didActivate(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        installStorm(pid: app.processIdentifier)
    }

    private func installStorm(pid: pid_t) {
        // Keep a live snapshot for the same activation: the notification
        // arriving after a commit-installed storm must not reset a
        // half-consumed set, or the raise tail would count as focus.
        if let storm, storm.pid == pid, storm.until > Date() { return }
        // On-Space windows are what an activation raises; minimized and
        // other-Space windows are not raised, and leaving them out means a
        // genuine focus of one (un-minimize, Space arrival) always counts.
        let windowIDs = Set(CGWindows.real([.optionOnScreenOnly])
            .filter { $0.pid == pid }
            .map(\.id))
        guard !windowIDs.isEmpty else { return }
        storm = (pid, windowIDs, false, Date().addingTimeInterval(0.5))
    }

    private func handleFocus(_ windowID: Int) {
        if var storm, storm.until > Date(), storm.windowIDs.contains(windowID) {
            storm.windowIDs.remove(windowID)
            if storm.sawFocus {
                self.storm = storm
                Log.debug("recency: wid=\(windowID) raise swallowed")
                return
            }
            storm.sawFocus = true
            self.storm = storm
        }
        noteFocus(windowID: windowID, source: "ws-focus")
    }
}
