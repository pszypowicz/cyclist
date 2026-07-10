import AppKit

// Detects 3-finger horizontal trackpad swipes from raw gesture events
// (CGS event type 29), independent of whether the macOS "swipe between
// full-screen applications" trackpad gesture is enabled. The event tap
// hands every gesture event here; touch positions come from the NSEvent
// bridge. Cyclist's own synthetic dock-swipe events carry no touches, so
// they can never re-trigger this.
final class SwipeDetector {
    // Fires once per physical swipe; `left` is the finger direction.
    var onSwipe: ((_ left: Bool) -> Void)?

    private let minDistance: CGFloat = 0.05  // normalized trackpad units
    private var tracking = false
    private var fired = false
    private var startX: CGFloat = 0
    private var startY: CGFloat = 0

    func handle(_ cgEvent: CGEvent) {
        guard let event = NSEvent(cgEvent: cgEvent) else { return }
        let touches = event.allTouches().filter { $0.phase != .ended && $0.phase != .cancelled }
        guard touches.count == 3 else {
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
}
