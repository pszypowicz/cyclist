import AppKit

// Detects 3-finger horizontal trackpad swipes from raw gesture events
// (CGS event type 29), independent of whether the macOS "swipe between
// full-screen applications" trackpad gesture is enabled. The event tap
// hands every gesture event here; touch positions come from the NSEvent
// bridge. Cyclist's own synthetic dock-swipe events carry no touches, so
// they can never re-trigger this.
//
// Known limitation: when the native 3-finger Spaces gesture is enabled,
// both the system and Cyclist react to the same swipe (the gesture tap is
// listen-only, so the native handling cannot be suppressed).
final class SwipeDetector {
    // Fires once per physical swipe; `left` is the finger direction.
    var onSwipe: ((_ left: Bool) -> Void)?

    private let minDistance: CGFloat = 0.05  // normalized trackpad units
    private var tracking = false
    private var fired = false
    private var poisoned = false
    private var lastCount = 0
    private var startX: CGFloat = 0
    private var startY: CGFloat = 0

    func handle(_ cgEvent: CGEvent) {
        guard let event = NSEvent(cgEvent: cgEvent) else {
            // Unknown state: never measure a later gesture against stale
            // anchors.
            reset()
            return
        }
        let touches = event.allTouches().filter { $0.phase != .ended && $0.phase != .cancelled }
        defer { lastCount = touches.count }
        if touches.isEmpty {
            // Sequence over; only here does a poisoned gesture recover.
            reset()
            return
        }
        // A gesture that ever had more than 3 fingers is a system gesture
        // whose tail (one finger lifting early) must not read as a swipe.
        if touches.count > 3 {
            poisoned = true
        }
        guard touches.count == 3, !poisoned else {
            tracking = false
            fired = false
            return
        }
        var sumX: CGFloat = 0
        var sumY: CGFloat = 0
        for touch in touches {
            sumX += touch.normalizedPosition.x
            sumY += touch.normalizedPosition.y
        }
        let avgX = sumX / 3
        let avgY = sumY / 3
        if !tracking {
            // Only a rise to exactly 3 fingers starts a gesture; a fall from
            // 4+ is the tail of a system gesture.
            guard lastCount < 3 else { return }
            tracking = true
            fired = false
            startX = avgX
            startY = avgY
            return
        }
        guard !fired else { return }
        let dx = avgX - startX
        let dy = avgY - startY
        if abs(dx) >= minDistance, abs(dx) > abs(dy) {
            fired = true
            onSwipe?(dx < 0)
        }
    }

    private func reset() {
        tracking = false
        fired = false
        poisoned = false
        lastCount = 0
    }
}
