import AppKit

// Walks to a target Space one Mission Control arrow press at a time.
//
// Mission Control drops any arrow press that arrives while its transition
// animation is still running - physical ones too: holding Ctrl and pressing
// the arrow twice quickly also lands one Space short, and a press that gets
// through mid-animation has its transition rolled back. Steps are therefore
// paced to the animation duration, and each step recomputes the remaining
// distance from the real Space state before pressing, so nothing is fired
// blind and outside interference (or a dropped press) degrades gracefully.
//
// activeSpaceDidChangeNotification is deliberately NOT used: it fires while
// the transition is in flight, when the reported current Space is garbage
// (it can read as an unrelated Space entirely), which once faked an arrival
// and stranded the navigation mid-route. Only reads taken a full step
// interval after a press proved trustworthy.
final class SpaceNavigator {
    // Just above the observed transition animation time; presses spaced
    // closer than ~1s get dropped.
    private let stepInterval: TimeInterval = 1.25

    private var target: UInt64?
    private var focus: (pid: pid_t, windowID: Int)?
    private var stepWork: DispatchWorkItem?

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
    }

    private func step() {
        guard let target else { return }
        guard let (order, current) = Spaces.orderInfo(containing: target),
              let targetIndex = order.firstIndex(of: target),
              let currentIndex = order.firstIndex(of: current) else {
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
        Log.write("navigator step: current=\(current) target=\(target)")
        Spaces.postCtrlArrow(right: targetIndex > currentIndex)
        let work = DispatchWorkItem { [weak self] in self?.step() }
        stepWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + stepInterval, execute: work)
    }
}
