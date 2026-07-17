import CoreGraphics
import Foundation

// Turns the trackpad's fluid Spaces swipe (the three- or four-finger
// horizontal gesture, whichever "Swipe between full-screen applications"
// is set to - it must be enabled, or the WindowServer never emits these
// events) into discrete chain-navigation steps: one step per gesture, the
// trackpad equivalent of one Ctrl+Left/Right press. Every event of a real
// horizontal dock swipe is consumed, so the Dock never starts its own
// animated transition; vertical dock swipes (Mission Control, App Exposé)
// pass through untouched.
//
// Reads the same undocumented gesture-event encoding that
// Spaces.postDockSwipePair writes: a dock-swipe payload carries
// IOHIDEventType 23 in field 110, motion axis in field 123 (1 =
// horizontal), cumulative progress in field 124 (screen-widths, positive
// toward the Space on the right), X velocity in field 129, and the
// IOHIDEventPhase in field 132 (mayBegin=128, began=1, changed=2,
// ended=4, cancelled=8). Cyclist's own synthetic swipes carry
// Spaces.syntheticGestureTag in the event-source user data and are not
// touched: they must reach the Dock for SpaceNavigator to work, and
// treating them as real would navigate in a loop.
final class DockSwipeRecognizer {
    // A step fires the moment cumulative progress commits past this, not
    // at gesture end, so the response feels immediate. A short flick ends
    // below the progress threshold but with velocity; the ended phase
    // falls back to that, mirroring the Dock's own flick handling.
    private let progressThreshold = 0.15
    private let velocityThreshold = 200.0

    private let gestureHIDTypeField = CGEventField(rawValue: 110)!
    private let swipeMotionField = CGEventField(rawValue: 123)!
    private let swipeProgressField = CGEventField(rawValue: 124)!
    private let swipeVelocityXField = CGEventField(rawValue: 129)!
    private let gesturePhaseField = CGEventField(rawValue: 132)!

    private let dockSwipeHIDType: Int64 = 23
    private let horizontalMotion: Int64 = 1

    // Called on the tap callback; the owner defers real work off it.
    var onSwipe: ((_ left: Bool) -> Void)?

    private var fired = false

    // Returns true when the event belongs to a real horizontal dock swipe,
    // which must not reach the Dock.
    func handle(_ event: CGEvent) -> Bool {
        guard event.getIntegerValueField(gestureHIDTypeField) == dockSwipeHIDType,
              event.getIntegerValueField(.eventSourceUserData) != Spaces.syntheticGestureTag,
              event.getIntegerValueField(swipeMotionField) == horizontalMotion else {
            return false
        }
        let phase = event.getIntegerValueField(gesturePhaseField)
        let progress = event.getDoubleValueField(swipeProgressField)
        let velocity = event.getDoubleValueField(swipeVelocityXField)
        Log.debug("swipe: phase=\(phase) progress=\(progress) velocity=\(velocity)")
        switch phase {
        case 1, 128:  // began / may begin
            fired = false
        case 2:  // changed
            fireIfCommitted(progress: progress, velocity: 0)
        case 4:  // ended
            fireIfCommitted(progress: progress, velocity: velocity)
            fired = false
        case 8:  // cancelled
            fired = false
        default:
            break
        }
        return true
    }

    private func fireIfCommitted(progress: Double, velocity: Double) {
        guard !fired else { return }
        let left: Bool
        if abs(progress) >= progressThreshold {
            left = progress < 0
        } else if abs(velocity) >= velocityThreshold {
            left = velocity < 0
        } else {
            return
        }
        fired = true
        Log.write("swipe: \(left ? "left" : "right")"
            + " (progress \(String(format: "%.2f", progress))"
            + ", velocity \(String(format: "%.0f", velocity)))")
        onSwipe?(left)
    }
}
