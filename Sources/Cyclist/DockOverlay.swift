import CoreGraphics

// Whether the Dock has one of its overlay sessions up - Mission Control or
// App Exposé. While one is showing, the Space-navigation inputs belong to
// the overlay (Ctrl+Arrows move its selection, the trackpad swipe scrubs
// its view), so Cyclist passes them through instead of consuming them -
// an overlay never sees a consumed press, and the user reads that as
// Mission Control ignoring them.
//
// Detection reads the Dock's on-screen windows: an overlay session adds
// full-screen windows at layers 18 and 20 that are absent otherwise. The
// same empirical heuristic InstantSpaceSwitcher ships with unit tests
// (github.com/jurplel/InstantSpaceSwitcher, iss_is_expose_detected_in_
// window_list); there layer-20 outnumbering layer-18 separates Mission
// Control from App Exposé, a distinction the pass-through does not need.
// Owner name and layer are readable without Screen Recording. One
// on-screen window-list IPC per call, so callers keep it off hot paths:
// a matched navigation press or a gesture's opening phase, not every
// keystroke.
enum DockOverlay {
    static func isActive() -> Bool {
        guard let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)
            as? [[String: Any]] else { return false }
        var layer18 = 0
        var layer20 = 0
        for window in list where window[kCGWindowOwnerName as String] as? String == "Dock" {
            switch window[kCGWindowLayer as String] as? Int {
            case 18: layer18 += 1
            case 20: layer20 += 1
            default: break
            }
        }
        return layer18 > 0 && layer20 > 0
    }
}
