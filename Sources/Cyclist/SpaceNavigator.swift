import AppKit

// Jumps to a target Space with synthetic dock-swipe gestures (~40ms, no
// animation, any distance, fullscreen Spaces included), verifying arrival
// shortly after firing and retrying while attempts remain: the Dock
// sometimes drops a gesture fired shortly after a completed transition
// (and a dropped gesture can still half-apply, moving focus while the
// Space stays). Every step recomputes the remaining distance from the real
// Space state before acting, and on verified arrival the target window is
// made key.
//
// The WindowServer's own Space-change events are the primary wake-up hint
// (they fire the moment its bookkeeping flips, well before AppKit's
// activeSpaceDidChangeNotification relays the change, which stays wired as
// a fallback). Both are hints only, never arrival truth: they fire while a
// transition is in flight, when the reported current Space can be garbage.
// Every wake goes through the same guarded re-read: arrival is concluded
// only after the outstanding posted swipe has observably landed. Timers
// remain as the fallback for missed events. The swipe pacing floors below
// stay time-based because no settled-signal exists: bookkeeping arrival
// (which is what the Space events announce) precedes compositor safety.
final class SpaceNavigator {
    // First arrival check after a post: unloaded, the Space bookkeeping
    // reflects a swipe ~150-200ms after posting, and checking early cuts
    // the gap until the arrival focus makes the target window key. Early
    // polling is safe because a swipe that has not landed yet just
    // reschedules (the outstandingPost guard); those rechecks and retry
    // ticks stay on the slower verifyInterval cadence.
    private let earlyVerifyInterval: TimeInterval = 0.15
    private let verifyInterval: TimeInterval = 0.4
    private let maxAttempts = 3
    // The Dock cannot absorb a sustained stream of synthetic dock swipes
    // faster than roughly one per second: the Space bookkeeping keeps up,
    // but the WindowServer stops compositing the arrived Space's windows
    // and the screen shows bare wallpaper until a clean transition.
    // Measured on macOS 26: six alternating presses at 0.8s cadence wedge
    // every time and at 1.0s never, while a single quick pair is fine at
    // any spacing (0/36 down to 0.3s gaps). So the second post in a run
    // may follow fast, and only from the third consecutive post does the
    // full floor apply; commands arriving sooner coalesce into the latest
    // target.
    private let fastFollowInterval: TimeInterval = 0.45
    private let minPostInterval: TimeInterval = 1.15
    // Posts within this trailing window count as one consecutive run.
    private let runWindow: TimeInterval = 3.0

    private var target: UInt64?
    private var onArrival: (() -> Void)?
    private var stepWork: DispatchWorkItem?
    private var attempts = 0
    // Dock-side state that survives cancel(): the Dock's settling does not
    // care that a navigation was replaced. `outstandingPost` is the Space a
    // posted swipe is still carrying the display toward; until the
    // bookkeeping reflects it, "current" reads as the pre-swipe Space and
    // must not be used to judge arrival (under sustained input the lag
    // exceeds the verify interval, and a replaced target would otherwise
    // fake an instant arrival and leave the in-flight swipe unaccounted).
    private var recentPosts: [Date] = []
    private var outstandingPost: UInt64?
    private var inFlightChecks = 0

    private var spaceChangeObserver: NSObjectProtocol?

    // The in-flight destination, so callers can step relative to where
    // navigation is already headed instead of the (stale) current Space.
    var pendingTarget: UInt64? { target }

    init(events: WindowServerEvents) {
        events.onSpaceChanged = { [weak self] spaceID in
            guard let self, self.target != nil else { return }
            Log.debug("navigator: woken by ws space event (\(spaceID))")
            self.stepWork?.cancel()
            self.step()
        }
        spaceChangeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.target != nil else { return }
            Log.debug("navigator: woken by space-change notification")
            self.stepWork?.cancel()
            self.step()
        }
    }

    deinit {
        if let spaceChangeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(spaceChangeObserver)
        }
    }

    // Returns false when the active display's Space order does not contain
    // the target: the dock swipes act on the active display only, so a
    // target on another display would displace the wrong display's Spaces
    // (worse with every retry). `onArrival` runs once, after the Space
    // change is verified.
    func begin(to spaceID: UInt64, onArrival: (() -> Void)? = nil) -> Bool {
        guard Spaces.activeDisplayInfo()?.order.contains(spaceID) == true else { return false }
        if let replaced = target, replaced != spaceID {
            Log.debug("navigator: replacing in-flight target \(replaced) with \(spaceID)")
        }
        cancel()
        target = spaceID
        self.onArrival = onArrival
        inFlightChecks = 0
        step()
        return true
    }

    func cancel() {
        stepWork?.cancel()
        stepWork = nil
        target = nil
        onArrival = nil
        attempts = 0
    }

    private func step() {
        guard let target else { return }
        guard let info = Spaces.activeDisplayInfo(),
              let targetIndex = info.order.firstIndex(of: target),
              let currentIndex = info.order.firstIndex(of: info.current) else {
            cancel()
            return
        }
        if let outstanding = outstandingPost {
            if info.current == outstanding {
                outstandingPost = nil
            } else if inFlightChecks < 3 {
                inFlightChecks += 1
                Log.debug("navigator: swipe to \(outstanding) not landed, current=\(info.current) (check \(inFlightChecks))")
                schedule(after: verifyInterval)
                return
            } else {
                // Never landed: the Dock dropped it. Fall through and let
                // the normal repost/arrival logic act on the real state.
                outstandingPost = nil
            }
        }
        if targetIndex == currentIndex {
            Log.write("navigator arrived: space=\(target)")
            let arrival = onArrival
            cancel()
            arrival?()
            AppListProvider.harvestTitles()
            Diagnostics.verifyTransition(space: target)
            return
        }

        guard attempts < maxAttempts else {
            Log.write("navigator gave up: stalled at space=\(info.current) target=\(target)")
            cancel()
            return
        }
        let now = Date()
        recentPosts.removeAll { now.timeIntervalSince($0) > runWindow }
        if let last = recentPosts.last {
            let floor = recentPosts.count < 2 ? fastFollowInterval : minPostInterval
            let sincePost = now.timeIntervalSince(last)
            if sincePost < floor {
                Log.debug("navigator hold: \(Int((floor - sincePost) * 1000))ms until next swipe (run \(recentPosts.count), target \(target))")
                schedule(after: floor - sincePost)
                return
            }
        }
        attempts += 1
        let right = targetIndex > currentIndex
        let distance = abs(targetIndex - currentIndex)
        let sincePost = recentPosts.last.map { "\(Int(now.timeIntervalSince($0) * 1000))ms" } ?? "-"
        Log.write("navigator jump (swipe x\(distance), attempt \(attempts), sincePost=\(sincePost)): \(info.current) -> \(target)")
        Spaces.postDockSwipes(right: right, steps: distance)
        recentPosts.append(Date())
        outstandingPost = target
        inFlightChecks = 0
        schedule(after: earlyVerifyInterval)
    }

    private func schedule(after interval: TimeInterval) {
        let work = DispatchWorkItem { [weak self] in self?.step() }
        stepWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: work)
    }
}
