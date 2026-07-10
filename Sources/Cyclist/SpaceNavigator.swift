import AppKit

// Takes the frontmost route to a target Space:
//
// 1. Direct jump: synthetic dock-swipe gestures (~40ms, no animation, any
//    distance, fullscreen Spaces included). Verified shortly after firing.
// 2. Fallback: the Mission Control arrow shortcut, one hop at a time. It
//    plays the full animation and drops any press that arrives while one
//    is running - physical presses included - so arrow hops are paced to
//    the animation duration. Covers a future macOS breaking the gesture
//    encoding; three stalled steps abort the walk (covers the Mission
//    Control shortcuts being disabled too).
//
// Every step recomputes the remaining distance from the real Space state
// before acting, and on verified arrival the target window is made key.
//
// activeSpaceDidChangeNotification is deliberately not used: it fires while
// a transition is in flight, when the reported current Space can be garbage
// (it once read as an unrelated Space and faked an arrival mid-route).
final class SpaceNavigator {
    private let swipeVerifyInterval: TimeInterval = 0.4
    private let arrowInterval: TimeInterval = 1.25

    private var target: UInt64?
    private var focus: (pid: pid_t, windowID: Int)?
    private var stepWork: DispatchWorkItem?
    private var triedSwipe = false
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
        triedSwipe = false
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

        if lastCurrent == info.current {
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
        let distance = abs(targetIndex - currentIndex)
        if !triedSwipe {
            triedSwipe = true
            Log.write("navigator jump (swipe x\(distance)): \(info.current) -> \(target)")
            Spaces.postDockSwipes(right: right, steps: distance)
            schedule(after: swipeVerifyInterval)
        } else {
            Log.write("navigator step (arrow): \(info.current) toward \(target)")
            Spaces.postCtrlArrow(right: right)
            schedule(after: arrowInterval)
        }
    }

    private func schedule(after interval: TimeInterval) {
        let work = DispatchWorkItem { [weak self] in self?.step() }
        stepWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: work)
    }
}
