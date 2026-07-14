import AppKit
import ApplicationServices

// The AXObserver callback is a C function pointer and cannot capture; the
// tracker is recovered through the unretained refcon. Safe because the
// tracker is owned by AppDelegate for the process lifetime and every
// observer is detached before a new one is created.
private let focusCallback: AXObserverCallback = { _, element, _, refcon in
    guard let refcon else { return }
    Unmanaged<WindowFocusTracker>.fromOpaque(refcon).takeUnretainedValue()
        .handleFocusNotification(element)
}

// Most-recently-focused ordering of individual windows, complementing
// MRUTracker's app-level order: without it the switcher cannot offer "the
// window of that app I just came from" first, so bouncing between two
// windows of one app (a fullscreen browser window and a normal one, say)
// means cycling past every other row each time. Sources, all main-queue:
//   - activation-time capture of the newly frontmost app's focused window,
//   - an AXObserver on the frontmost app for in-app focus changes
//     (clicking between windows posts no workspace notification),
//   - explicit recording from the switcher's commit paths, which must beat
//     the ~0.1-1s didActivate propagation lag when the user reopens the
//     switcher right after a quick tap.
// In-memory only: recency loses its value within minutes, the frontmost
// window is re-captured on the first activation after launch, and window
// ids recycle across reboots, so persistence would buy nothing.
final class WindowFocusTracker {
    // windowID -> monotonic focus sequence; higher = more recent.
    private var sequence: [Int: UInt64] = [:]
    private var counter: UInt64 = 0

    // Observer state for the current frontmost app.
    private var observer: AXObserver?
    private var observedElement: AXUIElement?
    private var observedPid: pid_t = -1
    // Cancels a pending attach retry once the frontmost app moves on.
    private var retryGeneration = 0

    init() {
        // Seed from the current-Space z-order (front-to-back) so ordering
        // is sane immediately after launch instead of degrading to AX
        // enumeration order until focus events accumulate.
        for window in CGWindows.real([.optionOnScreenOnly]).reversed() {
            counter += 1
            sequence[window.id] = counter
        }
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(didActivate(_:)),
                           name: NSWorkspace.didActivateApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(didTerminate(_:)),
                           name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        attachToFrontmost()
    }

    // The single mutation point. Recording is idempotent per focus change,
    // so duplicate deliveries (focused + main window notifications for one
    // switch, or a commit followed by its own activation capture) just
    // advance the same window's rank.
    func noteFocus(windowID: Int, source: String) {
        counter += 1
        sequence[windowID] = counter
        Log.debug("recency: wid=\(windowID) seq=\(counter) via \(source)")
        // Window ids are never reused within a boot, so closed windows
        // would leave dead entries forever; a size cap replaces tracking
        // window-close events. Runs at most once per 1024 focus changes.
        if sequence.count > 2048 {
            let cutoff = sequence.values.sorted(by: >)[1024]
            sequence = sequence.filter { $0.value > cutoff }
        }
    }

    // 0 = never seen (or no window id); real ranks start at 1.
    func rank(of windowID: Int?) -> UInt64 {
        windowID.flatMap { sequence[$0] } ?? 0
    }

    // Also called after an Accessibility grant lands: on first launch the
    // initial attach ran before the grant and failed.
    func attachToFrontmost() {
        if let front = NSWorkspace.shared.frontmostApplication {
            retarget(pid: front.processIdentifier)
        }
    }

    fileprivate func handleFocusNotification(_ element: AXUIElement) {
        guard let windowID = AX.windowID(of: element) else { return }
        noteFocus(windowID: windowID, source: "observer")
    }

    @objc private func didActivate(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        retarget(pid: app.processIdentifier)
    }

    @objc private func didTerminate(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.processIdentifier == observedPid else { return }
        detach()
    }

    private func retarget(pid: pid_t) {
        detach()
        retryGeneration += 1
        // The observer only reports changes after it attaches; capture the
        // window the user just landed on now. If the app still reports its
        // previous focused window this early in the activation, the
        // observer notification that follows overwrites it.
        if let windowID = AX.focusedWindowID(pid: pid) {
            noteFocus(windowID: windowID, source: "activate")
        }
        attach(pid: pid, isRetry: false)
    }

    private func attach(pid: pid_t, isRetry: Bool) {
        var created: AXObserver?
        guard AXObserverCreate(pid, focusCallback, &created) == .success, let created else {
            // App without an AX bridge; the commit chokepoints still rank
            // its windows.
            Log.debug("recency: observer create failed pid=\(pid)")
            return
        }
        let appElement = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let focusedResult = AXObserverAddNotification(
            created, appElement, kAXFocusedWindowChangedNotification as CFString, refcon)
        // Main-window changes can happen while a floating panel keeps focus,
        // and some apps emit only one of the two notifications.
        AXObserverAddNotification(
            created, appElement, kAXMainWindowChangedNotification as CFString, refcon)
        guard focusedResult == .success else {
            // A busy app (mid Space transition, exactly the fullscreen
            // arrival case) can run into the global AX messaging timeout.
            // One retry, dropped if the frontmost app moved on meanwhile.
            Log.debug("recency: observer attach failed pid=\(pid) (\(focusedResult.rawValue))")
            if !isRetry {
                let generation = retryGeneration
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    guard let self, self.retryGeneration == generation else { return }
                    if let windowID = AX.focusedWindowID(pid: pid) {
                        self.noteFocus(windowID: windowID, source: "attach-retry")
                    }
                    self.attach(pid: pid, isRetry: true)
                }
            }
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
        observer = created
        observedElement = appElement
        observedPid = pid
    }

    private func detach() {
        guard let observer, let observedElement else { return }
        // Failures ignored: the app may already be gone. The run-loop
        // source must come off either way or one leaks per app switch.
        AXObserverRemoveNotification(observer, observedElement, kAXFocusedWindowChangedNotification as CFString)
        AXObserverRemoveNotification(observer, observedElement, kAXMainWindowChangedNotification as CFString)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        self.observer = nil
        self.observedElement = nil
        observedPid = -1
    }
}
