import Foundation

// Jumps to a target Space with synthetic dock-swipe gestures (~40ms, no
// animation, any distance, fullscreen Spaces included), verifying arrival
// shortly after firing and retrying while attempts remain: the Dock
// sometimes drops a gesture fired shortly after a completed transition
// (and a dropped gesture can still half-apply, moving focus while the
// Space stays). Every step recomputes the remaining distance from the real
// Space state before acting, and on verified arrival the target window is
// made key.
//
// The WindowServer's own Space-change events wake the step loop the moment
// its bookkeeping flips. They are hints only, never arrival truth: they
// fire while a transition is in flight, when the reported current Space
// can be garbage. Every wake goes through the same guarded re-read:
// arrival is concluded only after the outstanding posted swipe has
// observably landed. Timers remain for swipes the Dock drops outright,
// where no event ever fires. Posting is event-gated: each swipe waits for
// the previous transition to land plus a short settle, which the
// --measure-swipe-floor experiment shows never wedges the compositor
// (unlike the blind time-based cadence this replaced).
final class SpaceNavigator {
    // First arrival check after a post: the WindowServer space event
    // normally wakes the step first (bookkeeping flips ~40ms after a
    // post); the timers are the fallback for swipes the Dock drops.
    private let earlyVerifyInterval: TimeInterval = 0.15
    private let verifyInterval: TimeInterval = 0.4
    private let maxAttempts = 3
    // Settle after a landed transition before the next post. Measured with
    // --measure-swipe-floor on macOS 26: event-gated bursts never wedge
    // the compositor at ANY gap (the historical wedge came from blind
    // time-based posting that landed swipes mid-transition). Latest sweep
    // (26.5): arrivals stay in the 15-45ms band down to a 50ms gap, with
    // occasional ~500ms latency spikes appearing only below that - 50ms is
    // the fastest sustained cadence that stays predictable. Re-measure
    // after macOS updates. A post after idle goes out immediately.
    private let postSettleGap: TimeInterval = 0.05

    private var target: UInt64?
    private var onArrival: (() -> Void)?
    private var stepWork: DispatchWorkItem?
    private var attempts = 0
    // Dock-side state that survives cancel(): the Dock's settling does not
    // care that a navigation was replaced. `outstandingPost` is the Space a
    // posted swipe is still carrying the display toward; until the
    // bookkeeping reflects it, "current" reads as the pre-swipe Space and
    // must not be used to judge arrival (a replaced target would otherwise
    // fake an instant arrival and leave the in-flight swipe unaccounted).
    // `lastLanded` anchors the settle gap: pacing is measured from the
    // observed landing of the previous transition, not from the post.
    private var outstandingPost: UInt64?
    private var lastLanded: Date?
    private var inFlightChecks = 0

    // The in-flight destination, so callers can step relative to where
    // navigation is already headed instead of the (stale) current Space.
    var pendingTarget: UInt64? { target }

    // Navigations mark themselves on the focus tracker: the transition's
    // focus-shaped raises (companion chrome, transited fullscreen Spaces)
    // are machine noise that must not advance recency ranks.
    private let recency: WindowFocusTracker

    init(events: WindowServerEvents, recency: WindowFocusTracker) {
        self.recency = recency
        events.onSpaceChanged = { [weak self] spaceID in
            guard let self, self.target != nil else { return }
            Log.debug("navigator: woken by ws space event (\(spaceID))")
            self.stepWork?.cancel()
            self.step()
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
        recency.navigationBegan()
        target = spaceID
        self.onArrival = onArrival
        inFlightChecks = 0
        step()
        return true
    }

    func cancel() {
        // Only a navigation actually in flight settles the suppression;
        // the defensive cancels sprinkled through commit paths must not
        // open spurious suppression tails.
        if target != nil {
            recency.navigationSettled()
        }
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
                lastLanded = Date()
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
        if let landed = lastLanded {
            let sinceLanded = Date().timeIntervalSince(landed)
            if sinceLanded < postSettleGap {
                Log.debug("navigator hold: \(Int((postSettleGap - sinceLanded) * 1000))ms settle (target \(target))")
                schedule(after: postSettleGap - sinceLanded)
                return
            }
        }
        attempts += 1
        let right = targetIndex > currentIndex
        let distance = abs(targetIndex - currentIndex)
        let sinceLanded = lastLanded.map { "\(Int(Date().timeIntervalSince($0) * 1000))ms" } ?? "-"
        Log.write("navigator jump (swipe x\(distance), attempt \(attempts), sinceLanded=\(sinceLanded)): \(info.current) -> \(target)")
        Spaces.postDockSwipes(right: right, steps: distance)
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
