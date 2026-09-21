import Foundation

// Jumps to a target Space with synthetic dock-swipe gestures (~40ms, no
// animation, any distance, fullscreen Spaces included), verifying arrival
// shortly after firing: the work chained on arrival (window focus, the
// AeroSpace two-hop's workspace switch) must only run once the Space
// change is real. Posting is single-shot - the three-phase
// gesture shape (Spaces.postDockSwipes) measures drop-free even at zero
// settle gap (scripts/gesture-shape-experiment.swift), so a navigation
// that never lands logs "gave up" as the signal to re-evaluate rather
// than reposting blind. Every step recomputes the remaining distance from
// the real Space state before acting, and on verified arrival the target
// window is made key.
//
// The WindowServer's own Space-change events wake the step loop the moment
// its bookkeeping flips. They are hints only, never arrival truth: they
// fire while a transition is in flight, when the reported current Space
// can be garbage. Every wake goes through the same guarded re-read:
// arrival is concluded only after the outstanding posted swipe has
// observably landed. Timers remain for swipes the Dock drops outright,
// where no event ever fires. Posting is event-gated: each swipe waits for
// the previous transition to land plus a short settle, which the
// --measure-swipe-floor experiment shows never wedges the compositor.
final class SpaceNavigator {
    // First arrival check after a post: the WindowServer space event
    // normally wakes the step first (bookkeeping flips ~40ms after a
    // post); the timers are the fallback for swipes the Dock drops.
    private let earlyVerifyInterval: TimeInterval = 0.15
    private let verifyInterval: TimeInterval = 0.4
    // Verify wakes an outstanding post may fail before the navigation
    // concludes the Dock dropped it and gives up (~1.5s with the timer
    // cadence; the event wake usually settles it in one).
    private let maxInFlightChecks = 3
    // Settle after a landed transition before the next post. Measured with
    // --measure-swipe-floor: event-gated bursts never wedge the compositor
    // at any gap, and 50ms is the fastest sustained cadence that stays
    // predictable. Re-measure after macOS updates. A post after idle
    // goes out immediately.
    private let postSettleGap: TimeInterval = 0.05

    private var target: UInt64?
    private var onArrival: (() -> Void)?
    private var stepWork: DispatchWorkItem?
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
    // Deferred heal requests coalesce: two arrivals in quick succession must
    // not leave two ramps racing to open.
    private var healWork: DispatchWorkItem?

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
    // target on another display would displace the wrong display's Spaces.
    // `onArrival` runs once, after the Space change is verified.
    func begin(to spaceID: UInt64, onArrival: (() -> Void)? = nil) -> Bool {
        guard Spaces.activeDisplayInfo()?.order.contains(spaceID) == true else { return false }
        if let replaced = target, replaced != spaceID {
            Log.debug("navigator: replacing in-flight target \(replaced) with \(spaceID)")
        }
        // A swipe posted into the middle of a chrome-heal ramp is dropped by
        // the Dock, which used to swallow whole bursts of quick swipes.
        if Spaces.cancelChromeHeal() {
            Log.debug("navigator: closed an in-flight chrome heal")
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
            } else if inFlightChecks < maxInFlightChecks {
                inFlightChecks += 1
                Log.debug("navigator: swipe to \(outstanding) not landed, current=\(info.current) (check \(inFlightChecks))")
                schedule(after: verifyInterval)
                return
            } else {
                // The Dock never acted on the post. Single-shot means the
                // navigation is over; this line is the tripwire for any
                // drop scenario the three-phase gesture does not cover.
                Log.write("navigator gave up: swipe to \(outstanding) never landed,"
                    + " current=\(info.current) target=\(target)")
                outstandingPost = nil
                cancel()
                return
            }
        }
        if targetIndex == currentIndex {
            Log.write("navigator arrived: space=\(target)")
            let arrival = onArrival
            cancel()
            arrival?()
            AppListProvider.harvestTitles()
            if info.types[target] != 0 {
                scheduleChromeHeal(space: target, right: targetIndex == 0)
            }
            Diagnostics.verifyTransition(space: target)
            return
        }

        // The settle gap runs from the last thing the Dock had to absorb:
        // a landed transition, or a chrome-heal ramp closing.
        if let settled = [lastLanded, Spaces.lastHealClose].compactMap({ $0 }).max() {
            let sinceSettled = Date().timeIntervalSince(settled)
            if sinceSettled < postSettleGap {
                Log.debug("navigator hold: \(Int((postSettleGap - sinceSettled) * 1000))ms settle (target \(target))")
                schedule(after: postSettleGap - sinceSettled)
                return
            }
        }
        let right = targetIndex > currentIndex
        let distance = abs(targetIndex - currentIndex)
        let sinceLanded = lastLanded.map { "\(Int(Date().timeIntervalSince($0) * 1000))ms" } ?? "-"
        Log.write("navigator jump (swipe x\(distance), sinceLanded=\(sinceLanded)): \(info.current) -> \(target)")
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

    // Every fullscreen arrival repaints its companion chrome (#63); see
    // Spaces.postFullscreenChromeHeal for the mechanism. Display sleep
    // purges the backings of windows on non-visible Spaces, the purge is
    // invisible to every bookkeeping signal short of capturing pixels, and
    // the heal itself is imperceptible, so it runs unconditionally rather
    // than detecting the wedge. Deferred past the arrival because the Dock
    // drops gestures fired right on a completed transition, and skipped
    // when the user has already navigated on. A navigation that starts
    // while the ramp is open closes it (see begin).
    private func scheduleChromeHeal(space: UInt64, right: Bool) {
        healWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.target == nil,
                  Spaces.activeDisplayInfo()?.current == space else { return }
            Log.debug("navigator: fullscreen chrome heal on space \(space)")
            Spaces.postFullscreenChromeHeal(right: right)
        }
        healWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }
}
