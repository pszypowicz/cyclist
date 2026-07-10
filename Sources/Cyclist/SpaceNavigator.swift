import AppKit

// Walks to a target Space one hop at a time, choosing the fastest native
// mechanism per hop:
//
// - Synthetic dock-swipe: instant (~40ms, no animation). The Dock refuses
//   it between two fullscreen Spaces, so those hops are predicted from the
//   Space types and use the arrow shortcut directly.
// - Mission Control arrow shortcut: animated (~1s), universally accepted,
//   but drops any press that arrives during a running animation - physical
//   presses included - so arrow hops are paced to the animation duration.
//
// Each step recomputes the remaining distance from the real Space state
// before acting, so nothing is fired blind; a hop that makes no progress
// falls back to the arrow, and three stalled steps abort the walk (covers
// the Mission Control shortcuts being disabled). On verified arrival the
// target window is made key.
//
// activeSpaceDidChangeNotification is deliberately not used: it fires while
// a transition is in flight, when the reported current Space can be garbage
// (it once read as an unrelated Space and faked an arrival mid-route).
final class SpaceNavigator {
    private let swipeInterval: TimeInterval = 0.35
    private let arrowInterval: TimeInterval = 1.25

    private var target: UInt64?
    private var focus: (pid: pid_t, windowID: Int)?
    private var stepWork: DispatchWorkItem?
    private var lastCurrent: UInt64?
    private var stalls = 0

    // Returns false when no display's Space order contains the target.
    func begin(to spaceID: UInt64, focusPid: pid_t, windowID: Int?) -> Bool {
        guard Spaces.orderInfo(containing: spaceID) != nil else { return false }
        cancel()
        target = spaceID
        focus = windowID.map { (focusPid, $0) }
        step()
        return true
    }

    func cancel() {
        stepWork?.cancel()
        stepWork = nil
        target = nil
        focus = nil
        lastCurrent = nil
        stalls = 0
    }

    private func step() {
        guard let target else { return }
        guard let info = Spaces.orderInfo(containing: target),
              let targetIndex = info.order.firstIndex(of: target),
              let currentIndex = info.order.firstIndex(of: info.current) else {
            cancel()
            return
        }
        if targetIndex == currentIndex {
            Log.write("navigator arrived: space=\(target)")
            if let focus {
                Spaces.makeKey(pid: focus.pid, windowID: focus.windowID)
            }
            cancel()
            return
        }

        let noProgress = lastCurrent == info.current
        if noProgress {
            stalls += 1
            if stalls >= 3 {
                Log.write("navigator gave up: stalled at space=\(info.current) target=\(target)")
                cancel()
                return
            }
        } else {
            stalls = 0
        }
        lastCurrent = info.current

        let right = targetIndex > currentIndex
        let next = info.order[currentIndex + (right ? 1 : -1)]
        let fullscreenToFullscreen = info.types[info.current] == Spaces.fullscreenSpaceType
            && info.types[next] == Spaces.fullscreenSpaceType
        let useArrow = fullscreenToFullscreen || noProgress

        Log.write("navigator step (\(useArrow ? "arrow" : "swipe")): \(info.current) -> \(next)")
        if useArrow {
            Spaces.postCtrlArrow(right: right)
        } else {
            Spaces.postDockSwipe(right: right)
        }
        let work = DispatchWorkItem { [weak self] in self?.step() }
        stepWork = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + (useArrow ? arrowInterval : swipeInterval), execute: work)
    }
}
