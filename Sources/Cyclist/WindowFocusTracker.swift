import AppKit

// Most-recently-focused ordering of individual windows, complementing
// MRUTracker's app-level order: without it the switcher cannot offer "the
// window of that app I just came from" first, so bouncing between two
// windows of one app (a fullscreen browser window and a normal one, say)
// means cycling past every other row each time. Sources, all main-queue:
//   - the WindowServer focus stream (WindowServerEvents): the window server
//     announces every real focus change no matter how busy the app is or
//     how broken its Accessibility tree may be,
//   - the switcher's commit paths and the chain's arrival focus, whose
//     targets are known before any event arrives,
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
//
// Two intake filters keep machine-generated raises out of the ranking:
//   - While SpaceNavigator drives a transition (begin to verified arrival
//     plus a settle tail) nothing from the event stream records. The
//     transition raises companion chrome and the windows of transited
//     fullscreen Spaces - same-app noise the frontmost guard cannot
//     reject (observed: committing into a fullscreen video ranked the
//     OTHER fullscreen Safari window above the origin window, so the
//     next quick tap went there instead of back). Commit and chain
//     arrival paths rank their targets explicitly; a genuine focus
//     landing inside the tail stays unranked until its next focus.
//   - Events for windows that fail the realness predicate (companion
//     strips, transition backdrops) are dropped outright: they can never
//     be rows, and recording one burns the storm's genuine-focus slot or
//     the activation backfill.
final class WindowFocusTracker {
    // windowID -> monotonic focus sequence; higher = more recent.
    private var sequence: [Int: UInt64] = [:]
    private var counter: UInt64 = 0

    private var storm: (pid: pid_t, windowIDs: Set<Int>, sawFocus: Bool, until: Date)?
    // A focus event rejected because its app was not frontmost. Usually a
    // reveal-raise to discard, but when the app activation notification
    // follows (it lags the event stream), the rejection was the real focus
    // of a cross-app switch and gets backfilled.
    private var lastRejected: (windowID: Int, pid: pid_t, at: Date)?

    private var navigationActive = false
    private var suppressTailUntil = Date.distantPast
    // Transition noise keeps arriving briefly after the bookkeeping flips
    // (observed up to ~200ms past verified arrival).
    private let suppressTail: TimeInterval = 0.5

    private var suppressing: Bool { navigationActive || suppressTailUntil > Date() }

    func navigationBegan() {
        navigationActive = true
    }

    func navigationSettled() {
        navigationActive = false
        suppressTailUntil = Date().addingTimeInterval(suppressTail)
    }

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
        // A brand-new window's first focus event races the per-window
        // opt-in push and can be gated away, leaving the window the user
        // is typing in unranked - and unrankable until a later focus. New
        // windows almost always hold focus next, so rank them on creation
        // (a window created in the background mis-ranks briefly and the
        // next real focus corrects it).
        events.onCreated = { [weak self] windowID in
            guard let self, !self.suppressing,
                  CGWindows.realOwner(of: windowID)?.isReal == true else { return }
            self.noteFocus(windowID: windowID, source: "created")
        }
        events.onDestroyed = { [weak self] windowID in
            self?.sequence.removeValue(forKey: windowID)
            AppListProvider.evictTitle(windowID: windowID)
            WindowElements.evict(windowID: windowID)
            if self?.currentWindow?.windowID == windowID {
                self?.currentWindow?.windowID = nil
            }
        }
    }

    // The single mutation point. Recording is idempotent per focus change,
    // so duplicate deliveries (a commit followed by its own focus event)
    // just advance the same window's rank. Destroy events retire dead
    // entries, so the map stays bounded by the live window count.
    func noteFocus(windowID: Int, source: String) {
        counter += 1
        sequence[windowID] = counter
        Log.debug("recency: wid=\(windowID) seq=\(counter) via \(source)")
    }

    // 0 = never seen (or no window id); real ranks start at 1.
    func rank(of windowID: Int?) -> UInt64 {
        windowID.flatMap { sequence[$0] } ?? 0
    }

    // Value copy for off-main sweeps; `sequence` itself is main-confined.
    func ranksSnapshot() -> [Int: UInt64] {
        sequence
    }

    // The single current-window authority: what the switcher excludes as
    // "the window the user holds" and whose pid answers "the frontmost
    // app". Fed only by signals this tracker already trusts - the
    // switcher's commits at intent time, and focus events accepted into
    // the ranks (same-app focus, an activation storm's first focus, the
    // didActivate backfill). Suppressed transition noise never touches
    // it, so during our own navigation the last commit stays
    // authoritative; a cross-app mouse click lands when its activation
    // notification does (~0.1-1s). windowID goes nil when the current window
    // is destroyed or a windowless app was committed; pid survives for
    // the app-level question.
    private(set) var currentWindow: (windowID: Int?, pid: pid_t)?

    // Commit-intent feed from the switcher: the freshest possible truth
    // for switches Cyclist itself makes.
    func noteCommit(app: NSRunningApplication, windowID: Int?) {
        currentWindow = (windowID, app.processIdentifier)
        if let windowID {
            noteFocus(windowID: windowID, source: "commit")
        }
    }

    // Called from the switcher right before it activates an app, so the
    // raise-storm snapshot is in place even when the storm beats the
    // activation notification.
    func expectActivation(of app: NSRunningApplication) {
        installStorm(pid: app.processIdentifier)
    }

    @objc private func didActivate(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        let pid = app.processIdentifier
        installStorm(pid: pid)
        // A focus event for this app that arrived before the activation
        // notification was rejected by the frontmost guard; it was the
        // real focus of this very activation. Not during a self-driven
        // transition: there the commit already ranked the true target.
        if let rejected = lastRejected, rejected.pid == pid, !suppressing,
           Date().timeIntervalSince(rejected.at) < 1 {
            if var storm, storm.pid == pid {
                storm.windowIDs.remove(rejected.windowID)
                storm.sawFocus = true
                self.storm = storm
            }
            currentWindow = (rejected.windowID, rejected.pid)
            noteFocus(windowID: rejected.windowID, source: "activation")
            lastRejected = nil
        }
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
        if suppressing {
            Log.debug("recency: wid=\(windowID) suppressed (navigation)")
            return
        }
        guard let (pid, isReal) = CGWindows.realOwner(of: windowID), isReal else {
            Log.debug("recency: wid=\(windowID) ignored (unreal or gone)")
            return
        }
        if var storm, storm.until > Date(), storm.windowIDs.contains(windowID) {
            storm.windowIDs.remove(windowID)
            if storm.sawFocus {
                self.storm = storm
                Log.debug("recency: wid=\(windowID) raise swallowed")
                return
            }
            storm.sawFocus = true
            self.storm = storm
            currentWindow = (windowID, pid)
            noteFocus(windowID: windowID, source: "ws-focus")
            return
        }
        // Outside an activation storm, an event is only a user focus when
        // its app is frontmost: Space and workspace reveals raise the
        // freshly-visible windows of background apps, and recording those
        // corrupts both the ranks and the quick tap's notion of the
        // current window (observed as a first Cmd+Tab that re-commits the
        // window already held). A genuine cross-app focus rejected here is
        // backfilled when its activation notification lands.
        if pid != NSWorkspace.shared.frontmostApplication?.processIdentifier {
            lastRejected = (windowID, pid, Date())
            Log.debug("recency: wid=\(windowID) raise rejected (pid \(pid) not frontmost)")
            return
        }
        currentWindow = (windowID, pid)
        noteFocus(windowID: windowID, source: "ws-focus")
    }
}
