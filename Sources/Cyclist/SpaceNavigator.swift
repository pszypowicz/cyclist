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
// activeSpaceDidChangeNotification is deliberately not used: it fires while
// a transition is in flight, when the reported current Space can be garbage
// (it once read as an unrelated Space and faked an arrival mid-route).
final class SpaceNavigator {
    private let verifyInterval: TimeInterval = 0.4
    private let maxAttempts = 3

    private var target: UInt64?
    private var focus: (pid: pid_t, windowID: Int)?
    private var stepWork: DispatchWorkItem?
    private var attempts = 0

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
        attempts = 0
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

        guard attempts < maxAttempts else {
            Log.write("navigator gave up: stalled at space=\(info.current) target=\(target)")
            cancel()
            return
        }
        attempts += 1
        let right = targetIndex > currentIndex
        let distance = abs(targetIndex - currentIndex)
        Log.write("navigator jump (swipe x\(distance), attempt \(attempts)): \(info.current) -> \(target)")
        Spaces.postDockSwipes(right: right, steps: distance)
        schedule(after: verifyInterval)
    }

    private func schedule(after interval: TimeInterval) {
        let work = DispatchWorkItem { [weak self] in self?.step() }
        stepWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: work)
    }
}
