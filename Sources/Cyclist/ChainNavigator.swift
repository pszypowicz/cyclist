import AppKit

// Ctrl+Left/Right and the 3-finger swipe walk the native Spaces of the
// active display in Mission Control order - user desktops and fullscreen
// Spaces alike - with instant, animation-free jumps. Arriving on a user
// Space focuses its top window, so stepping out of a fullscreen app always
// lands on something concrete instead of leaving the fullscreen app's menu
// bar behind. Workspace systems layered on top of a single Space keep
// their own switching bindings; Cyclist deliberately stays out of that
// business.
final class ChainNavigator {
    private let navigator: SpaceNavigator

    init(navigator: SpaceNavigator) {
        self.navigator = navigator
    }

    func navigate(left: Bool) {
        guard let display = Spaces.activeDisplayInfo() else {
            Log.write("chain: no display info")
            return
        }
        guard let currentIndex = display.order.firstIndex(of: display.current) else {
            Log.write("chain: current space \(display.current) not in \(display.order)")
            return
        }
        let targetIndex = currentIndex + (left ? -1 : 1)
        guard display.order.indices.contains(targetIndex) else {
            Log.write("chain: at \(left ? "left" : "right") edge of \(display.order)")
            return
        }
        let target = display.order[targetIndex]
        Log.write("chain: \(left ? "left" : "right") \(display.current) -> \(target)")
        let arrival: (() -> Void)? = display.types[target] == 0
            ? { Self.focusTopUserWindow() }
            : nil
        _ = navigator.begin(to: target, onArrival: arrival)
    }

    // Front-to-back on-screen window list; the first regular-app window on
    // the active display is what the user sees on top of the Space just
    // arrived at. The center-point test keeps windows overhanging from a
    // neighboring display out (CGWindowList bounds and CGDisplayBounds share
    // the same global top-left-origin coordinates).
    private static func focusTopUserWindow() {
        let displayBounds = Spaces.activeDisplayID().map(CGDisplayBounds)
        guard let window = CGWindows.real([.optionOnScreenOnly]).first(where: { window in
            guard NSRunningApplication(processIdentifier: window.pid)?.activationPolicy == .regular
            else { return false }
            guard let displayBounds else { return true }
            return displayBounds.contains(CGPoint(x: window.bounds.midX, y: window.bounds.midY))
        }) else { return }
        Log.write("chain: focus top window \(window.id) pid \(window.pid)")
        Spaces.makeKey(pid: window.pid, windowID: window.id)
    }
}
